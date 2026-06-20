import { describe, expect, test } from "bun:test";
import type { OutboundRequest } from "./connection_wire.js";
import { SchemaDictionary } from "./schema_dictionary.js";
import { type StoreConnection, StoreImpl } from "./store.js";
import { SubscriptionTracker } from "./subscriptions.js";
import type {
	InboundMessage,
	JsonValue,
	LifecycleEvent,
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
) {
	const messages: OutboundRequest[] = [];
	const errors: unknown[] = [];
	const pendingResponses = [...responses];
	let messageHandler: ((msg: InboundMessage) => void) | null = null;
	const disconnectHandlers: Array<() => void> = [];

	const schema = schemaDictionary ?? new SchemaDictionary();

	const conn: StoreConnection = {
		dispatch: async (msg: OutboundRequest): Promise<OkResponse> => {
			messages.push(msg);
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
		schemaDictionary: schema,
	};

	const tracker = new SubscriptionTracker();
	const store = new StoreImpl(conn, tracker, (err) => errors.push(err));

	/** Simulate a server push arriving on the WebSocket. */
	const push = (msg: InboundMessage) => messageHandler?.(msg);
	/** Simulate a disconnect event. */
	const disconnect = () => {
		for (const h of disconnectHandlers) h();
	};

	return { store, tracker, messages, errors, conn, push, disconnect, schema };
}

async function flushPromises(): Promise<void> {
	await Promise.resolve();
	await Promise.resolve();
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
				value: [{ name: "Ada", address__city: "London" }],
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

		const unlisten = store.listen("users.u1", (value) => values.push(value));
		await flushPromises();

		expect(messages[0]).toEqual({
			type: "StoreSubscribe",
			table_index: "users",
			conditions: [["id", 0, "u1"]],
		});
		expect(values).toEqual([{ id: "u1", name: "Ada" }]);

		unlisten();
		expect(messages[1]).toEqual({ type: "StoreUnsubscribe", subId: 7 });
	});

	test("subscribe registers collection view and loadMore dispatches cursor request", async () => {
		const { store, messages } = makeStore([
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
		]);
		const snapshots: JsonValue[][] = [];

		const handle = store.subscribe("users", {}, (value) =>
			snapshots.push(value),
		);
		await flushPromises();

		expect(handle.hasMore).toBe(true);
		expect(snapshots).toEqual([[{ id: "u1", name: "Ada" }]]);

		await handle.loadMore();

		expect(messages[1]).toEqual({
			type: "StoreLoadMore",
			subId: 9,
			nextCursor: "next",
			table_index: "users",
		});
		expect(handle.hasMore).toBe(false);
		expect(snapshots.at(-1)).toEqual([
			{ id: "u1", name: "Ada" },
			{ id: "u2", name: "Grace" },
		]);
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
	});
});
