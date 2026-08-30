import { describe, expect, test } from "bun:test";
import { packDocId } from "./doc_id";
import { SchemaDictionary } from "./schema_dictionary";

describe("SchemaDictionary performance", () => {
	test("250k representative records decode within budget", async () => {
		const schema = new SchemaDictionary();
		await schema.processSchemaSync({
			tables: ["items"],
			fields: [["id", "name", "priority", "active", "metrics__rank", "tags"]],
			fieldFlags: [[0b11, 0, 0, 0, 0, 0]],
		});
		const wireRecord: unknown[] = [
			packDocId("task_1"),
			"item",
			42,
			true,
			7,
			["a", "b"],
		];

		for (let i = 0; i < 20_000; i++) {
			schema.decodeRecord(0, wireRecord);
		}

		const iterations = 250_000;
		let last: unknown;
		const t0 = performance.now();
		for (let i = 0; i < iterations; i++) {
			last = schema.decodeRecord(0, wireRecord);
		}
		const elapsedMs = performance.now() - t0;

		console.log(
			`decodeRecord (${iterations} records) [ms]: ${elapsedMs.toFixed(1)}`,
		);
		expect(last).toEqual({
			id: "task_1",
			name: "item",
			priority: 42,
			active: true,
			metrics: { rank: 7 },
			tags: ["a", "b"],
		});
		expect(elapsedMs).toBeLessThan(75);
	});
});
