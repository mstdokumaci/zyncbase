import { describe, expect, test } from "bun:test";
import { SubscriptionTracker } from "./subscriptions";
import type { StoreDelta, StoreSubscribe } from "./types";

/**
 * Pure unit benchmark for the materialized-view delta path — no network, no
 * schema, no client. Exercises the hot loop that was O(records) per delta:
 * 2000-record view, 20000 deltas, one flush.
 */
describe("SubscriptionTracker delta fan-in performance", () => {
	test("20000 deltas on a 2000-record view batch into per-tick callbacks", async () => {
		const tracker = new SubscriptionTracker();

		let callbackCount = 0;
		let lastSnapshot: unknown = null;

		const params: Omit<StoreSubscribe, "id"> = {
			type: "StoreSubscribe",
			table_index: "items",
		};
		tracker.registerCollection(101, params, (value) => {
			callbackCount++;
			lastSnapshot = value;
		});

		const seedOps: StoreDelta["ops"] = Array.from({ length: 2000 }, (_, i) => ({
			op: "set" as const,
			path: ["items", `doc-${i}`],
			value: { id: `doc-${i}`, n: i },
		}));
		tracker.dispatch({ type: "StoreDelta", subId: 101, ops: seedOps });
		await new Promise((resolve) => setTimeout(resolve, 0));

		const t0 = performance.now();
		for (let i = 0; i < 20000; i++) {
			const doc = `doc-${i % 2000}`;
			tracker.dispatch({
				type: "StoreDelta",
				subId: 101,
				ops: [{ op: "set", path: ["items", doc], value: { id: doc, n: i } }],
			});
		}
		await new Promise((resolve) => setTimeout(resolve, 0));
		const elapsedMs = performance.now() - t0;

		console.log(
			`Fan-in (2000 records / 20000 deltas) [ms]: ${elapsedMs.toFixed(2)}  callbacks=${callbackCount}`,
		);

		// Contract: exactly two flushes — seed dispatch, then the single-tick
		// 20000-delta burst. A per-delta callback (or an extra flush) fails here.
		expect(callbackCount).toBe(2);
		// Final state: all records present, last write wins per doc.
		expect(Array.isArray(lastSnapshot)).toBe(true);
		const snapshot = lastSnapshot as Array<{ id: string; n: number }>;
		expect(snapshot.length).toBe(2000);
		const doc5 = snapshot.find((r) => r.id === "doc-5");
		expect(doc5?.n).toBe(18005);
		// Loose threshold — headroom for CI variance.
		expect(elapsedMs).toBeLessThan(1000);
	});
});
