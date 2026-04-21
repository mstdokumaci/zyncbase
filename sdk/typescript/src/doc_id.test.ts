import { describe, expect, test } from "bun:test";
import { ErrorCodes, ZyncBaseError } from "./errors.js";
import { packDocId, unpackDocId } from "./doc_id.js";
import { generateUUIDv7 } from "./uuid.js";

function compareBytes(a: Uint8Array, b: Uint8Array): number {
	for (let i = 0; i < Math.min(a.length, b.length); i += 1) {
		if (a[i] !== b[i]) return a[i] - b[i];
	}
	return a.length - b.length;
}

describe("doc_id", () => {
	test("round-trips canonical UUIDv7 strings", () => {
		const id = generateUUIDv7();
		expect(unpackDocId(packDocId(id))).toBe(id);
	});

	test("round-trips short IDs", () => {
		expect(unpackDocId(packDocId("a"))).toBe("a");
		expect(unpackDocId(packDocId("abc_09-z"))).toBe("abc_09-z");
		expect(unpackDocId(packDocId("zzzzzzzzzzzzzzzzzzzzzzzz"))).toBe(
			"zzzzzzzzzzzzzzzzzzzzzzzz",
		);
	});

	test("preserves lexicographic order among short IDs", () => {
		const ordered = ["-", "0", "9", "_", "a", "aa", "ab", "b", "zz"];
		for (let i = 0; i < ordered.length - 1; i += 1) {
			const left = packDocId(ordered[i]);
			const right = packDocId(ordered[i + 1]);
			expect(compareBytes(left, right)).toBeLessThan(0);
		}
	});

	test("rejects invalid short IDs immediately", () => {
		const invalid = [
			"",
			"A",
			"has.dot",
			"contains/slash",
			"waytoolongwaytoolongwaytoolong",
		];
		for (const id of invalid) {
			expect(() => packDocId(id, ErrorCodes.INVALID_PATH)).toThrow(
				ZyncBaseError,
			);
			try {
				packDocId(id, ErrorCodes.INVALID_PATH);
			} catch (error) {
				expect((error as ZyncBaseError).code).toBe(ErrorCodes.INVALID_PATH);
			}
		}
	});
});
