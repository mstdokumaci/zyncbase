import { describe, expect, test } from "bun:test";
import type { OutboundRequest } from "./connection_wire.js";
import { SchemaDictionary } from "./schema_dictionary.js";
import { type StoreConnection, StoreImpl } from "./store.js";
import { SubscriptionTracker } from "./subscriptions.js";
import type { JsonValue, ListenHandle, OkResponse } from "./types.js";

function makeStore(
	responses: Array<OkResponse | Error> = [],
	schemaDictionary?: SchemaDictionary,
	options: { ready?: boolean } = {},
) {
	const messages: OutboundRequest[] = [];
	const responseTableIndexes: Array<number | undefined> = [];
	const errors: unknown[] = [];
	const pendingResponses = [...responses];

	const schema = schemaDictionary ?? new SchemaDictionary();

	const conn: StoreConnection = {
		dispatch: async (
			msg: OutboundRequest,
			responseTableIndex?: number,
		): Promise<OkResponse> => {
			messages.push(msg);
			responseTableIndexes.push(responseTableIndex);
			const response = pendingResponses.shift();
			if (response instanceof Error) throw response;
			return response ?? { type: "ok", id: messages.length };
		},
		dispatchWrite: async (msg: OutboundRequest): Promise<void> => {
			messages.push(msg);
			const response = pendingResponses.shift();
			if (response instanceof Error) throw response;
		},
		on: () => {},
		schemaDictionary: schema,
	};

	const tracker = new SubscriptionTracker();
	const store = new StoreImpl(conn, tracker, (err) => errors.push(err));
	if (options.ready !== false) void store.markSessionReady();

	return {
		store,
		tracker,
		messages,
		responseTableIndexes,
		errors,
		conn,
		schema,
	};
}

async function flushPromises(): Promise<void> {
	await Promise.resolve();
	await Promise.resolve();
}

/** Waits one macrotask tick so the batched materialized-view flush runs. */
async function flushTimers(): Promise<void> {
	await new Promise((resolve) => setTimeout(resolve, 0));
}

async function makeReadySchema(): Promise<SchemaDictionary> {
	const schema = new SchemaDictionary();
	await schema.processSchemaSync({
		version: "1.0.0",
		tables: ["users"],
		fields: [["id", "name"]],
		fieldFlags: [[0, 0]],
	});
	return schema;
}

