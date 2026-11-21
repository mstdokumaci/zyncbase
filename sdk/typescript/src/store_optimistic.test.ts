import { describe, expect, test } from "bun:test";
import type { OutboundRequest } from "./connection_wire.js";
import { SchemaDictionary } from "./schema_dictionary.js";
import { type StoreConnection, StoreImpl } from "./store.js";
import { SubscriptionTracker } from "./subscriptions.js";
import type { JsonValue, OkResponse, QueryOptions } from "./types.js";

type Row = Record<string, JsonValue>;

interface Delivery {
	rows: Row[];
	pending: ReadonlySet<string>;
}

interface Write {
	message: OutboundRequest;
	commit: () => void;
	fail: (err: unknown) => void;
}

const FIELDS = [
	"id",
	"namespace_id",
	"owner_id",
	"title",
	"status",
	"rank",
	"tags",
	"address__city",
	"address__zip",
	"created_at",
	"updated_at",
];

function row(id: string, fields: Row & { created_at: number }): Row {
	return {
		id,
		namespace_id: 1,
		owner_id: "me",
		title: null,
		status: null,
		rank: null,
		tags: null,
		address: { city: null, zip: null },
		updated_at: fields.created_at,
		...fields,
	};
}

const T1 = row("t1", { title: "one", status: "open", rank: 1, created_at: 10 });
const T2 = row("t2", { title: "two", status: "done", rank: 2, created_at: 20 });

async function makeStore() {
	const schema = new SchemaDictionary();
	await schema.processSchemaSync({
		version: "1.0.0",
		tables: ["todos"],
		fields: [FIELDS],
		fieldFlags: [[0b11, 0b01, 0b11, 0, 0, 0, 0, 0, 0, 0b01, 0b01]],
	});
	const writes: Write[] = [];
	const acks: OkResponse[] = [];
	const errors: unknown[] = [];
	const conn: StoreConnection = {
		dispatch: async () => acks.shift() ?? { type: "ok", id: 0 },
		dispatchWrite: (message) =>
			new Promise<void>((resolve, reject) => {
				writes.push({ message, commit: resolve, fail: reject });
			}),
		on: () => {},
		schemaDictionary: schema,
		userId: "me",
	};
	const tracker = new SubscriptionTracker();
	const store = new StoreImpl(conn, tracker, (err) => errors.push(err));
	await store.markSessionReady();

	let nextSubId = 1;
	const subscribe = async (
		options: QueryOptions,
		records: Row[] = [T1, T2],
	) => {
		const subId = nextSubId++;
		acks.push({ type: "ok", id: 0, subId, value: records });
		const deliveries: Delivery[] = [];
		const handle = await store.subscribe("todos", options, (rows, meta) => {
			deliveries.push({ rows: rows as Row[], pending: meta.pending });
		});
		await tick();
		return { subId, handle, deliveries };
	};
	const delta = (subId: number, record: Row) =>
		tracker.dispatch({
			type: "StoreDelta",
			subId,
			ops: [{ op: "set", path: ["todos", record.id as string], value: record }],
		});

	return { store, tracker, writes, acks, errors, subscribe, delta };
}

function tick(): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, 0));
}

function ids(delivery: Delivery | undefined): string[] {
	return (delivery?.rows ?? []).map((r) => r.id as string);
}

