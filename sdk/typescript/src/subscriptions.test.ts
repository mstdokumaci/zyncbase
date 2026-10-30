import { describe, expect, test } from "bun:test";
import * as fc from "fast-check";
import {
	createCreatedAtComparator,
	createInitialSnapshotDelta,
	createListenProjection,
	SubscriptionTracker,
} from "./subscriptions";
import type { JsonValue, StoreDelta, StoreSubscribe } from "./types";

/** Registers a collection-level (materialized view) subscription. */
function registerView(
	tracker: SubscriptionTracker,
	subId: number,
	params: Omit<StoreSubscribe, "id">,
	callback: (results: JsonValue[]) => void,
): void {
	tracker.register(subId, {
		params,
		callbacks: [callback],
		projection: null,
		materializedView: {
			records: new Map(),
			comparator: createCreatedAtComparator(),
		},
	});
}

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

		registerView(
			tracker,
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

		registerView(
			tracker,
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

		registerView(
			tracker,
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

describe("SubscriptionTracker - field projection delivery", () => {
	test("object projection suppresses sibling-field and system-column updates", () => {
		const tracker = new SubscriptionTracker();
		const values: JsonValue[] = [];

		tracker.register(301, {
			params: { type: "StoreSubscribe", table_index: "users" },
			callbacks: [(value) => values.push(value)],
			projection: createListenProjection(["users", "u1", "address"]),
		});

		const push = (address: JsonValue, score: number, updatedAt: number) =>
			tracker.dispatch({
				type: "StoreDelta",
				subId: 301,
				ops: [
					{
						op: "set",
						path: ["users", "u1"],
						value: { id: "u1", address, score, updated_at: updatedAt },
					},
				],
			});

		push({ city: "London" }, 1, 100);
		push({ city: "London" }, 2, 200); // sibling + system change only
		push({ city: "London" }, 2, 300); // system change only
		push({ city: "Paris" }, 2, 400); // projected change

		expect(values).toEqual([{ city: "London" }, { city: "Paris" }]);
	});

	test("scalar projection suppresses deliveries with an unchanged value", () => {
		const tracker = new SubscriptionTracker();
		const values: JsonValue[] = [];

		tracker.register(302, {
			params: { type: "StoreSubscribe", table_index: "users" },
			callbacks: [(value) => values.push(value)],
			projection: createListenProjection(["users", "u1", "name"]),
		});

		const push = (name: string, score: number) =>
			tracker.dispatch({
				type: "StoreDelta",
				subId: 302,
				ops: [
					{
						op: "set",
						path: ["users", "u1"],
						value: { id: "u1", name, score, updated_at: score },
					},
				],
			});

		push("Alice", 1);
		push("Alice", 2);
		push("Bob", 3);

		expect(values).toEqual(["Alice", "Bob"]);
	});

	test("document-level listen delivers every pushed record", () => {
		const tracker = new SubscriptionTracker();
		const values: JsonValue[] = [];

		tracker.register(303, {
			params: { type: "StoreSubscribe", table_index: "users" },
			callbacks: [(value) => values.push(value)],
			projection: createListenProjection(["users", "u1"]),
		});

		const record = { id: "u1", name: "Alice", updated_at: 100 };
		const push = (value: JsonValue) =>
			tracker.dispatch({
				type: "StoreDelta",
				subId: 303,
				ops: [{ op: "set", path: ["users", "u1"], value }],
			});

		push(record);
		push({ ...record }); // deep-equal record still delivered at document depth

		expect(values).toHaveLength(2);
	});

	test("removing an absent record does not deliver", async () => {
		const tracker = new SubscriptionTracker();
		const snapshots: JsonValue[][] = [];

		registerView(
			tracker,
			304,
			{ type: "StoreSubscribe", table_index: "items" },
			(value) => snapshots.push(value),
		);

		tracker.dispatch({
			type: "StoreDelta",
			subId: 304,
			ops: [{ op: "remove", path: ["items", "missing"] }],
		});
		await flushTick();

		expect(snapshots).toHaveLength(0);
	});

	test("callback mutation of a delivered object cannot poison suppression", () => {
		const tracker = new SubscriptionTracker();
		const seen: Array<[JsonValue, JsonValue]> = [];

		tracker.register(305, {
			params: { type: "StoreSubscribe", table_index: "users" },
			callbacks: [
				(value) => {
					const address = value as Record<string, JsonValue>;
					seen.push([address.city, address.tier]);
					address.tier = 999; // mutate the delivered value after delivery
				},
			],
			projection: createListenProjection(["users", "u1", "address"]),
		});

		const push = (address: JsonValue) =>
			tracker.dispatch({
				type: "StoreDelta",
				subId: 305,
				ops: [
					{
						op: "set",
						path: ["users", "u1"],
						value: { id: "u1", address, updated_at: 0 },
					},
				],
			});

		push({ city: "London", tier: 1 });
		push({ city: "London", tier: 1 }); // equal server content: suppressed
		expect(seen).toHaveLength(1);

		push({ city: "London", tier: 999 }); // genuine change: delivered
		expect(seen).toHaveLength(2);
		expect(seen[1]).toEqual(["London", 999]);
	});

	test("callback mutation of delivered bytes cannot poison suppression", () => {
		const tracker = new SubscriptionTracker();
		const seen: JsonValue[] = [];

		tracker.register(306, {
			params: { type: "StoreSubscribe", table_index: "chunks" },
			callbacks: [
				(value) => {
					const coordinates = value as Uint8Array;
					seen.push(new Uint8Array(coordinates));
					coordinates[0] = 9; // mutate the delivered value after delivery
				},
			],
			projection: createListenProjection(["chunks", "c1", "coordinates"]),
		});

		const push = (bytes: number[]) =>
			tracker.dispatch({
				type: "StoreDelta",
				subId: 306,
				ops: [
					{
						op: "set",
						path: ["chunks", "c1"],
						value: { id: "c1", coordinates: new Uint8Array(bytes) },
					},
				],
			});

		push([1, 2, 3]);
		push([1, 2, 3]); // equal server content: suppressed
		expect(seen).toHaveLength(1);

		push([9, 2, 3]); // genuine change: delivered
		expect(seen).toHaveLength(2);
		expect(seen[1]).toEqual(new Uint8Array([9, 2, 3]));
	});

	test("own __proto__ keys survive the suppression baseline clone", () => {
		const tracker = new SubscriptionTracker();
		const values: JsonValue[] = [];

		tracker.register(307, {
			params: { type: "StoreSubscribe", table_index: "users" },
			callbacks: [(value) => values.push(value)],
			projection: createListenProjection(["users", "u1", "address"]),
		});

		// JSON.parse creates an own "__proto__" property (not a prototype).
		const address = JSON.parse(
			'{"city":"London","__proto__":{"x":1}}',
		) as JsonValue;
		const push = () =>
			tracker.dispatch({
				type: "StoreDelta",
				subId: 307,
				ops: [
					{
						op: "set",
						path: ["users", "u1"],
						value: { id: "u1", address, updated_at: 0 },
					},
				],
			});

		push();
		push(); // equal server content: suppressed
		expect(values).toHaveLength(1);
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
