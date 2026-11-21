import { describe, expect, test } from "bun:test";
import {
	type OverlayContext,
	type OverlayOp,
	overlayOps,
	PendingWrites,
} from "./optimistic.js";
import { SchemaDictionary } from "./schema_dictionary.js";

const TODO_FIELDS = [
	"id",
	"namespace_id",
	"owner_id",
	"title",
	"count",
	"tags",
	"refs",
	"data",
	"address__city",
	"address__zip",
	"created_at",
	"updated_at",
];

async function makeContext(time = 100): Promise<OverlayContext> {
	const schema = new SchemaDictionary();
	await schema.processSchemaSync({
		version: "1.0.0",
		tables: ["todos", "users"],
		fields: [
			TODO_FIELDS,
			["id", "namespace_id", "owner_id", "name", "created_at", "updated_at"],
		],
		fieldFlags: [
			[0b11, 0b01, 0b11, 0, 0, 0, 0b10, 0, 0, 0, 0b01, 0b01],
			[0b11, 0b01, 0b11, 0, 0b01, 0b01],
		],
	});
	return { schema, userId: "me", time };
}

const BASE = {
	id: "t1",
	title: "old",
	count: 1,
	address: { city: "Oslo", zip: "0150" },
	updated_at: 5,
};

function set(
	id: string,
	patch: Record<string, string | number | null>,
): OverlayOp {
	return { kind: "set", collection: "todos", id, patch };
}

describe("PendingWrites.apply", () => {
	test("set merges into the server record", () => {
		const pending = new PendingWrites();
		pending.add([set("t1", { title: "new" })]);
		expect(pending.apply("todos", "t1", BASE)).toEqual({
			...BASE,
			title: "new",
		});
	});

	test("set on an unknown document shows nothing", () => {
		const pending = new PendingWrites();
		pending.add([set("t1", { title: "new" })]);
		expect(pending.apply("todos", "t1", null)).toBeNull();
	});

	test("a set after a pending create applies to the created row", () => {
		const pending = new PendingWrites();
		pending.add([
			{
				kind: "create",
				collection: "todos",
				id: "t1",
				record: { id: "t1", title: "a" },
			},
		]);
		pending.add([set("t1", { title: "b" })]);
		expect(pending.apply("todos", "t1", null)).toEqual({
			id: "t1",
			title: "b",
		});
	});

	test("remove hides the document", () => {
		const pending = new PendingWrites();
		pending.add([{ kind: "remove", collection: "todos", id: "t1" }]);
		expect(pending.apply("todos", "t1", BASE)).toBeNull();
	});

	test("increment applies only to a number", () => {
		const pending = new PendingWrites();
		const op: OverlayOp = {
			kind: "increment",
			collection: "todos",
			id: "t1",
			field: "count",
			by: 2,
			time: 9,
		};
		pending.add([op, { ...op, field: "title" }]);
		expect(pending.apply("todos", "t1", BASE)).toEqual({
			...BASE,
			count: 3,
			updated_at: 9,
		});
		expect(pending.apply("todos", "t1", { ...BASE, count: null })).toEqual({
			...BASE,
			count: null,
		});
	});

	test("increment reconciliation survives records without a revision", () => {
		const pending = new PendingWrites();
		const increment = (by: number): OverlayOp => ({
			kind: "increment",
			collection: "todos",
			id: "t1",
			field: "count",
			by,
			time: 9,
		});
		const base = { id: "t1", count: 0 };
		const first = pending.add([increment(1)]);
		pending.add([increment(1)]);

		expect(pending.apply("todos", "t1", base)).toMatchObject({ count: 2 });
		const committed = { ...base, count: 2 };
		expect(pending.apply("todos", "t1", committed)).toMatchObject({
			count: 2,
		});

		pending.commit(first);
		expect(pending.apply("todos", "t1", committed)).toMatchObject({
			count: 2,
		});
		expect(pending.apply("todos", "t1", base)).toMatchObject({ count: 1 });
	});

	test("writes apply in send order", () => {
		const pending = new PendingWrites();
		pending.add([set("t1", { title: "first" })]);
		pending.add([set("t1", { title: "second" })]);
		expect(pending.apply("todos", "t1", BASE)).toMatchObject({
			title: "second",
		});
	});
});

