import { describe, expect, test } from "bun:test";
import { packDocId } from "./doc_id.js";
import { SchemaDictionary } from "./schema_dictionary.js";

describe("SchemaDictionary doc IDs", () => {
	test("encodes and decodes path doc IDs as bin(16)", async () => {
		const schema = new SchemaDictionary();
		await schema.processSchemaSync({
			tables: ["users"],
			fields: [["id", "namespace_id", "created_at", "updated_at", "name"]],
			fieldFlags: [[0b11, 0b01, 0b01, 0b01, 0b00]],
		});

		const encoded = schema.encodePath(["users", "abc123", "name"]);
		expect(encoded[1]).toBeInstanceOf(Uint8Array);
		expect(schema.decodePath(encoded)).toEqual(["users", "abc123", "name"]);
	});

	test("encodes and decodes row id/reference fields using field flags", async () => {
		const schema = new SchemaDictionary();
		await schema.processSchemaSync({
			tables: ["tasks"],
			fields: [
				["id", "namespace_id", "created_at", "updated_at", "title", "owner_id"],
			],
			fieldFlags: [[0b11, 0b01, 0b01, 0b01, 0b00, 0b10]],
		});

		const encoded = schema.encodeValue(0, {
			title: "hello",
			owner_id: "owner_1",
		});
		// Find the pair with field index 5
		const ownerPair = encoded.find((pair) => pair[0] === 5);
		expect(ownerPair).toBeDefined();
		expect(ownerPair?.[1]).toBeInstanceOf(Uint8Array);

		const decoded = schema.decodeRecord(0, [
			packDocId("task_1"),
			1,
			100,
			200,
			"hello",
			packDocId("owner_1"),
		]);
		expect(decoded).toEqual({
			id: "task_1",
			namespace_id: 1,
			created_at: 100,
			updated_at: 200,
			title: "hello",
			owner_id: "owner_1",
		});
	});

	test("decodes complete records with nested, nullable, and document ID fields", async () => {
		const schema = new SchemaDictionary();
		await schema.processSchemaSync({
			tables: ["tasks"],
			fields: [["id", "metrics__rank", "owner_id", "member_ids", "note"]],
			fieldFlags: [[0b11, 0b00, 0b10, 0b10, 0b00]],
		});

		expect(
			schema.decodeRecord(0, [
				packDocId("task_1"),
				7,
				packDocId("owner_1"),
				[packDocId("member_1"), packDocId("member_2")],
				null,
			]),
		).toEqual({
			id: "task_1",
			metrics: { rank: 7 },
			owner_id: "owner_1",
			member_ids: ["member_1", "member_2"],
			note: null,
		});
		expect(() => schema.decodeRecord(0, [packDocId("task_1"), 7])).toThrow(
			"record field count 2 does not match schema field count 5",
		);
		expect(() =>
			schema.decodeRecord(0, [
				packDocId("task_1"),
				7,
				packDocId("owner_1"),
				[],
				null,
				null,
			]),
		).toThrow("record field count 6 does not match schema field count 5");
		expect(() => schema.decodeRecord(99, [])).toThrow(
			"table index 99 out of range",
		);
	});

	test("rejects missing fieldFlags", async () => {
		const schema = new SchemaDictionary();
		await expect(
			schema.processSchemaSync({
				tables: ["users"],
				fields: [["id", "name"]],
			} as unknown as {
				tables: string[];
				fields: string[][];
				fieldFlags: number[][];
			}),
		).rejects.toThrow("missing fieldFlags");
	});
});
