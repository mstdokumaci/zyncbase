import { describe, expect, test } from "bun:test";
import { SchemaDictionary } from "./schema_dictionary.js";
import { type StoreConnection, StoreImpl } from "./store.js";
import { SubscriptionTracker } from "./subscriptions.js";
import type {
	InboundMessage,
	JsonValue,
	LifecycleEvent,
	OkResponse,
	QueryOptions,
} from "./types.js";

/**
 * Flags: 0b01 system, 0b10 doc-id/reference, 0b100 required.
 * Table "items": id(system+doc+req), name(req), score(req), ref(doc+req), opt(optional).
 */
async function makeReadySchema(): Promise<SchemaDictionary> {
	const schema = new SchemaDictionary();
	await schema.processSchemaSync({
		tables: ["items"],
		fields: [["id", "name", "score", "ref", "opt"]],
		fieldFlags: [[7, 4, 4, 6, 0]],
	});
	return schema;
}

function makeStore(schema: SchemaDictionary) {
	const messages: unknown[] = [];

	const conn: StoreConnection = {
		dispatch: async (msg) => {
			messages.push(msg);
			return { type: "ok", id: 1 };
		},
		onMessage: (_handler) => {},
		on: (_event: LifecycleEvent, _handler: (...args: unknown[]) => void) => {},
		isSchemaReady: () => schema.isReady(),
		schemaDictionary: schema,
	};

	// Deltas reach the tracker exactly as client.ts wires them.
	const tracker = new SubscriptionTracker();
	const store = new StoreImpl(conn, tracker);
	const push = (msg: InboundMessage) =>
		tracker.dispatch(msg as Parameters<SubscriptionTracker["dispatch"]>[0]);

	return { store, tracker, messages, push, conn };
}

async function subscribeAndCollect(
	store: StoreImpl,
	options: QueryOptions,
): Promise<JsonValue[][]> {
	const snapshots: JsonValue[][] = [];
	// Subscribe with a stubbed dispatch: swap in a one-shot ok response.
	const conn = (store as unknown as { conn: StoreConnection }).conn;
	conn.dispatch = async () => ({
		type: "ok",
		id: 1,
		subId: 5,
		value: [],
		hasMore: false,
		nextCursor: null,
	});
	store.subscribe("items", options, (value) => snapshots.push(value));
	await new Promise((resolve) => setTimeout(resolve, 0));
	return snapshots;
}

function setOp(id: string, fields: Record<string, JsonValue>): InboundMessage {
	return {
		type: "StoreDelta",
		subId: 5,
		ops: [{ op: "set", path: ["items", id], value: fields }],
	};
}

function idsOf(snapshot: JsonValue[]): string[] {
	return (snapshot as Record<string, JsonValue>[]).map((r) => r.id as string);
}

