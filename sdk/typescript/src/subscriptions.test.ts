import { describe, expect, test } from "bun:test";
import * as fc from "fast-check";
import {
	createInitialSnapshotDelta,
	SubscriptionTracker,
} from "./subscriptions";
import type { JsonValue, StoreDelta, StoreSubscribe } from "./types";

/**
 * Property 9: StoreDelta routing to subscriptions
 * Validates: Requirements 3.6, 8.2
 */
describe("SubscriptionTracker", () => {
	test("Property 9: dispatching a StoreDelta invokes the registered callback exactly once with the delta ops", () => {
		fc.assert(
			fc.property(fc.integer({ min: 1, max: 100000 }), (subId) => {
				const tracker = new SubscriptionTracker();

				const received: unknown[] = [];
				const callback = (value: unknown) => received.push(value);

				const params: Omit<StoreSubscribe, "id"> = {
					type: "StoreSubscribe",
					table_index: "users",
				};

				tracker.register(subId, {
					params,
					callbacks: [callback],
					projection: null, // store.subscribe style
				});

				const delta: StoreDelta = {
					type: "StoreDelta",
					subId,
					ops: [{ op: "set", path: ["name"], value: "Alice" }],
				};

				tracker.dispatch(delta);

				// Callback invoked exactly once with the delta's ops
				return received.length === 1 && received[0] === delta.ops;
			}),
			{ numRuns: 100 },
		);
	});

	test("Property 9: dispatching a StoreDelta for an unregistered subId does NOT invoke any callback", () => {
		fc.assert(
			fc.property(
				fc.integer({ min: 1, max: 100000 }),
				fc.integer({ min: 100001, max: 200000 }),
				(registeredSubId, unregisteredSubId) => {
					const tracker = new SubscriptionTracker();

					const received: unknown[] = [];
					const callback = (value: unknown) => received.push(value);

					tracker.register(registeredSubId, {
						params: {
							type: "StoreSubscribe",
							table_index: "users",
						},
						callbacks: [callback],
						projection: null,
					});

					const delta: StoreDelta = {
						type: "StoreDelta",
						subId: unregisteredSubId,
						ops: [{ op: "set", path: ["name"], value: "Bob" }],
					};

					tracker.dispatch(delta);

					// No callback should be invoked for an unregistered subId
					return received.length === 0;
				},
			),
			{ numRuns: 100 },
		);
	});
});

describe("SubscriptionTracker - materialized view set ops", () => {
	test("initial snapshots reuse final nested records", () => {
		const record = { id: "u1", address: { city: "London" } };
		const delta = createInitialSnapshotDelta(200, ["users"], [record]);

		expect(delta.ops).toHaveLength(1);
		expect(delta.ops[0]?.op).toBe("set");
		if (delta.ops[0]?.op === "set") expect(delta.ops[0].value).toBe(record);
	});

	test("decoded record set op stores the final value", async () => {
		const tracker = new SubscriptionTracker();
		const snapshots: JsonValue[][] = [];

		tracker.registerCollection(
			201,
			{ type: "StoreSubscribe", table_index: "items" },
			(value) => snapshots.push(value),
		);

		tracker.dispatch({
			type: "StoreDelta",
			subId: 201,
			ops: [
				{
					op: "set",
					path: ["items", "doc-1"],
					value: { id: "doc-1", name: "item", priority: 5 },
				},
			],
		});
		await flushTick();

		expect(snapshots).toEqual([[{ id: "doc-1", name: "item", priority: 5 }]]);
	});

	test("stores the inbound delta value directly", async () => {
		const tracker = new SubscriptionTracker();
		const snapshots: JsonValue[][] = [];
		const inputValue = { id: "doc-1", name: "item", priority: 5 };

		tracker.registerCollection(
			203,
			{ type: "StoreSubscribe", table_index: "items" },
			(value) => snapshots.push(value),
		);

		tracker.dispatch({
			type: "StoreDelta",
			subId: 203,
			ops: [
				{
					op: "set",
					path: ["items", "doc-1"],
					value: inputValue,
				},
			],
		});
		await flushTick();

		expect(snapshots).toEqual([[{ id: "doc-1", name: "item", priority: 5 }]]);
		expect(snapshots[0][0]).toBe(inputValue);
	});

	test("keeps decoded nested records intact", async () => {
		const tracker = new SubscriptionTracker();
		const snapshots: JsonValue[][] = [];

		tracker.registerCollection(
			202,
			{ type: "StoreSubscribe", table_index: "users" },
			(value) => snapshots.push(value),
		);

		tracker.dispatch({
			type: "StoreDelta",
			subId: 202,
			ops: [
				{
					op: "set",
					path: ["users", "u1"],
					value: { id: "u1", address: { city: "NYC" } },
				},
			],
		});
		await flushTick();

		expect(snapshots).toEqual([[{ id: "u1", address: { city: "NYC" } }]]);
	});
});

function flushTick(): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, 0));
}

/**
 * Property 10: Subscription replay on reconnect
 * Validates: Requirements 8.5
 */
describe("SubscriptionTracker - replayAll", () => {
	test("Property 11: replayAll(send) invokes send for all currently registered subscriptions", async () => {
		await fc.assert(
			fc.asyncProperty(fc.integer({ min: 1, max: 10 }), async (n) => {
				const tracker = new SubscriptionTracker();
				const collections = Array.from({ length: n }, (_, i) => `c${i}`);
				const subIds = Array.from({ length: n }, (_, i) => i + 1);

				for (let i = 0; i < n; i++) {
					const params: Omit<StoreSubscribe, "id"> = {
						type: "StoreSubscribe",
						table_index: collections[i],
					};
					tracker.register(subIds[i], {
						params,
						callbacks: [],
						projection: null,
					});
				}

				// Collect all params and subIds passed to send
				const sent: { params: Omit<StoreSubscribe, "id">; subId: number }[] =
					[];
				await tracker.replayAll(async (params, subId) => {
					sent.push({ params, subId });
				});

				// send must be called exactly N times (once per subscription)
				return (
					sent.length === n &&
					sent.every((s) => s.params === tracker.get(s.subId)?.params)
				);
			}),
			{ numRuns: 100 },
		);
	});
});
