import { describe, expect, test } from "bun:test";
import type { OutboundRequest } from "./connection_wire.js";
import { SchemaDictionary } from "./schema_dictionary.js";
import { type StoreConnection, StoreImpl } from "./store.js";
import { SubscriptionTracker } from "./subscriptions.js";
import type {
	InboundMessage,
	JsonValue,
	LifecycleEvent,
	ListenHandle,
	OkResponse,
} from "./types.js";

/** Extract writeId from a write message. Only StoreSet/StoreRemove/StoreBatch carry it. */
function writeIdOf(msg: OutboundRequest): string | undefined {
	if (
		msg.type === "StoreSet" ||
		msg.type === "StoreRemove" ||
		msg.type === "StoreBatch"
	) {
		return msg.writeId;
	}
	return undefined;
}

/**
 * Overrides conn.dispatch to capture the writeId from the outgoing message,
 * then pushes `serverResponse(writeId)` asynchronously after `delayMs`.
 * Throws if the message carries no writeId (test misconfiguration).
 */
function makeCommittedDispatch(
	conn: StoreConnection,
	push: (msg: InboundMessage) => void,
	serverResponse: (writeId: string) => InboundMessage,
	delayMs = 0,
): void {
	conn.dispatch = async (msg) => {
		const writeId = writeIdOf(msg);
		if (!writeId)
			throw new Error("makeCommittedDispatch: message has no writeId");
		setTimeout(() => push(serverResponse(writeId)), delayMs);
		return { type: "ok", id: 1 };
	};
}

