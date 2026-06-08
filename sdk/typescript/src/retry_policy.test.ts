import { describe, expect, test } from "bun:test";
import { ErrorCodes, ZyncBaseError } from "./errors";
import { RetryPolicy } from "./retry_policy";

function makeError(code: string, retryAfter?: number): ZyncBaseError {
	return new ZyncBaseError("test error", {
		code,
		category: "test",
		retryable: code === ErrorCodes.RATE_LIMITED,
		retryAfter,
	});
}

describe("RetryPolicy", () => {
	describe("shouldRetry", () => {
		test("returns true for RATE_LIMITED by default", () => {
			const policy = new RetryPolicy({ url: "ws://localhost" });
			expect(policy.shouldRetry(makeError(ErrorCodes.RATE_LIMITED), 0)).toBe(
				true,
			);
		});

		test("returns true for RATE_LIMITED at any attempt (infinite retries)", () => {
			const policy = new RetryPolicy({ url: "ws://localhost" });
			expect(policy.shouldRetry(makeError(ErrorCodes.RATE_LIMITED), 100)).toBe(
				true,
			);
		});

		test("returns false for RATE_LIMITED when retryRateLimits is false", () => {
			const policy = new RetryPolicy({
				url: "ws://localhost",
				retryRateLimits: false,
			});
			expect(policy.shouldRetry(makeError(ErrorCodes.RATE_LIMITED), 0)).toBe(
				false,
			);
		});

		test("returns true for INTERNAL_ERROR by default", () => {
			const policy = new RetryPolicy({ url: "ws://localhost" });
			expect(policy.shouldRetry(makeError(ErrorCodes.INTERNAL_ERROR), 0)).toBe(
				true,
			);
		});

		test("returns true for ENGINE_UNHEALTHY by default", () => {
			const policy = new RetryPolicy({ url: "ws://localhost" });
			expect(
				policy.shouldRetry(makeError(ErrorCodes.ENGINE_UNHEALTHY), 0),
			).toBe(true);
		});

		test("returns true for server errors up to maxServerRetries (default 3)", () => {
			const policy = new RetryPolicy({ url: "ws://localhost" });
			expect(policy.shouldRetry(makeError(ErrorCodes.INTERNAL_ERROR), 0)).toBe(
				true,
			);
			expect(policy.shouldRetry(makeError(ErrorCodes.INTERNAL_ERROR), 1)).toBe(
				true,
			);
			expect(policy.shouldRetry(makeError(ErrorCodes.INTERNAL_ERROR), 2)).toBe(
				true,
			);
			expect(policy.shouldRetry(makeError(ErrorCodes.INTERNAL_ERROR), 3)).toBe(
				false,
			);
		});

		test("respects custom maxServerRetries", () => {
			const policy = new RetryPolicy({
				url: "ws://localhost",
				maxServerRetries: 1,
			});
			expect(policy.shouldRetry(makeError(ErrorCodes.INTERNAL_ERROR), 0)).toBe(
				true,
			);
			expect(policy.shouldRetry(makeError(ErrorCodes.INTERNAL_ERROR), 1)).toBe(
				false,
			);
		});

		test("returns false for server errors when retryServerErrors is false", () => {
			const policy = new RetryPolicy({
				url: "ws://localhost",
				retryServerErrors: false,
			});
			expect(policy.shouldRetry(makeError(ErrorCodes.INTERNAL_ERROR), 0)).toBe(
				false,
			);
		});

		test("returns false for validation errors", () => {
			const policy = new RetryPolicy({ url: "ws://localhost" });
			expect(
				policy.shouldRetry(makeError(ErrorCodes.SCHEMA_VALIDATION_FAILED), 0),
			).toBe(false);
			expect(policy.shouldRetry(makeError(ErrorCodes.INVALID_MESSAGE), 0)).toBe(
				false,
			);
		});

		test("returns false for auth errors", () => {
			const policy = new RetryPolicy({ url: "ws://localhost" });
			expect(
				policy.shouldRetry(makeError(ErrorCodes.PERMISSION_DENIED), 0),
			).toBe(false);
			expect(policy.shouldRetry(makeError(ErrorCodes.AUTH_FAILED), 0)).toBe(
				false,
			);
		});

		test("returns false for non-ZyncBaseError", () => {
			const policy = new RetryPolicy({ url: "ws://localhost" });
			expect(policy.shouldRetry(new Error("test"), 0)).toBe(false);
			expect(policy.shouldRetry("string error", 0)).toBe(false);
			expect(policy.shouldRetry(null, 0)).toBe(false);
		});
	});

	describe("getDelay", () => {
		test("respects retryAfter when present", () => {
			const policy = new RetryPolicy({ url: "ws://localhost" });
			const err = makeError(ErrorCodes.RATE_LIMITED, 5000);
			expect(policy.getDelay(err, 0)).toBe(5000);
			expect(policy.getDelay(err, 5)).toBe(5000);
		});

		test("uses retryAfter of 0 as immediate retry", () => {
			const policy = new RetryPolicy({ url: "ws://localhost" });
			const err = makeError(ErrorCodes.RATE_LIMITED, 0);
			expect(policy.getDelay(err, 0)).toBe(0);
		});

		test("uses exponential backoff when retryAfter is absent", () => {
			const policy = new RetryPolicy({ url: "ws://localhost" });
			const err = makeError(ErrorCodes.INTERNAL_ERROR);

			const delay0 = policy.getDelay(err, 0);
			const delay1 = policy.getDelay(err, 1);
			const delay2 = policy.getDelay(err, 2);

			// With default base=1000 and ±10% jitter:
			// attempt 0: ~1000ms (900-1100)
			// attempt 1: ~2000ms (1800-2200)
			// attempt 2: ~4000ms (3600-4400)
			expect(delay0).toBeGreaterThanOrEqual(900);
			expect(delay0).toBeLessThanOrEqual(1100);
			expect(delay1).toBeGreaterThanOrEqual(1800);
			expect(delay1).toBeLessThanOrEqual(2200);
			expect(delay2).toBeGreaterThanOrEqual(3600);
			expect(delay2).toBeLessThanOrEqual(4400);
		});

		test("respects custom reconnectDelay", () => {
			const policy = new RetryPolicy({
				url: "ws://localhost",
				reconnectDelay: 500,
			});
			const err = makeError(ErrorCodes.INTERNAL_ERROR);

			const delay0 = policy.getDelay(err, 0);
			expect(delay0).toBeGreaterThanOrEqual(450);
			expect(delay0).toBeLessThanOrEqual(550);
		});

		test("caps at maxReconnectDelay", () => {
			const policy = new RetryPolicy({
				url: "ws://localhost",
				maxReconnectDelay: 5000,
			});
			const err = makeError(ErrorCodes.INTERNAL_ERROR);

			// attempt 10 would be 1000 * 2^10 = 1,024,000 without cap
			const delay = policy.getDelay(err, 10);
			expect(delay).toBeLessThanOrEqual(5500); // 5000 + 10% jitter
		});
	});
});
