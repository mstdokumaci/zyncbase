// Filter matching vectors shared by the evaluator unit test and the e2e
// conformance suite, which runs them against a live server.

import type { JsonValue, QueryOptions } from "./types.js";

export interface FilterVector {
	name: string;
	where: NonNullable<QueryOptions["where"]>;
	/** Matching record ids, in any order. */
	expected: string[];
}

/** The doc-id field of the vector collection; everything else is a plain value. */
export const FILTER_VECTOR_DOC_ID_FIELDS: ReadonlySet<string> = new Set(["id"]);

const UUID = "01936b2e-1e85-7000-8000-000000000005";
const ALL = ["r1", "r2", "r3", "r4", UUID];

export const FILTER_VECTOR_RECORDS: Array<
	{ id: string } & Record<string, JsonValue>
> = [
	{
		id: "r1",
		name: "Alpha",
		label: "\uff21",
		score: 10,
		ratio: 1.5,
		active: true,
		tags: ["a", "b"],
		meta: { rank: 1 },
	},
	{
		id: "r2",
		name: "alphabet",
		label: "\u{1f600}",
		score: 5,
		ratio: -2,
		active: false,
		tags: ["b"],
		meta: { rank: null },
	},
	{
		id: "r3",
		name: "Ärger",
		label: null,
		score: null,
		ratio: null,
		active: null,
		tags: null,
		meta: { rank: 3 },
	},
	{
		id: "r4",
		name: null,
		label: null,
		score: 0,
		ratio: 0,
		active: true,
		tags: [],
		meta: { rank: 2 },
	},
	{
		id: UUID,
		name: "beta_%",
		label: "a",
		score: 7,
		ratio: 0.5,
		active: false,
		tags: ["c"],
		meta: { rank: null },
	},
];

export const FILTER_VECTORS: FilterVector[] = [
	{
		name: "eq on text is case-sensitive",
		where: { name: "alpha" },
		expected: [],
	},
	{ name: "eq on text", where: { name: "Alpha" }, expected: ["r1"] },
	{
		name: "ne skips null",
		where: { score: { ne: 5 } },
		expected: ["r1", "r4", UUID],
	},
	{
		name: "lt skips null",
		where: { score: { lt: 6 } },
		expected: ["r2", "r4"],
	},
	{
		name: "gte on a real field",
		where: { ratio: { gte: 0 } },
		expected: ["r1", "r4", UUID],
	},
	{ name: "isNull", where: { score: { isNull: true } }, expected: ["r3"] },
	{
		name: "isNotNull",
		where: { name: { isNotNull: true } },
		expected: ["r1", "r2", "r3", UUID],
	},
	{
		name: "startsWith folds ASCII case",
		where: { name: { startsWith: "ALPHA" } },
		expected: ["r1", "r2"],
	},
	{
		name: "startsWith does not fold non-ASCII case",
		where: { name: { startsWith: "ä" } },
		expected: [],
	},
	{
		name: "startsWith matches non-ASCII exactly",
		where: { name: { startsWith: "Är" } },
		expected: ["r3"],
	},
	{
		name: "endsWith folds ASCII case",
		where: { name: { endsWith: "BET" } },
		expected: ["r2"],
	},
	{
		name: "contains treats % and _ literally",
		where: { name: { contains: "a_" } },
		expected: [UUID],
	},
	{
		name: "an empty needle matches every non-null text",
		where: { name: { startsWith: "" } },
		expected: ["r1", "r2", "r3", UUID],
	},
	{
		name: "contains on an array is exact membership",
		where: { tags: { contains: "a" } },
		expected: ["r1"],
	},
	{
		name: "contains on an array is case-sensitive",
		where: { tags: { contains: "A" } },
		expected: [],
	},
	{
		name: "eq on an array compares sets",
		where: { tags: ["b", "a"] },
		expected: ["r1"],
	},
	{ name: "eq on an empty array", where: { tags: [] }, expected: ["r4"] },
	{
		name: "ne on an array skips null",
		where: { tags: { ne: ["b"] } },
		expected: ["r1", "r4", UUID],
	},
	{ name: "in", where: { score: { in: [5, 0] } }, expected: ["r2", "r4"] },
	{
		name: "notIn skips null",
		where: { score: { notIn: [5] } },
		expected: ["r1", "r4", UUID],
	},
	{ name: "in [] matches nothing", where: { score: { in: [] } }, expected: [] },
	{
		name: "notIn [] matches everything, null included",
		where: { score: { notIn: [] } },
		expected: ALL,
	},
	{ name: "eq on a boolean", where: { active: false }, expected: ["r2", UUID] },
	{
		name: "gt on a boolean",
		where: { active: { gt: false } },
		expected: ["r1", "r4"],
	},
	{
		name: "nested field",
		where: { meta: { rank: { gte: 2 } } },
		expected: ["r3", "r4"],
	},
	{
		name: "text orders by UTF-8 bytes",
		where: { label: { gt: "\uff21" } },
		expected: ["r2"],
	},
	{
		name: "doc ids order short ids before UUIDs",
		where: { id: { gt: "r4" } },
		expected: [UUID],
	},
	{
		name: "doc ids order short ids by their characters",
		where: { id: { lt: "r2" } },
		expected: ["r1"],
	},
	{
		name: "or",
		where: { or: [{ score: 10 }, { name: { isNull: true } }] },
		expected: ["r1", "r4"],
	},
	{
		name: "and with or",
		where: { active: true, or: [{ score: 0 }, { tags: { contains: "a" } }] },
		expected: ["r1", "r4"],
	},
	{
		name: "an or branch with notIn [] always holds",
		where: { or: [{ score: 99 }, { score: { notIn: [] } }] },
		expected: ALL,
	},
	{
		name: "an or of only in [] matches nothing",
		where: { or: [{ score: { in: [] } }] },
		expected: [],
	},
];