describe("optimistic writes", () => {
	test("a set shows synchronously, marked pending", async () => {
		const { store, subscribe } = await makeStore();
		const { handle, deliveries } = await subscribe({});

		void store.set("todos.t1", { title: "edited" });

		const last = deliveries.at(-1);
		expect(last?.rows[0]).toMatchObject({
			id: "t1",
			title: "edited",
			status: "open",
		});
		expect([...(last?.pending ?? [])]).toEqual(["t1"]);
		expect([...handle.pendingIds]).toEqual(["t1"]);
	});

	test("a commit whose delta is still batched delivers once, with the server row", async () => {
		const { store, writes, subscribe, delta } = await makeStore();
		const { subId, handle, deliveries } = await subscribe({});
		const done = store.set("todos.t1", { title: "edited" });
		expect(handle.pendingIds.has("t1")).toBe(true);
		const before = deliveries.length;

		delta(subId, { ...T1, title: "edited", updated_at: 11 });
		writes[0].commit();
		await done;

		expect(deliveries.length).toBe(before + 1);
		expect(deliveries.at(-1)?.rows[0]).toMatchObject({
			title: "edited",
			updated_at: 11,
		});
		expect(deliveries.at(-1)?.pending.size).toBe(0);
		expect(handle.pendingIds.size).toBe(0);
	});

	test("a failed write reverts and rejects", async () => {
		const { store, writes, errors, subscribe } = await makeStore();
		const { deliveries } = await subscribe({});
		const done = store.set("todos.t1", { title: "edited" });
		expect(deliveries.at(-1)?.rows[0]).toMatchObject({ title: "edited" });

		writes[0].fail(new Error("unique violation"));

		await expect(done).rejects.toMatchObject({ message: "unique violation" });
		expect(deliveries.at(-1)?.rows[0]).toBe(T1);
		expect(deliveries.at(-1)?.pending.size).toBe(0);
		expect(errors).toHaveLength(1);
	});

	test("a later write committing first settles the earlier one too", async () => {
		const { store, writes, subscribe, delta } = await makeStore();
		const { subId, deliveries } = await subscribe({});
		const first = store.set("todos.t1", { title: "first" });
		const second = store.set("todos.t1", { title: "second" });
		expect(deliveries.at(-1)?.rows[0]).toMatchObject({ title: "second" });
		expect(deliveries.at(-1)?.pending.has("t1")).toBe(true);

		delta(subId, { ...T1, title: "first", updated_at: 11 });
		delta(subId, { ...T1, title: "second", updated_at: 12 });
		writes[1].commit();
		await second;
		const settled = deliveries.length;
		expect(deliveries.at(-1)?.rows[0]).toMatchObject({ title: "second" });
		expect(deliveries.at(-1)?.pending.size).toBe(0);

		writes[0].commit();
		await first;
		expect(deliveries.length).toBe(settled);
	});

	test("optimistic: false and conditional writes wait for the server", async () => {
		const { store, subscribe } = await makeStore();
		const { deliveries } = await subscribe({});
		const before = deliveries.length;

		void store.set("todos.t1", { title: "a" }, { optimistic: false });
		void store.set("todos.t1", { title: "b" }, { if: { status: "open" } });
		void store.batch([{ op: "remove", path: "todos.t2" }], {
			optimistic: false,
		});

		expect(deliveries.length).toBe(before);
	});

	test("a write while the session is not ready is not shown", async () => {
		const { store, subscribe } = await makeStore();
		const { deliveries } = await subscribe({});
		const before = deliveries.length;

		store.markNotReady();
		void store.set("todos.t1", { title: "a" });

		expect(deliveries.length).toBe(before);
	});

	test("losing the session drops pending writes", async () => {
		const { store, subscribe } = await makeStore();
		const { deliveries } = await subscribe({});
		void store.set("todos.t1", { title: "a" });
		expect(deliveries.at(-1)?.rows[0]).toMatchObject({ title: "a" });

		store.markNotReady();

		expect(deliveries.at(-1)?.rows[0]).toBe(T1);
		expect(deliveries.at(-1)?.pending.size).toBe(0);
	});

	test("a pending edit moves a row out of a filtered view, and back on failure", async () => {
		const { store, writes, subscribe } = await makeStore();
		const { deliveries } = await subscribe({ where: { status: "open" } }, [T1]);
		void store.set("todos.t1", { status: "done" }).catch(() => {});

		expect(ids(deliveries.at(-1))).toEqual([]);

		writes[0].fail(new Error("denied"));
		await tick();
		expect(ids(deliveries.at(-1))).toEqual(["t1"]);
	});

	test("a pending edit moves a row into a view that did not hold it", async () => {
		const { store, subscribe } = await makeStore();
		await subscribe({});
		const open = await subscribe({ where: { status: "open" } }, [T1]);

		void store.set("todos.t2", { status: "open" });

		expect(ids(open.deliveries.at(-1))).toEqual(["t1", "t2"]);
		expect([...(open.deliveries.at(-1)?.pending ?? [])]).toEqual(["t2"]);
	});

	test("a create appears last, in matching views only", async () => {
		const { store, subscribe } = await makeStore();
		const open = await subscribe({ where: { status: "open" } }, [T1]);
		const done = await subscribe({ where: { status: "done" } }, [T2]);
		const doneCount = done.deliveries.length;

		void store.create("todos", { title: "new", status: "open" });

		const created = open.deliveries.at(-1)?.rows[1];
		expect(created).toMatchObject({
			title: "new",
			status: "open",
			owner_id: "me",
			rank: null,
		});
		expect(open.deliveries.at(-1)?.pending.has(created?.id as string)).toBe(
			true,
		);
		expect(done.deliveries.length).toBe(doneCount);
	});

	test("an OR view takes a row that matches one branch", async () => {
		const { store, subscribe } = await makeStore();
		await subscribe({});
		const view = await subscribe(
			{ where: { or: [{ status: "open" }, { rank: { gt: 5 } }] } },
			[T1],
		);

		void store.set("todos.t2", { rank: 9 });

		expect(ids(view.deliveries.at(-1))).toEqual(["t1", "t2"]);
	});

	test("a pending edit re-sorts the row by the view's order", async () => {
		const { store, subscribe } = await makeStore();
		const { deliveries } = await subscribe({ orderBy: [{ rank: "asc" }] });

		void store.set("todos.t1", { rank: 3 });

		expect(ids(deliveries.at(-1))).toEqual(["t2", "t1"]);
	});

	test("a commit that changes no value still clears the pending mark", async () => {
		const { store, writes, subscribe } = await makeStore();
		const { deliveries } = await subscribe({});
		const done = store.set("todos.t1", {
			title: "one",
			updated_at: T1.updated_at,
		});
		expect(deliveries.at(-1)?.pending.has("t1")).toBe(true);
		const before = deliveries.length;

		writes[0].commit();
		await done;

		expect(deliveries.length).toBe(before + 1);
		expect(deliveries.at(-1)?.pending.size).toBe(0);
	});

	test("arrays show as sorted sets and a null object clears its fields", async () => {
		const { store, subscribe } = await makeStore();
		const { deliveries } = await subscribe({}, [
			row("t1", {
				tags: ["x"],
				address: { city: "Oslo", zip: "0150" },
				created_at: 10,
			}),
		]);

		void store.set("todos.t1", { tags: ["b", "a", "b"], address: null });

		expect(deliveries.at(-1)?.rows[0]).toMatchObject({
			tags: ["a", "b"],
			address: { city: null, zip: null },
		});
	});

	test("an increment applies to the shown number", async () => {
		const { store, subscribe } = await makeStore();
		const { deliveries } = await subscribe({});

		void store.increment("todos.t2.rank", 5);

		expect(deliveries.at(-1)?.rows[1]).toMatchObject({ id: "t2", rank: 7 });
	});

	test("a listen delivers its first null value", async () => {
		const { store, acks } = await makeStore();
		acks.push({ type: "ok", id: 0, subId: 9, value: [] });
		const values: JsonValue[] = [];
		const handle = await store.listen("todos.missing", (value) =>
			values.push(value),
		);

		expect(values).toEqual([null]);
		expect(handle.getSnapshot()).toBeNull();
	});

	test("a listen does not apply an increment its delta already includes", async () => {
		const { store, writes, acks, tracker } = await makeStore();
		acks.push({ type: "ok", id: 0, subId: 9, value: [T2] });
		const values: Array<[JsonValue, boolean]> = [];
		await store.listen("todos.t2.rank", (value, meta) => {
			values.push([value, meta.pending]);
		});

		const done = store.increment("todos.t2.rank", 5);
		expect(values.at(-1)).toEqual([7, true]);

		tracker.dispatch({
			type: "StoreDelta",
			subId: 9,
			ops: [{ op: "set", path: ["todos", "t2"], value: { ...T2, rank: 7 } }],
		});
		expect(values.at(-1)).toEqual([7, true]);

		writes[0].commit();
		await done;
		expect(values.at(-1)).toEqual([7, false]);
	});

	test("a coalesced increment delta is not counted again by an earlier commit", async () => {
		const { store, writes, subscribe, delta } = await makeStore();
		const { subId, deliveries } = await subscribe({});

		const first = store.increment("todos.t2.rank", 1);
		const second = store.increment("todos.t2.rank", 1);
		expect(deliveries.at(-1)?.rows[1]).toMatchObject({ rank: 4 });

		delta(subId, { ...T2, rank: 4, updated_at: 21 });
		expect(deliveries.at(-1)?.rows[1]).toMatchObject({ rank: 4 });

		writes[0].commit();
		await first;
		expect(deliveries.at(-1)?.rows[1]).toMatchObject({ rank: 4 });

		writes[1].commit();
		await second;
		expect(deliveries.at(-1)?.rows[1]).toMatchObject({ rank: 4 });
	});

	test("a pending increment still applies to a base that predates it", async () => {
		const { store, subscribe, delta } = await makeStore();
		const { subId, deliveries } = await subscribe({});

		void store.increment("todos.t2.rank", 5);
		expect(deliveries.at(-1)?.rows[1]).toMatchObject({ rank: 7 });

		delta(subId, { ...T2, updated_at: 21 });
		expect(deliveries.at(-1)?.rows[1]).toMatchObject({ rank: 7 });
	});

	test("a listen shows a pending field write and clears its mark on commit", async () => {
		const { store, writes, acks, tracker } = await makeStore();
		acks.push({ type: "ok", id: 0, subId: 9, value: [T1] });
		const values: Array<[JsonValue, boolean]> = [];
		const handle = await store.listen("todos.t1.title", (value, meta) => {
			values.push([value, meta.pending]);
		});

		const done = store.set("todos.t1.title", "edited");
		expect(values.at(-1)).toEqual(["edited", true]);
		expect(handle.isPending).toBe(true);

		tracker.dispatch({
			type: "StoreDelta",
			subId: 9,
			ops: [
				{ op: "set", path: ["todos", "t1"], value: { ...T1, title: "edited" } },
			],
		});
		writes[0].commit();
		await done;
		expect(values.at(-1)).toEqual(["edited", false]);
		expect(handle.isPending).toBe(false);
	});

	test("a listen shows a pending remove as null", async () => {
		const { store, writes, acks } = await makeStore();
		acks.push({ type: "ok", id: 0, subId: 9, value: [T1] });
		const values: JsonValue[] = [];
		await store.listen("todos.t1", (value) => values.push(value));

		void store.remove("todos.t1").catch(() => {});
		expect(values.at(-1)).toBeNull();

		writes[0].fail(new Error("denied"));
		await tick();
		expect(values.at(-1)).toEqual(T1);
	});
});
