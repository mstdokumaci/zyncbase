import { describe, expect, test } from "bun:test";
import * as fc from "fast-check";
import {
	ErrorCodes,
	toConnectionError,
	toZyncError,
	ZyncBaseError,
} from "./errors";

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

describe("toZyncError", () => {
	test("passes a ZyncBaseError through unchanged", () => {
		const original = new ZyncBaseError("already normalized", {
			code: ErrorCodes.RATE_LIMITED,
			category: "rate_limit",
			retryable: true,
		});
		expect(toZyncError(original, "fallback")).toBe(original);
	});

	test("wraps an Error as a retryable INTERNAL_ERROR", () => {
		const error = toZyncError(new Error("boom"), "fallback");
		expect(error).toMatchObject({
			code: ErrorCodes.INTERNAL_ERROR,
			category: "server",
			retryable: true,
			message: "boom",
		});
	});

	test("uses the fallback message for non-Error values and honors retryable=false", () => {
		expect(toZyncError("nope", "fallback")).toMatchObject({
			message: "fallback",
			retryable: true,
		});
		expect(toZyncError(null, "fallback", false)).toMatchObject({
			code: ErrorCodes.INTERNAL_ERROR,
			retryable: false,
		});
	});
});

describe("toConnectionError", () => {
	test("passes a ZyncBaseError through unchanged", () => {
		const original = new ZyncBaseError("already normalized", {
			code: ErrorCodes.AUTH_FAILED,
			category: "authentication",
			retryable: false,
		});
		expect(toConnectionError(original, "fallback")).toBe(original);
	});

	test("wraps an Error as a retryable CONNECTION_FAILED", () => {
		expect(
			toConnectionError(new Error("socket died"), "fallback"),
		).toMatchObject({
			code: ErrorCodes.CONNECTION_FAILED,
			category: "network",
			retryable: true,
			message: "socket died",
		});
		expect(toConnectionError(undefined, "fallback").message).toBe("fallback");
	});
});
