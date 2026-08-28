import { describe, expect, test } from "bun:test";
import { SchemaDictionary } from "./schema_dictionary";

describe("SchemaDictionary performance", () => {
	test("250k representative delta records decode within budget", async () => {
		const schema = new SchemaDictionary();
		await schema.processSchemaSync({
			tables: ["items"],
			fields: [["id", "name", "priority", "active", "metrics__rank", "tags"]],
			fieldFlags: [[0b11, 0, 0, 0, 0, 0]],
		});
		const wireValue: Array<[number, unknown]> = [
			[0, new Uint8Array(16)],
			[1, "item"],
			[2, 42],
			[3, true],
			[4, 7],
			[5, ["a", "b"]],
		];

		for (let i = 0; i < 20_000; i++) {
			schema.decodeDeltaValue(0, wireValue, "task_1");
		}

		const iterations = 250_000;
		let last: unknown;
		const t0 = performance.now();
		for (let i = 0; i < iterations; i++) {
			last = schema.decodeDeltaValue(0, wireValue, "task_1");
		}
		const elapsedMs = performance.now() - t0;

		console.log(
			`decodeDeltaValue (${iterations} records) [ms]: ${elapsedMs.toFixed(1)}`,
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