describe("PendingWrites settlement", () => {
	test("a commit settles every earlier write on the same documents", () => {
		const pending = new PendingWrites();
		pending.add([set("t1", { title: "a" }), set("t2", { title: "a" })]);
		const second = pending.add([set("t1", { title: "b" })]);
		const keys = pending.commit(second);
		expect(keys).toEqual(new Map([["todos", new Set(["t1"])]]));
		expect(pending.has("todos", "t1")).toBe(false);
		expect(pending.has("todos", "t2")).toBe(true);
	});

	test("a commit leaves later writes pending", () => {
		const pending = new PendingWrites();
		const first = pending.add([set("t1", { title: "a" })]);
		pending.add([set("t1", { title: "b" })]);
		pending.commit(first);
		expect(pending.apply("todos", "t1", BASE)).toMatchObject({ title: "b" });
	});

	test("a failure settles only that write", () => {
		const pending = new PendingWrites();
		pending.add([set("t1", { title: "a" })]);
		const second = pending.add([set("t1", { title: "b" })]);
		pending.fail(second);
		expect(pending.apply("todos", "t1", BASE)).toMatchObject({ title: "a" });
	});

	test("settling a cleared write is a no-op", () => {
		const pending = new PendingWrites();
		const entry = pending.add([set("t1", { title: "a" })]);
		expect(pending.clear()).toEqual(new Map([["todos", new Set(["t1"])]]));
		pending.commit(entry);
		expect(pending.has("todos", "t1")).toBe(false);
	});
});

describe("overlayOps", () => {
	test("conditional writes are never optimistic", async () => {
		const context = await makeContext();
		const ifWire = {
			conditions: [["title", 0, "x"]] as [string, number, string][],
		};
		expect(
			overlayOps(
				{ type: "StoreSet", path: ["todos", "t1"], value: {}, if: ifWire },
				false,
				context,
			),
		).toBeNull();
		expect(
			overlayOps(
				{ type: "StoreRemove", path: ["todos", "t1"], if: ifWire },
				false,
				context,
			),
		).toBeNull();
		expect(
			overlayOps(
				{
					type: "StoreBatch",
					ops: [
						["r", ["todos", "t1"]],
						["i", ["todos", "t2"], "count", 1, ifWire],
					],
				},
				false,
				context,
			),
		).toBeNull();
	});

	test("a set expands null namespaces, sorts arrays and bumps updated_at", async () => {
		const context = await makeContext(42);
		const ops = overlayOps(
			{
				type: "StoreSet",
				path: ["todos", "t1"],
				value: {
					address: null,
					address__zip: "1",
					tags: ["b", "a", "b"],
					refs: ["u2", "u10"],
				},
			},
			false,
			context,
		);
		expect(ops).toEqual([
			{
				kind: "set",
				collection: "todos",
				id: "t1",
				patch: {
					address__city: null,
					address__zip: "1",
					tags: ["a", "b"],
					refs: ["u10", "u2"],
					updated_at: 42,
				},
			},
		]);
	});

	test("a set copies byte buffers into the pending patch", async () => {
		const context = await makeContext(42);
		const bytes = new Uint8Array([1, 2, 3]);
		const [op] =
			overlayOps(
				{ type: "StoreSet", path: ["todos", "t1"], value: { data: bytes } },
				false,
				context,
			) ?? [];

		bytes[0] = 9;

		expect(op?.kind === "set" ? op.patch.data : null).toEqual(
			new Uint8Array([1, 2, 3]),
		);
		expect(op?.kind === "set" ? op.patch.data : null).not.toBe(bytes);
	});

	test("a create shapes a complete row with provisional system fields", async () => {
		const context = await makeContext(42);
		const [op] =
			overlayOps(
				{ type: "StoreSet", path: ["todos", "t1"], value: { title: "a" } },
				true,
				context,
			) ?? [];
		expect(op).toEqual({
			kind: "create",
			collection: "todos",
			id: "t1",
			record: {
				id: "t1",
				namespace_id: null,
				owner_id: "me",
				title: "a",
				count: null,
				tags: null,
				refs: null,
				data: null,
				address__city: null,
				address__zip: null,
				created_at: 42,
				updated_at: 42,
			},
		});
	});

	test("a created user owns itself", async () => {
		const context = await makeContext();
		const [op] =
			overlayOps(
				{ type: "StoreSet", path: ["users", "u1"], value: { name: "a" } },
				true,
				context,
			) ?? [];
		expect(op?.kind === "create" && op.record.owner_id).toBe("u1");
	});

	test("a batch becomes one op per write", async () => {
		const context = await makeContext(7);
		expect(
			overlayOps(
				{
					type: "StoreBatch",
					ops: [
						["s", ["todos", "t1"], { title: "a" }],
						["r", ["todos", "t2"]],
						["i", ["todos", "t3"], "count", 2],
					],
				},
				false,
				context,
			),
		).toEqual([
			{
				kind: "set",
				collection: "todos",
				id: "t1",
				patch: { title: "a", updated_at: 7 },
			},
			{ kind: "remove", collection: "todos", id: "t2" },
			{
				kind: "increment",
				collection: "todos",
				id: "t3",
				field: "count",
				by: 2,
				time: 7,
			},
		]);
	});
});
