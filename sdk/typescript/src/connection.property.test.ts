import { describe, test } from "bun:test";
import * as fc from "fast-check";
import { ConnectionManager } from "./connection";
import type { ClientOptions } from "./types";

/**
 * Property 5: Backoff delay bounds
 * Validates: Requirements 2.3
 */
describe("ConnectionManager", () => {
	test("Property 5: backoff delay is within ±10% jitter bounds and capped at maxReconnectDelay", () => {
		fc.assert(
			fc.property(
				fc.integer({ min: 0, max: 20 }),
				fc.record({
					reconnectDelay: fc.integer({ min: 100, max: 5000 }),
					maxReconnectDelay: fc.integer({ min: 5000, max: 60000 }),
				}),
				(attempt, opts) => {
					const options: ClientOptions = {
						url: "ws://localhost:1234",
						reconnectDelay: opts.reconnectDelay,
						maxReconnectDelay: opts.maxReconnectDelay,
					};
					const manager = new ConnectionManager(options);
					const delay = manager._computeBackoffDelay(attempt);

					const preCap = opts.reconnectDelay * 2 ** attempt;
					// When preCap exceeds maxReconnectDelay, the cap applies and the delay is maxReconnectDelay.
					// The lower bound is also capped so the assertion remains valid.
					const lowerBound = Math.min(preCap * 0.9, opts.maxReconnectDelay);
					const upperBound = Math.min(preCap * 1.1, opts.maxReconnectDelay);

					return delay >= lowerBound && delay <= upperBound;
				},
			),
			{ numRuns: 100 },
		);
	});
});
