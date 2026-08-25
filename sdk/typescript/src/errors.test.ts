import { describe, expect, test } from "bun:test";
import * as fc from "fast-check";
import { ErrorCodes, ZyncBaseError } from "./errors";

/**
 * Property 11: ZyncBaseError construction from server response
 * Validates: Requirements 9.2
 */
describe("ZyncBaseError", () => {
	test("Property 11: error.code and error.message match server response payload", () => {
		fc.assert(
			fc.property(
				fc.record({ code: fc.string(), message: fc.string() }),
				(payload) => {
					const error = ZyncBaseError.fromServerResponse(payload);
					return (
						error.code === payload.code && error.message === payload.message
					);
				},
			),
			{ numRuns: 100 },
		);
	});

	test("UNIQUE_CONSTRAINT_VIOLATED derives validation category and is non-retryable", () => {
		const error = ZyncBaseError.fromServerResponse({
			code: ErrorCodes.UNIQUE_CONSTRAINT_VIOLATED,
			message: "Unique constraint violated",
		});
		expect(error.code).toBe("UNIQUE_CONSTRAINT_VIOLATED");
		expect(error.category).toBe("validation");
		expect(error.retryable).toBe(false);
	});
});