function makeStore(
	responses: Array<OkResponse | Error> = [],
	schemaDictionary?: SchemaDictionary,
	options: { ready?: boolean } = {},
) {
	const messages: OutboundRequest[] = [];
	const responseTableIndexes: Array<number | undefined> = [];
	const errors: unknown[] = [];
	const pendingResponses = [...responses];
	let messageHandler: ((msg: InboundMessage) => void) | null = null;
	const disconnectHandlers: Array<() => void> = [];

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
		onMessage: (handler) => {
			messageHandler = handler;
		},
		on: (event: LifecycleEvent, handler: (...args: unknown[]) => void) => {
			if (event === "disconnected")
				disconnectHandlers.push(handler as () => void);
		},
		isSchemaReady: () => schema.isReady(),
		schemaDictionary: schema,
	};

	const tracker = new SubscriptionTracker();
	const store = new StoreImpl(conn, tracker, (err) => errors.push(err));
	if (options.ready !== false) void store.markSessionReady();

	/** Simulate a server push arriving on the WebSocket. */
	const push = (msg: InboundMessage) => messageHandler?.(msg);
	/** Simulate a disconnect event. */
	const disconnect = () => {
		for (const h of disconnectHandlers) h();
	};

	return {
		store,
		tracker,
		messages,
		responseTableIndexes,
		errors,
		conn,
		push,
		disconnect,
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
		await new Promise((resolve) => setTimeout(resolve, 150));
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
		await new Promise((resolve) => setTimeout(resolve, 150));

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
		await new Promise((resolve) => setTimeout(resolve, 150));

		expect(tracker.get(12)).toBeUndefined();
		expect(messages.at(-1)).toEqual({ type: "StoreUnsubscribe", subId: 12 });
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
		await new Promise((resolve) => setTimeout(resolve, 150));
		expect(messages.at(-1)).toEqual({ type: "StoreUnsubscribe", subId: 7 });
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
		await new Promise((resolve) => setTimeout(resolve, 150));

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

	test("set with confirm committed returns a promise that resolves on WriteCommitted event", async () => {
		const { store, conn, push } = makeStore();
		let capturedWriteId: string | undefined;

		conn.dispatch = async (msg) => {
			capturedWriteId = writeIdOf(msg);
			if (!capturedWriteId) throw new Error("missing writeId");
			const wid = capturedWriteId;
			setTimeout(() => push({ type: "WriteCommitted", writeId: wid }), 10);
			return { type: "ok", id: 1 };
		};

		const start = Date.now();
		await store.set("users.u1", { name: "Ada" }, { confirm: "committed" });

		expect(Date.now() - start).toBeGreaterThanOrEqual(10);
		expect(capturedWriteId).toBeDefined();
		expect(capturedWriteId?.length).toBe(32);
	});

	test("set with confirm committed rejects on WriteError event", async () => {
		const { store, conn, push } = makeStore();
		makeCommittedDispatch(
			conn,
			push,
			(writeId) => ({
				type: "WriteError",
				writeId,
				code: "ACCESS_DENIED",
				message: "auth predicate failed",
				phase: "write",
			}),
			10,
		);

		await expect(
			store.set("users.u1", { name: "Ada" }, { confirm: "committed" }),
		).rejects.toThrow("auth predicate failed");
	});

	test("WriteError carries phase and derives retryability from code", async () => {
		const { store, conn, push } = makeStore();
		makeCommittedDispatch(conn, push, (writeId) => ({
			type: "WriteError",
			writeId,
			code: "INTERNAL_ERROR",
			message: "storage failure",
			phase: "write",
		}));

		let capturedError: unknown;
		try {
			await store.set("users.u1", { name: "Ada" }, { confirm: "committed" });
		} catch (e) {
			capturedError = e;
		}

		expect((capturedError as { code?: string })?.code).toBe("INTERNAL_ERROR");
		expect((capturedError as { retryable?: boolean })?.retryable).toBe(true);
		expect(
			(capturedError as { details?: { phase?: string } })?.details?.phase,
		).toBe("write");
	});

	test("WriteError with batchIndex surfaces it in error details", async () => {
		const { store, conn, push } = makeStore();
		makeCommittedDispatch(conn, push, (writeId) => ({
			type: "WriteError",
			writeId,
			code: "PERMISSION_DENIED",
			message: "denied",
			phase: "write",
			batchIndex: 2,
		}));

		let capturedError: unknown;
		try {
			await store.batch(
				[
					{ op: "set", path: "users.u1", value: { name: "A" } },
					{ op: "set", path: "users.u2", value: { name: "B" } },
					{ op: "set", path: "users.u3", value: { name: "C" } },
				],
				{ confirm: "committed" },
			);
		} catch (e) {
			capturedError = e;
		}

		expect((capturedError as { code?: string })?.code).toBe(
			"PERMISSION_DENIED",
		);
		expect(
			(capturedError as { details?: { batchIndex?: number } })?.details
				?.batchIndex,
		).toBe(2);
	});

	test("remove with confirm committed resolves on WriteCommitted", async () => {
		const { store, conn, push } = makeStore();
		makeCommittedDispatch(conn, push, (writeId) => ({
			type: "WriteCommitted",
			writeId,
		}));

		await expect(
			store.remove("users.u1", { confirm: "committed" }),
		).resolves.toBeUndefined();
	});

	test("batch with confirm committed resolves on WriteCommitted", async () => {
		const { store, conn, push } = makeStore();
		makeCommittedDispatch(conn, push, (writeId) => ({
			type: "WriteCommitted",
			writeId,
		}));

		await expect(
			store.batch([{ op: "set", path: "users.u1", value: { name: "Ada" } }], {
				confirm: "committed",
			}),
		).resolves.toBeUndefined();
	});

	test("inFlightWrites are rejected with CONNECTION_FAILED on disconnect", async () => {
		const { store, disconnect } = makeStore();

		// Start a committed write — dispatch accepts it but WriteCommitted never arrives
		const writePromise = store.set(
			"users.u1",
			{ name: "Ada" },
			{ confirm: "committed" },
		);

		disconnect();

		await expect(writePromise).rejects.toMatchObject({
			code: "CONNECTION_FAILED",
		});
	});

	describe("required field validation", () => {
		async function setupSchemaWithRequiredFields() {
			const schema = new SchemaDictionary();
			await schema.processSchemaSync({
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
