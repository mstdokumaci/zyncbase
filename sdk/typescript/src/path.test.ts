import { describe, expect, test } from "bun:test";
import * as fc from "fast-check";
import { ErrorCodes, ZyncBaseError } from "./errors";
import { decodeWirePath, encodeWirePath, normalizePath } from "./path";

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

/**
 * Property 16: Wire path encoding round-trip
 * Validates: Requirements 4.6, 4.7
 */
describe("encodeWirePath / decodeWirePath", () => {
	test("Property 16: round-trip — decodeWirePath(encodeWirePath(path)) deep-equals original for depth 3+", () => {
		fc.assert(
			fc.property(
				// Allow underscores in segments but avoid leading/trailing ones to prevent ambiguity with "__"
				// Also ensure segments don't contain "__" themselves.
				fc.array(
					fc
						.string({ minLength: 1 })
						.filter(
							(s) =>
								!s.includes("__") &&
								!s.includes(".") &&
								!s.startsWith("_") &&
								!s.endsWith("_"),
						),
					{ minLength: 3 },
				),
				(path) => {
					const encoded = encodeWirePath(path);
					const decoded = decodeWirePath(encoded);
					expect(decoded).toEqual(path);
				},
			),
			{ numRuns: 100 },
		);
	});

	test("Property 16: explicit underscore preservation — ['tasks', '1', 'must_be_complete', 'before'] → ['tasks', '1', 'must_be_complete__before']", () => {
		const path = ["tasks", "1", "must_be_complete", "before"];
		const encoded = encodeWirePath(path);
		expect(encoded).toEqual(["tasks", "1", "must_be_complete__before"]);
		expect(decodeWirePath(encoded)).toEqual(path);
	});

	test("Property 16: depth-1 paths are returned unchanged by encodeWirePath", () => {
		fc.assert(
			fc.property(
				fc.array(
					fc.string({ minLength: 1 }).filter((s) => !s.includes("__")),
					{ minLength: 1, maxLength: 1 },
				),
				(path) => {
					expect(encodeWirePath(path)).toEqual(path);
				},
			),
			{ numRuns: 100 },
		);
	});

	test("Property 16: depth-2 paths are returned unchanged by encodeWirePath", () => {
		fc.assert(
			fc.property(
				fc.array(
					fc.string({ minLength: 1 }).filter((s) => !s.includes("__")),
					{ minLength: 2, maxLength: 2 },
				),
				(path) => {
					expect(encodeWirePath(path)).toEqual(path);
				},
			),
			{ numRuns: 100 },
		);
	});
});
