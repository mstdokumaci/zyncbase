import { describe, expect, test } from "bun:test";
import { SchemaDictionary } from "./schema_dictionary";
import { type StoreConnection, StoreImpl } from "./store";
import {
	createCreatedAtComparator,
	SubscriptionTracker,
} from "./subscriptions";
import type { JsonValue, StoreDelta, StoreSubscribe } from "./types";

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

/**
 * Pure unit benchmark for the materialized-view delta path — no network, no
 * schema, no client. Exercises the hot loop that was O(records) per delta:
 * 10000-record view with 100 pending local writes, 20000 deltas, one flush.
 */
describe("SubscriptionTracker delta fan-in performance", () => {
	test("20000 deltas on a 10000-record view with pending writes batch into per-tick callbacks", async () => {
		const tracker = new SubscriptionTracker();

		let callbackCount = 0;
		let lastSnapshot: unknown = null;

		const params: Omit<StoreSubscribe, "id"> = {
			type: "StoreSubscribe",
			table_index: "items",
		};
		tracker.register(101, {
			params,
			collection: "items",
			callbacks: [
				(value) => {
					callbackCount++;
					lastSnapshot = value;
				},
			],
			projection: null,
			materializedView: {
				records: new Map(),
				comparator: createCreatedAtComparator(),
				matches: () => true,
			},
		});

		const seedOps: StoreDelta["ops"] = Array.from(
			{ length: 10000 },
			(_, i) => ({
				op: "set" as const,
				path: ["items", `doc-${i}`],
				value: { id: `doc-${i}`, n: i, created_at: i },
			}),
		);
		tracker.dispatch({ type: "StoreDelta", subId: 101, ops: seedOps });
		await tick();
		for (let i = 0; i < 100; i++) {
			tracker.pending.add([
				{
					kind: "set",
					collection: "items",
					id: `doc-${i * 100}`,
					patch: { local: true },
				},
			]);
		}

		const t0 = performance.now();
		for (let i = 0; i < 20000; i++) {
			const doc = `doc-${i % 10000}`;
			tracker.dispatch({
				type: "StoreDelta",
				subId: 101,
				ops: [
					{
						op: "set",
						path: ["items", doc],
						value: { id: doc, n: i, created_at: i % 10000 },
					},
				],
			});
		}
		await tick();
		const elapsedMs = performance.now() - t0;

		console.log(
			`Fan-in (10000 records / 100 pending / 20000 deltas) [ms]: ${elapsedMs.toFixed(2)}  callbacks=${callbackCount}`,
		);

		// Contract: exactly two flushes — seed dispatch, then the single-tick
		// 20000-delta burst. A per-delta callback (or an extra flush) fails here.
		expect(callbackCount).toBe(2);
		// Final state: all records present, last write wins per doc, pending
		// writes applied over it.
		const snapshot = lastSnapshot as Array<{
			id: string;
			n: number;
			local?: boolean;
		}>;
		expect(snapshot.length).toBe(10000);
		expect(snapshot[5]).toMatchObject({ id: "doc-5", n: 10005 });
		expect(snapshot[100]).toMatchObject({
			id: "doc-100",
			n: 10100,
			local: true,
		});
		// Loose threshold — headroom for CI variance.
		expect(elapsedMs).toBeLessThan(1000);
	});
});

/**
 * Mirrors the e2e filtered-subscription stress shape: many in-process
 * clients, each with a large filtered view, each issuing a burst of local
 * writes. Local delivery is incremental, so the burst costs no re-sorts.
 */
describe("optimistic local delivery performance", () => {
	test("400 stores with 800-row views take 8 local writes each", async () => {
		const schema = new SchemaDictionary();
		await schema.processSchemaSync({
			version: "1.0.0",
			tables: ["items"],
			fields: [
				[
					"id",
					"namespace_id",
					"owner_id",
					"priority",
					"active",
					"created_at",
					"updated_at",
				],
			],
			fieldFlags: [[0b11, 0b01, 0b11, 0, 0, 0b01, 0b01]],
		});
		const rows: JsonValue[] = Array.from({ length: 800 }, (_, i) => ({
			id: `item-${i}`,
			namespace_id: 1,
			owner_id: "me",
			priority: i % 10,
			active: true,
			created_at: i + 1,
			updated_at: i + 1,
		}));

		const stores: StoreImpl[] = [];
		let deliveries = 0;
		for (let s = 0; s < 400; s++) {
			const conn: StoreConnection = {
				dispatch: async () => ({ type: "ok", id: 0, subId: 1, value: rows }),
				dispatchWrite: () => new Promise<void>(() => {}),
				on: () => {},
				schemaDictionary: schema,
				userId: "me",
			};
			const store = new StoreImpl(conn, new SubscriptionTracker());
			await store.markSessionReady();
			await store.subscribe(
				"items",
				{ where: { priority: { gte: 0 }, active: true } },
				() => {
					deliveries++;
				},
			);
			stores.push(store);
		}
		await tick();
		deliveries = 0;

		const t0 = performance.now();
		for (const store of stores) {
			for (let w = 0; w < 8; w++) {
				void store.set(["items", `item-${w * 97}`], { priority: 9 - w });
			}
		}
		const elapsedMs = performance.now() - t0;

		console.log(
			`Local burst (400 stores x 800 rows x 8 writes) [ms]: ${elapsedMs.toFixed(2)}`,
		);
		expect(deliveries).toBe(400 * 8);
		expect(elapsedMs).toBeLessThan(100);
	});
});
