import { describe, expect, test } from "bun:test";
import {
	cursorFromPresence,
	cursorToPresence,
	pickRelativePosition,
} from "./editor/cursor-presence";
import { assembleChanges } from "./history-data";
import { buildTree, positionAtEnd, positionBetween, siblingsOf } from "./pages";
import type { PageRow } from "./shared";

function page(
	id: string,
	position: number,
	parentId?: string,
): PageRow & { created_at: number } {
	return {
		id,
		title: id,
		position,
		compaction_version: 0,
		...(parentId ? { parent_id: parentId } : {}),
		created_at: 1,
	};
}

describe("page tree", () => {
	const rows = [
		page("root-b", 2000),
		page("root-a", 1000),
		page("child-2", 2000, "root-a"),
		page("child-1", 1000, "root-a"),
		page("grandchild", 1000, "child-1"),
		page("orphan", 500, "missing-parent"),
	];

	test("sorts roots and children, promotes orphans", () => {
		const tree = buildTree(rows);
		expect(tree.map((node) => node.page.id)).toEqual([
			"orphan",
			"root-a",
			"root-b",
		]);
		expect(tree[1]?.children.map((node) => node.page.id)).toEqual([
			"child-1",
			"child-2",
		]);
		expect(tree[1]?.children[0]?.children.map((node) => node.page.id)).toEqual([
			"grandchild",
		]);
	});

	test("siblings ignore grandchildren", () => {
		expect(siblingsOf(rows, "root-a").map((row) => row.id)).toEqual([
			"child-1",
			"child-2",
		]);
		expect(siblingsOf(rows, undefined).map((row) => row.id)).toEqual([
			"orphan",
			"root-a",
			"root-b",
		]);
	});
});

describe("positions", () => {
	test("append and insert between", () => {
		expect(positionAtEnd([])).toBe(1000);
		expect(positionAtEnd([page("a", 1000)])).toBe(2000);
		expect(positionBetween(page("a", 1000), page("b", 2000))).toBe(1500);
		expect(positionBetween(undefined, page("b", 2000))).toBe(1000);
		expect(positionBetween(page("a", 1000), undefined)).toBe(2000);
	});
});

describe("presence cursor", () => {
	const anchor = {
		type: { client: 4, clock: 9 },
		tname: "default",
		item: { client: 7, clock: 3 },
		assoc: 0,
	};
	// The form y-tiptap produces for a caret on an empty non-text node: a root
	// type ID and nothing else. Dropping it used to crash every peer.
	const emptyNode = { type: { client: 4, clock: 9 }, assoc: 0 };

	test("keeps every reference and nulls the absent leaves", () => {
		expect(cursorToPresence({ anchor, head: emptyNode })).toEqual({
			anchor: {
				type: { client: 4, clock: 9 },
				tname: "default",
				item: { client: 7, clock: 3 },
				assoc: 0,
			},
			head: {
				type: { client: 4, clock: 9 },
				tname: null,
				item: { client: null, clock: null },
				assoc: 0,
			},
		});
	});

	test("drops a position with no reference at all", () => {
		expect(pickRelativePosition({ assoc: 0 })).toBeNull();
		expect(pickRelativePosition(null)).toBeNull();
		expect(
			cursorToPresence({ anchor: { assoc: 0 }, head: emptyNode }),
		).toBeNull();
	});

	test("restores awareness state from presence", () => {
		expect(
			cursorFromPresence({
				anchor: {
					type: { client: 4, clock: 9 },
					tname: "default",
					item: { client: 7, clock: 3 },
					assoc: 0,
				},
				head: {
					type: { client: 4, clock: 9 },
					tname: null,
					item: { client: null, clock: null },
					assoc: 0,
				},
			}),
		).toEqual({
			anchor: {
				type: { client: 4, clock: 9 },
				tname: "default",
				item: { client: 7, clock: 3 },
				assoc: 0,
			},
			head: { type: { client: 4, clock: 9 }, assoc: 0 },
		});
	});

	test("omits a cursor that cannot be placed", () => {
		expect(cursorFromPresence(null)).toBeNull();
		expect(
			cursorFromPresence({
				anchor: { assoc: 0 },
				head: { assoc: 0 },
			}),
		).toBeNull();
		expect(cursorToPresence({})).toBeNull();
	});
});

describe("history assembly", () => {
	const base = {
		id: "row-1",
		document_id: "p1",
		update_id: "u1",
		part: 0,
		parts: 1,
		data: new Uint8Array([1, 2, 3]),
		created_at: 10,
	};

	test("single-part payloads are complete on arrival", () => {
		expect(assembleChanges([base])).toEqual([
			{ at: 10, bytes: new Uint8Array([1, 2, 3]) },
		]);
	});

	test("multi-part payloads need every part and a commit row", () => {
		const rows = [
			{
				...base,
				parts: 2,
				part: 0,
				data: new Uint8Array([1, 2]),
				update_id: "u2",
			},
			{
				...base,
				parts: 2,
				part: 1,
				data: new Uint8Array([3]),
				update_id: "u2",
			},
			{ ...base, parts: 2, part: 2, data: undefined, update_id: "u2" },
		];
		expect(assembleChanges(rows)).toEqual([]);
		const committed = rows.map((row, index) =>
			index === 2 ? { ...row, committed: true } : row,
		);
		expect(assembleChanges(committed)).toEqual([
			{ at: 10, bytes: new Uint8Array([1, 2, 3]) },
		]);
	});
});