describe("materialized-view comparator", () => {
	test("default subscription order matches packed id ASC across short and UUIDv7 IDs", async () => {
		const schema = await makeReadySchema();
		const { store, push } = makeStore(schema);
		const snapshots = await subscribeAndCollect(store, {});

		// Short IDs pack below the UUIDv7 family tag bit, so they come first.
		push(setOp("b-uuid-v7-doc", { name: "x" }));
		push(
			setOp("019c1e50-7d11-7abc-9def-0123456789ab", {
				name: "y",
			}),
		);
		push(setOp("aardvark", { name: "z" }));
		push(setOp("INVALID", { name: "invalid" }));
		await new Promise((resolve) => setTimeout(resolve, 0));

		expect(idsOf(snapshots.at(-1) as JsonValue[])).toEqual([
			"aardvark",
			"b-uuid-v7-doc",
			"019c1e50-7d11-7abc-9def-0123456789ab",
			"INVALID",
		]);
	});

	test("multi-key mixed-direction clauses fall through in order", async () => {
		const schema = await makeReadySchema();
		const { store, push } = makeStore(schema);
		const snapshots = await subscribeAndCollect(store, {
			orderBy: [{ name: "asc" }, { score: "desc" }],
		});

		for (const [id, name, score] of [
			["r1", "same", 1],
			["r2", "same", 3],
			["r3", "same", 2],
			["r4", "other", 9],
		] as const) {
			push(setOp(id, { name, score }));
		}
		await new Promise((resolve) => setTimeout(resolve, 0));

		expect(idsOf(snapshots.at(-1) as JsonValue[])).toEqual([
			"r4",
			"r2",
			"r3",
			"r1",
		]);

		push(setOp("r1", { name: "aaa", score: 1 }));
		await new Promise((resolve) => setTimeout(resolve, 0));
		expect(idsOf(snapshots.at(-1) as JsonValue[])).toEqual([
			"r1",
			"r4",
			"r2",
			"r3",
		]);
	});

	test("captures the comparator before an async subscribe response", async () => {
		const schema = await makeReadySchema();
		const { store, push, conn } = makeStore(schema);
		let resolveSubscribe: (value: OkResponse) => void = () => {};
		conn.dispatch = () =>
			new Promise<OkResponse>((resolve) => {
				resolveSubscribe = resolve;
			});

		const options: QueryOptions = { orderBy: [{ score: "asc" }] };
		const snapshots: JsonValue[][] = [];
		store.subscribe("items", options, (rows) => snapshots.push(rows));
		options.orderBy = [{ score: "desc" }];
		resolveSubscribe({
			type: "ok",
			id: 1,
			subId: 5,
			value: [],
			hasMore: false,
			nextCursor: null,
		});
		await new Promise((resolve) => setTimeout(resolve, 0));

		push(setOp("r1", { score: 1 }));
		push(setOp("r2", { score: 2 }));
		await new Promise((resolve) => setTimeout(resolve, 0));
		expect(idsOf(snapshots.at(-1) as JsonValue[])).toEqual(["r1", "r2"]);
	});

	test("null is last for both ascending and descending directions", async () => {
		const schemaAsc = await makeReadySchema();
		const a = makeStore(schemaAsc);
		const ascSnaps = await subscribeAndCollect(a.store, {
			orderBy: [{ opt: "asc" }],
		});
		a.push(setOp("n1", { opt: null }));
		a.push(setOp("n2", { opt: "b" }));
		a.push(setOp("n3", { opt: "a" }));
		await new Promise((resolve) => setTimeout(resolve, 0));
		expect(idsOf(ascSnaps.at(-1) as JsonValue[])).toEqual(["n3", "n2", "n1"]);

		const schemaDesc = await makeReadySchema();
		const d = makeStore(schemaDesc);
		const descSnaps = await subscribeAndCollect(d.store, {
			orderBy: [{ opt: "desc" }],
		});
		d.push(setOp("n1", { opt: null }));
		d.push(setOp("n2", { opt: "b" }));
		d.push(setOp("n3", { opt: "a" }));
		await new Promise((resolve) => setTimeout(resolve, 0));
		expect(idsOf(descSnaps.at(-1) as JsonValue[])).toEqual(["n2", "n3", "n1"]);
	});

	test("text ordering matches SQLite BINARY (UTF-8), not UTF-16 code-unit order", async () => {
		const schema = await makeReadySchema();
		const { store, push } = makeStore(schema);
		const snapshots = await subscribeAndCollect(store, {
			orderBy: [{ name: "asc" }],
		});

		// U+10000 vs U+FFFD: UTF-8 byte order places U+10000 after U+FFFD,
		// while JavaScript's UTF-16 `<` claims the opposite.
		const bmpMax = "\uFFFD";
		const supplementaryMin = "\u{10000}";
		expect(supplementaryMin < bmpMax).toBe(true); // confirm JS divergence

		push(setOp("t1", { name: supplementaryMin }));
		push(setOp("t2", { name: bmpMax }));
		await new Promise((resolve) => setTimeout(resolve, 0));

		expect(idsOf(snapshots.at(-1) as JsonValue[])).toEqual(["t2", "t1"]);
	});

	test("reference fields compare by packed DocId order", async () => {
		const schema = await makeReadySchema();
		const { store, push } = makeStore(schema);
		const snapshots = await subscribeAndCollect(store, {
			orderBy: [{ ref: "asc" }],
		});

		push(setOp("ref1", { ref: "zzz-short" }));
		push(setOp("ref2", { ref: "019c1e50-7d11-7abc-9def-0123456789ab" }));
		push(setOp("ref3", { ref: "aaa-short" }));
		push(setOp("ref4", { ref: "INVALID" }));
		await new Promise((resolve) => setTimeout(resolve, 0));

		expect(idsOf(snapshots.at(-1) as JsonValue[])).toEqual([
			"ref3",
			"ref1",
			"ref2",
			"ref4",
		]);
	});
});