describe("StoreImpl", () => {
	test("set dispatches one built StoreSet message", async () => {
		const { store, messages } = makeStore();

		await store.set("users.u1", {
			name: "Ada",
			address: { city: "London" },
		});

		expect(messages).toEqual([
			{
				type: "StoreSet",
				path: ["users", "u1"],
				value: {
					name: "Ada",
					address__city: "London",
				},
			},
		]);
	});

	test("get dispatches StoreQuery and returns shaped document results", async () => {
		const { store, messages } = makeStore([
			{
				type: "ok",
				id: 1,
				value: [{ name: "Ada", address: { city: "London" } }],
			},
		]);

		await expect(store.get("users.u1")).resolves.toEqual({
			name: "Ada",
			address: { city: "London" },
		});
		expect(messages).toEqual([
			{
				type: "StoreQuery",
				table_index: "users",
				conditions: [["id", 0, "u1"]],
			},
		]);
	});

	test("dispatch errors are emitted and rethrown as SDK errors", async () => {
		const { store, errors } = makeStore([new Error("socket failed")]);

		await expect(store.set("users.u1", { name: "Ada" })).rejects.toMatchObject({
			code: "INTERNAL_ERROR",
			message: "socket failed",
		});
		expect(errors).toHaveLength(1);
		expect(errors[0]).toMatchObject({
			code: "INTERNAL_ERROR",
			message: "socket failed",
		});
	});

	test("listen registers with SubscriptionTracker and emits initial snapshot", async () => {
		const { store, messages } = makeStore([
			{
				type: "ok",
				id: 1,
				subId: 7,
				value: [{ id: "u1", name: "Ada" }],
			},
		]);
		const values: JsonValue[] = [];

		const handle = await store.listen("users.u1", (value) =>
			values.push(value),
		);
		await flushPromises();

		expect(messages[0]).toEqual({
			type: "StoreSubscribe",
			table_index: "users",
			conditions: [["id", 0, "u1"]],
		});
		expect(values).toEqual([{ id: "u1", name: "Ada" }]);

		await handle.unlisten();
		// Local detach resolves immediately; the server unsubscribe lands
		// after the grace window.
		expect(messages).toHaveLength(1);
		await new Promise((resolve) => setTimeout(resolve, 350));
		expect(messages[1]).toEqual({ type: "StoreUnsubscribe", subId: 7 });
	});

	test("listen handle follows the subId remapped by reconnect replay", async () => {
		const { store, tracker, messages } = makeStore([
			{ type: "ok", id: 1, subId: 7 },
		]);
		const handle = await store.listen("users.u1", () => {});
		await flushPromises();
		expect(tracker.get(7)).toBeDefined();

		// Reconnect replay assigns a fresh server subId and remaps the tracker.
		tracker.reconnect(new Map([[7, 11]]));
		await handle.unlisten();
		await new Promise((resolve) => setTimeout(resolve, 350));

		expect(tracker.get(11)).toBeUndefined();
		expect(messages.at(-1)).toEqual({ type: "StoreUnsubscribe", subId: 11 });
	});

	test("subscribe handle follows the subId remapped by reconnect replay", async () => {
		const { store, tracker, messages } = makeStore(
			[{ type: "ok", id: 1, subId: 9, value: [] }],
			await makeReadySchema(),
		);
		const handle = await store.subscribe("users", {}, () => {});
		expect(tracker.get(9)).toBeDefined();

		tracker.reconnect(new Map([[9, 12]]));
		await handle.unsubscribe();
		await new Promise((resolve) => setTimeout(resolve, 350));

		expect(tracker.get(12)).toBeUndefined();
		expect(messages.at(-1)).toEqual({ type: "StoreUnsubscribe", subId: 12 });
	});

	test("subscribe delivers an acknowledged empty snapshot", async () => {
		const { store } = makeStore(
			[{ type: "ok", id: 1, subId: 9, value: [] }],
			await makeReadySchema(),
		);
		const snapshots: JsonValue[][] = [];
		const handle = await store.subscribe("users", {}, (value) =>
			snapshots.push(value),
		);

		expect(snapshots).toEqual([[]]);
		expect(handle.getSnapshot()).toEqual([]);
		await handle.unsubscribe();
	});

	test("subscribe registers collection view and loadMore dispatches cursor request", async () => {
		const { store, messages, responseTableIndexes } = makeStore(
			[
				{
					type: "ok",
					id: 1,
					subId: 9,
					value: [{ id: "u1", name: "Ada" }],
					hasMore: true,
					nextCursor: "next",
				},
				{
					type: "ok",
					id: 2,
					value: [{ id: "u2", name: "Grace" }],
					hasMore: false,
					nextCursor: null,
				},
			],
			await makeReadySchema(),
		);
		const snapshots: JsonValue[][] = [];

		const handle = await store.subscribe("users", {}, (value) =>
			snapshots.push(value),
		);
		await flushTimers();

		expect(handle.hasMore).toBe(true);
		expect(snapshots).toEqual([[{ id: "u1", name: "Ada" }]]);

		await handle.loadMore();
		await flushTimers();

		expect(messages[1]).toEqual({
			type: "StoreLoadMore",
			subId: 9,
			nextCursor: "next",
		});
		expect(responseTableIndexes[1]).toBe(0);
		expect(handle.hasMore).toBe(false);
		expect(snapshots.at(-1)).toEqual([
			{ id: "u1", name: "Ada" },
			{ id: "u2", name: "Grace" },
		]);
	});

	test("subscribe before the session is ready queues and dispatches on readiness", async () => {
		const { store, messages, errors } = makeStore(
			[{ type: "ok", id: 1, subId: 9, value: [] }],
			await makeReadySchema(),
			{ ready: false },
		);

		const pending = store.subscribe("users", {}, () => {});
		expect(messages).toHaveLength(0);
		expect(errors).toHaveLength(0);

		await store.markSessionReady();
		await pending;
		expect(messages[0]).toMatchObject({
			type: "StoreSubscribe",
			table_index: "users",
		});
	});

	test("rejectPending rejects queued registrations with CONNECTION_FAILED", async () => {
		const { store, messages, errors } = makeStore([], undefined, {
			ready: false,
		});

		const pending = store.subscribe("users", {}, () => {});
		store.rejectPending();

		await expect(pending).rejects.toMatchObject({
			code: "CONNECTION_FAILED",
		});
		expect(messages).toHaveLength(0);
		expect(errors).toHaveLength(0);
		// The establishment loop must be woken so it can observe `closed`
		// and exit, not parked on readySignal() forever.
		expect(
			(store as unknown as { readyWaiters: unknown[] }).readyWaiters,
		).toHaveLength(0);
	});

	test("two consumers of the same path share one server subscription", async () => {
		const { store, messages, tracker } = makeStore([
			{
				type: "ok",
				id: 1,
				subId: 7,
				value: [{ id: "u1", name: "Ada" }],
			},
		]);
		const first: JsonValue[] = [];
		const second: JsonValue[] = [];

		const h1 = await store.listen("users.u1", (value) => first.push(value));
		const h2 = await store.listen("users.u1", (value) => second.push(value));
		await flushPromises();

		expect(
			messages.filter((message) => message.type === "StoreSubscribe"),
		).toHaveLength(1);
		// The second consumer attaches locally and receives the retained snapshot.
		expect(second).toEqual([{ id: "u1", name: "Ada" }]);
		expect(tracker.get(7)?.callbacks).toHaveLength(2);

		await h1.unlisten();
		expect(tracker.get(7)).toBeDefined();

		await h2.unlisten();
		await new Promise((resolve) => setTimeout(resolve, 350));
		expect(messages.at(-1)).toEqual({ type: "StoreUnsubscribe", subId: 7 });
	});

	test("different fields of one document get separate projections", async () => {
		const record = { id: "u1", name: "Ada", email: "ada@example.com" };
		const { store, messages } = makeStore([
			{ type: "ok", id: 1, subId: 7, value: [record] },
			{ type: "ok", id: 2, subId: 8, value: [record] },
		]);
		const names: JsonValue[] = [];
		const emails: JsonValue[] = [];

		const nameHandle = await store.listen("users.u1.name", (value) =>
			names.push(value),
		);
		const emailHandle = await store.listen("users.u1.email", (value) =>
			emails.push(value),
		);
		await flushPromises();

		expect(
			messages.filter((message) => message.type === "StoreSubscribe"),
		).toHaveLength(2);
		expect(names).toEqual(["Ada"]);
		expect(emails).toEqual(["ada@example.com"]);
		expect(nameHandle.getSnapshot()).toBe("Ada");
		expect(emailHandle.getSnapshot()).toBe("ada@example.com");

		await nameHandle.unlisten();
		await emailHandle.unlisten();
	});

	test("reattaching within the grace window cancels the unsubscribe", async () => {
		const { store, messages } = makeStore([
			{
				type: "ok",
				id: 1,
				subId: 7,
				value: [{ id: "u1", name: "Ada" }],
			},
		]);
		const values: JsonValue[] = [];
		const subs = new Map<number, Promise<ListenHandle>>();

		const h1 = await store.listen("users.u1", () => {});
		await h1.unlisten();
		await new Promise((resolve) => setTimeout(resolve, 50));

		// The game's syncChunks guards with `if (!subs.has(key)) return`
		// before it stores the entry — the retained value must not fire
		// before store.listen() returns, or the guard eats it.
		const key = 1;
		const h2 = store.listen("users.u1", (value) => {
			if (!subs.has(key)) return;
			values.push(value);
		});
		subs.set(key, h2);

		// Past the original deadline the unsubscribe must never fire.
		await new Promise((resolve) => setTimeout(resolve, 350));

		expect(
			messages.filter((message) => message.type === "StoreUnsubscribe"),
		).toHaveLength(0);
		expect(values).toEqual([{ id: "u1", name: "Ada" }]);
		await (await h2).unlisten();
	});

	test("getSnapshot reads the retained value without a round trip", async () => {
		const { store, messages } = makeStore(
			[
				{
					type: "ok",
					id: 1,
					subId: 7,
					value: [{ id: "u1", name: "Ada" }],
				},
				{
					type: "ok",
					id: 2,
					subId: 9,
					value: [{ id: "u2", name: "Grace" }],
					hasMore: false,
					nextCursor: null,
				},
			],
			await makeReadySchema(),
		);

		const listenHandle = await store.listen("users.u1", () => {});
		const subscribeHandle = await store.subscribe("users", {}, () => {});
		await flushTimers();

		// A document listen snapshots the record itself; a collection
		// subscribe snapshots the materialized row array.
		expect(listenHandle.getSnapshot()).toEqual({ id: "u1", name: "Ada" });
		expect(subscribeHandle.getSnapshot()).toEqual([
			{ id: "u2", name: "Grace" },
		]);
		expect(messages).toHaveLength(2);
	});

	test("loadMore rejection does not mutate pagination state", async () => {
		const schema = await makeReadySchema();
		const { store } = makeStore(
			[
				{
					type: "ok",
					id: 1,
					subId: 9,
					value: [{ id: "u1", name: "Ada" }],
					hasMore: true,
					nextCursor: "next",
				},
				new Error("Invalid positional store record"),
			],
			schema,
		);
		const snapshots: JsonValue[][] = [];
		const handle = await store.subscribe("users", {}, (value) =>
			snapshots.push(value),
		);
		await flushTimers();

		await expect(handle.loadMore()).rejects.toThrow(
			"Invalid positional store record",
		);
		expect(handle.hasMore).toBe(true);
		expect(snapshots).toEqual([[{ id: "u1", name: "Ada" }]]);
	});

	test("loadMore discards a page whose subscription was remapped mid-flight", async () => {
		const { store, tracker, conn } = makeStore(
			[
				{
					type: "ok",
					id: 1,
					subId: 9,
					value: [{ id: "u1", name: "Ada" }],
					hasMore: true,
					nextCursor: "next",
				},
			],
			await makeReadySchema(),
		);
		const handle = await store.subscribe("users", {}, () => {});
		await flushTimers();
		expect(handle.hasMore).toBe(true);

		// Hold the page response so the reconnect remap can land first.
		let release!: (ok: OkResponse) => void;
		const deferred = new Promise<OkResponse>((resolve) => {
			release = resolve;
		});
		const dispatch = conn.dispatch.bind(conn);
		let pendingMessage: OutboundRequest | undefined;
		conn.dispatch = async (msg, responseTableIndex) => {
			if (msg.type === "StoreLoadMore") {
				pendingMessage = msg;
				return deferred;
			}
			return dispatch(msg, responseTableIndex);
		};

		const loading = handle.loadMore();
		await flushPromises();
		expect(pendingMessage).toEqual({
			type: "StoreLoadMore",
			subId: 9,
			nextCursor: "next",
		});

		// Reconnect replay remaps the subscription while the page is pending.
		tracker.reconnect(new Map([[9, 12]]));
		release({
			type: "ok",
			id: 2,
			value: [{ id: "late", name: "Late" }],
			hasMore: false,
			nextCursor: null,
		});
		await loading;

		expect(handle.hasMore).toBe(true);
		expect(tracker.get(12)?.materializedView?.records.has("late")).toBe(false);
	});

	test("every write kind goes through dispatchWrite", async () => {
		const { store, messages, conn } = makeStore();
		conn.dispatch = () => Promise.reject(new Error("writes must not dispatch"));

		await store.set("users.u1", { name: "Ada" });
		await store.remove("users.u1");
		await store.increment("users.u1.age", 1);
		await store.create("users", { name: "Bo" });
		await store.batch([{ op: "remove", path: "users.u2" }]);

		expect(messages.map((m) => m.type)).toEqual([
			"StoreSet",
			"StoreRemove",
			"StoreBatch",
			"StoreSet",
			"StoreBatch",
		]);
	});

	test("an un-awaited failing write emits on error without an unhandled rejection", async () => {
		const { store, errors } = makeStore([
			new Error("set failed"),
			new Error("create failed"),
		]);
		const unhandled: unknown[] = [];
		const onUnhandled = (reason: unknown) => unhandled.push(reason);
		process.on("unhandledRejection", onUnhandled);
		try {
			void store.set("users.u1", { name: "Ada" });
			void store.create("users", { name: "Bo" });
			await flushTimers();
		} finally {
			process.off("unhandledRejection", onUnhandled);
		}

		expect(unhandled).toEqual([]);
		expect(errors).toMatchObject([
			{ message: "set failed" },
			{ message: "create failed" },
		]);
	});

	test("a delta that precedes its subscribe ack is applied after the snapshot", async () => {
		const { store, tracker, conn } = makeStore([], await makeReadySchema());
		// The server registered subId 7 and pushed a delta before the ack, whose
		// snapshot was read before that commit.
		conn.dispatch = async () => {
			tracker.dispatch({
				type: "StoreDelta",
				subId: 7,
				ops: [
					{
						op: "set",
						path: ["users", "u1"],
						value: { id: "u1", name: "Ada" },
					},
				],
			});
			return { type: "ok", id: 1, subId: 7, value: [] };
		};

		const handle = await store.subscribe("users", {}, () => {});
		await flushTimers();

		expect(handle.getSnapshot()).toEqual([{ id: "u1", name: "Ada" }]);
		await handle.unsubscribe();
	});

	test("an early delta for a subscription awaiting its ack is applied to the snapshot", async () => {
		const { store, tracker, conn } = makeStore([], await makeReadySchema());
		let releaseFirst!: (ok: OkResponse) => void;
		let releaseSecond!: (ok: OkResponse) => void;
		const firstAck = new Promise<OkResponse>((resolve) => {
			releaseFirst = resolve;
		});
		const secondAck = new Promise<OkResponse>((resolve) => {
			releaseSecond = resolve;
		});
		let dispatchCount = 0;
		conn.dispatch = async () => {
			dispatchCount += 1;
			return dispatchCount === 1 ? firstAck : secondAck;
		};

		const first = store.subscribe("users", {}, () => {});
		const second = store.subscribe("users", { limit: 5 }, () => {});
		await flushPromises();

		// The server pushes subId 8's delta before either ack reveals its subId.
		tracker.dispatch({
			type: "StoreDelta",
			subId: 8,
			ops: [
				{
					op: "set",
					path: ["users", "u1"],
					value: { id: "u1", name: "Old" },
				},
			],
		});

		releaseFirst({ type: "ok", id: 1, subId: 7, value: [] });
		const firstHandle = await first;
		releaseSecond({ type: "ok", id: 2, subId: 8, value: [] });
		const secondHandle = await second;
		await flushTimers();

		expect(secondHandle.getSnapshot()).toEqual([{ id: "u1", name: "Old" }]);
		await firstHandle.unsubscribe();
		await secondHandle.unsubscribe();
	});

	test("a resolved write has already delivered the deltas sent before it", async () => {
		const { store, tracker, conn } = makeStore(
			[{ type: "ok", id: 1, subId: 9, value: [] }],
			await makeReadySchema(),
		);
		const snapshots: JsonValue[][] = [];
		const handle = await store.subscribe("users", {}, (value) =>
			snapshots.push(value),
		);
		// The server pushes the write's delta, then its WriteCommitted.
		conn.dispatchWrite = async () => {
			tracker.dispatch({
				type: "StoreDelta",
				subId: 9,
				ops: [
					{
						op: "set",
						path: ["users", "u1"],
						value: { id: "u1", name: "Ada" },
					},
				],
			});
		};

		await store.set("users.u1", { name: "Ada" });

		expect(snapshots.at(-1)).toEqual([{ id: "u1", name: "Ada" }]);
		expect(handle.getSnapshot()).toEqual([{ id: "u1", name: "Ada" }]);
		await handle.unsubscribe();
	});

	test("a write that fails to build rejects and emits on error", async () => {
		const { store, messages, errors } = makeStore();

		await expect(store.set("users", { name: "Ada" })).rejects.toMatchObject({
			code: "INVALID_PATH",
		});
		expect(messages).toEqual([]);
		expect(errors).toHaveLength(1);
	});

	describe("required field validation", () => {
		async function setupSchemaWithRequiredFields() {
			const schema = new SchemaDictionary();
			await schema.processSchemaSync({
				version: "1.0.0",
				tables: ["posts"],
				fields: [
					[
						"id",
						"namespace_id",
						"owner_id",
						"title",
						"body",
						"address__city",
						"created_at",
						"updated_at",
					],
				],
				fieldFlags: [
					[
						0b01, // id: system
						0b01, // namespace_id: system
						0b01, // owner_id: system
						0b100, // title: required
						0b00, // body: not required
						0b100, // address__city: required (nested)
						0b01, // created_at: system
						0b01, // updated_at: system
					],
				],
			});
			return schema;
		}

		test("create throws SCHEMA_VALIDATION_FAILED when required fields are missing", async () => {
			const schema = await setupSchemaWithRequiredFields();
			const { store } = makeStore([], schema);

			await expect(
				store.create("posts", { body: "Hello" }),
			).rejects.toMatchObject({
				code: "SCHEMA_VALIDATION_FAILED",
				message: "Missing required field(s): title, address.city",
			});
		});

		test("create includes missingFields in error details", async () => {
			const schema = await setupSchemaWithRequiredFields();
			const { store } = makeStore([], schema);

			try {
				await store.create("posts", { body: "Hello" });
				expect.fail("should have thrown");
			} catch (err) {
				expect(
					(err as { details?: { missingFields?: string[] } }).details,
				).toBeDefined();
				expect(
					(err as { details?: { missingFields?: string[] } }).details
						?.missingFields,
				).toEqual(["title", "address.city"]);
			}
		});

		test("create succeeds when all required fields are present", async () => {
			const schema = await setupSchemaWithRequiredFields();
			const { store, messages } = makeStore([], schema);

			const id = await store.create("posts", {
				title: "Hello",
				body: "World",
				address: { city: "London" },
			});

			expect(id).toBeDefined();
			expect(messages).toHaveLength(1);
			expect(messages[0]).toMatchObject({
				type: "StoreSet",
				path: ["posts", id],
			});
		});

		test("create with nested required field shows dot notation in error", async () => {
			const schema = await setupSchemaWithRequiredFields();
			const { store } = makeStore([], schema);

			await expect(
				store.create("posts", { title: "Hello" }),
			).rejects.toMatchObject({
				message: "Missing required field(s): address.city",
			});
		});

		test("set does NOT validate required fields", async () => {
			const schema = await setupSchemaWithRequiredFields();
			const { store, messages } = makeStore([], schema);

			await store.set("posts.p1", { body: "partial update" });

			expect(messages).toHaveLength(1);
			expect(messages[0]).toMatchObject({
				type: "StoreSet",
				path: ["posts", "p1"],
			});
		});

		test("create treats explicit undefined as missing", async () => {
			const schema = await setupSchemaWithRequiredFields();
			const { store } = makeStore([], schema);

			await expect(
				store.create("posts", {
					title: undefined as unknown as JsonValue,
					body: "Hello",
				}),
			).rejects.toMatchObject({
				code: "SCHEMA_VALIDATION_FAILED",
				message: expect.stringContaining("address.city"),
			});
		});

		test("create rejects null for required fields", async () => {
			const schema = await setupSchemaWithRequiredFields();
			const { store } = makeStore([], schema);

			await expect(
				store.create("posts", {
					title: null,
					body: "Hello",
					address: { city: "London" },
				}),
			).rejects.toMatchObject({
				code: "SCHEMA_VALIDATION_FAILED",
				message: expect.stringContaining("title"),
			});
		});

		test("create skips validation when schema is not ready", async () => {
			const schema = new SchemaDictionary();
			const { store, messages } = makeStore([], schema);

			const id = await store.create("posts", { anything: "goes" });

			expect(id).toBeDefined();
			expect(messages).toHaveLength(1);
		});

		test("set preserves Uint8Array payload without flattening", async () => {
			const { store, messages } = makeStore();
			const bytes = new Uint8Array([1, 2, 3, 4, 5]);

			await store.set("files.f1", { data: bytes, nested: { blob: bytes } });
			expect(messages).toHaveLength(1);
			expect(messages[0]).toMatchObject({
				type: "StoreSet",
				path: ["files", "f1"],
				value: {
					data: bytes,
					nested__blob: bytes,
				},
			});
		});
	});
});
