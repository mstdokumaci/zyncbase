import { describe, expect, test } from "bun:test";
import * as fc from "fast-check";
import { ErrorCodes, ZyncBaseError } from "./errors";
import { flatten, normalizePath, unflatten } from "./path";

function hasNoEmptyObjects(val: unknown): boolean {
	if (val === null || typeof val !== "object" || Array.isArray(val))
		return true;
	const obj = val as Record<string, unknown>;
	if (Object.keys(obj).length === 0) return false;
	return Object.values(obj).every(hasNoEmptyObjects);
}

/**
 * Property 1: Path round-trip identity
 * Validates: Requirements 4.1, 4.2, 4.5
 */
describe("normalizePath", () => {
	test("Property 1: round-trip identity — normalizePath(segments.join('.')).join('.') === segments.join('.')", () => {
		fc.assert(
			fc.property(
				fc.array(
					fc.string({ minLength: 1 }).filter((s) => !s.includes(".")),
					{ minLength: 1 },
				),
				(segments) => {
					const joined = segments.join(".");
					const result = normalizePath(joined).join(".");
					return result === joined;
				},
			),
			{ numRuns: 100 },
		);
	});

	/**
	 * Property 2: Path normalization rejects invalid inputs
	 * Validates: Requirements 4.3, 4.4
	 */
	test("Property 2: rejects arrays with at least one empty string segment", () => {
		fc.assert(
			fc.property(
				fc.array(fc.string()).chain((arr) =>
					fc.integer({ min: 0, max: arr.length }).map((insertAt) => {
						const withEmpty = [...arr];
						withEmpty.splice(insertAt, 0, "");
						return withEmpty;
					}),
				),
				(segments) => {
					let threw = false;
					try {
						normalizePath(segments);
					} catch (e) {
						if (
							e instanceof ZyncBaseError &&
							e.code === ErrorCodes.INVALID_PATH
						) {
							threw = true;
						}
					}
					return threw;
				},
			),
			{ numRuns: 100 },
		);
	});

	test("Property 2: rejects empty array", () => {
		expect(() => normalizePath([])).toThrow(ZyncBaseError);
		try {
			normalizePath([]);
		} catch (e) {
			expect(e).toBeInstanceOf(ZyncBaseError);
			expect((e as ZyncBaseError).code).toBe(ErrorCodes.INVALID_PATH);
		}
	});

	test("Property 2: rejects empty string", () => {
		expect(() => normalizePath("")).toThrow(ZyncBaseError);
		try {
			normalizePath("");
		} catch (e) {
			expect(e).toBeInstanceOf(ZyncBaseError);
			expect((e as ZyncBaseError).code).toBe(ErrorCodes.INVALID_PATH);
		}
	});
});

describe("flatten / unflatten", () => {
	test("Property 14: unflatten(flatten(obj)) deep-equals the original for objects with primitive leaf values", () => {
		fc.assert(
			fc.property(
				fc
					.object({
						key: fc
							.string({ minLength: 1 })
							.filter((key) => !key.includes("_")),
						values: [
							fc.string(),
							fc.integer(),
							fc.boolean(),
							fc.constant(null),
						],
					})
					.filter(hasNoEmptyObjects),
				(obj) => {
					const typedObj = obj as Record<string, import("./types").JsonValue>;
					expect(unflatten(flatten(typedObj))).toEqual(typedObj);
				},
			),
			{ numRuns: 100 },
		);
	});
});
