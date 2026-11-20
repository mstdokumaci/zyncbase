import { describe, expect, test } from "bun:test";
import { compileWhere } from "./filter_eval.js";
import {
	FILTER_VECTOR_DOC_ID_FIELDS,
	FILTER_VECTOR_RECORDS,
	FILTER_VECTORS,
} from "./filter_eval.vectors.js";
import { encodeQueryOptions } from "./store_wire.js";

const isDocIdField = (field: string) => FILTER_VECTOR_DOC_ID_FIELDS.has(field);

describe("compileWhere", () => {
	for (const vector of FILTER_VECTORS) {
		test(vector.name, () => {
			const matches = compileWhere(
				encodeQueryOptions({ where: vector.where }),
				isDocIdField,
			);
			const ids = FILTER_VECTOR_RECORDS.filter(matches).map((r) => r.id);
			expect(ids.sort()).toEqual([...vector.expected].sort());
		});
	}

	test("a missing field reads as null", () => {
		const matches = compileWhere(
			encodeQueryOptions({ where: { score: { isNull: true } } }),
			isDocIdField,
		);
		expect(matches({ id: "x" })).toBe(true);
		expect(matches({ id: "x", score: 1 })).toBe(false);
	});

	test("array equality ignores order and duplicates on the record side", () => {
		const matches = compileWhere(
			encodeQueryOptions({ where: { tags: ["a", "b"] } }),
			isDocIdField,
		);
		expect(matches({ tags: ["b", "a", "b"] })).toBe(true);
	});
});
