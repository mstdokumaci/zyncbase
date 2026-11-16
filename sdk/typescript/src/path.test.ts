import { describe, expect, test } from "bun:test";
import * as fc from "fast-check";
import { ErrorCodes, ZyncBaseError } from "./errors";
import { fieldPathToFlat, flatten, normalizePath, unflatten } from "./path";

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
function expectInvalidPath(run: () => void): void {
	expect(run).toThrow(ZyncBaseError);
	try {
		run();
	} catch (e) {
		expect(e).toBeInstanceOf(ZyncBaseError);
		expect((e as ZyncBaseError).code).toBe(ErrorCodes.INVALID_PATH);
	}
}

describe("normalizePath", () => {
	test("Property 1: round-trip identity for 1-3 dot-free segments", () => {
		fc.assert(
			fc.property(
				fc.array(
					fc
						.string({ minLength: 1 })
						.filter((s) => !s.includes(".") && !s.includes("__")),
					{ minLength: 1, maxLength: 3 },
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

	test("Property 2: rejects arrays with at least one empty string segment", () => {
		fc.assert(
			fc.property(
				fc.array(fc.string(), { minLength: 1, maxLength: 2 }).chain((arr) =>
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

	test("collapses deep string paths into the third segment", () => {
		expect(normalizePath("users.u1.profile.address.city")).toEqual([
			"users",
			"u1",
			"profile.address.city",
		]);
	});

	test("accepts canonical 3-element arrays", () => {
		expect(normalizePath(["users", "u1", "profile.address.city"])).toEqual([
			"users",
			"u1",
			"profile.address.city",
		]);
	});

	test("rejects 4+ element arrays instead of joining them", () => {
		expectInvalidPath(() =>
			normalizePath(["users", "u1", "profile", "address"]),
		);
	});

	test("rejects empty field-path parts", () => {
		expectInvalidPath(() => normalizePath(["users", "u1", "profile..city"]));
		expectInvalidPath(() => normalizePath(["users", "u1", ""]));
		expectInvalidPath(() => normalizePath("users.u1.profile."));
	});

	test("rejects reserved double underscore in the field path", () => {
		expectInvalidPath(() => normalizePath(["users", "u1", "profile__address"]));
	});

	test("is idempotent", () => {
		const once = normalizePath("users.u1.profile.address.city");
		expect(normalizePath(once)).toEqual(once);
		expect(normalizePath(once.join("."))).toEqual(once);
	});

	test("rejects empty array and empty string", () => {
		expectInvalidPath(() => normalizePath([]));
		expectInvalidPath(() => normalizePath(""));
	});
});

describe("fieldPathToFlat", () => {
	test("converts a logical dotted field path to the flat schema form", () => {
		expect(fieldPathToFlat("address.city")).toBe("address__city");
		expect(fieldPathToFlat("profile.address.city")).toBe(
			"profile__address__city",
		);
		expect(fieldPathToFlat("name")).toBe("name");
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

	test("unflatten handles null-with-nested-key conflict without crashing", () => {
		expect(() => unflatten({ cursor: null, cursor__x: 100 })).not.toThrow();
		expect(unflatten({ cursor: null, cursor__x: 100 })).toEqual({
			cursor: { x: 100 },
		});
	});

	test("flatten does not decompose Uint8Array into indexed properties", () => {
		const bytes = new Uint8Array([1, 2, 3, 4]);
		const obj = { data: bytes, nested: { payload: bytes } };
		const flattened = flatten(obj);
		expect(flattened).toEqual({
			data: bytes,
			nested__payload: bytes,
		});
		expect(unflatten(flattened)).toEqual(obj);
	});
});
