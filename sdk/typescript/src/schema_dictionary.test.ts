import { describe, expect, test } from "bun:test";
import { packDocId } from "./doc_id.js";
import { SchemaDictionary } from "./schema_dictionary.js";

describe("SchemaDictionary doc IDs", () => {
	test("encodes and decodes path doc IDs as bin(16)", async () => {
		const schema = new SchemaDictionary();
		await schema.processSchemaSync({
			tables: ["users"],
			fields: [["id", "namespace_id", "created_at", "updated_at", "name"]],
			fieldFlags: [[0x03, 0x01, 0x01, 0x01, 0x00]],
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
			fieldFlags: [[0x03, 0x01, 0x01, 0x01, 0x00, 0x02]],
		});

		const encoded = schema.encodeValue(0, {
			title: "hello",
			owner_id: "owner_1",
		});
		expect(encoded[5]).toBeInstanceOf(Uint8Array);

		const decoded = schema.decodeValue(0, {
			0: packDocId("task_1"),
			4: "hello",
			5: packDocId("owner_1"),
		} as unknown as Record<number, unknown>);
		expect(decoded).toEqual({
			id: "task_1",
			title: "hello",
			owner_id: "owner_1",
		});
	});

	test("infers the built-in id field as doc_id even without field flags", async () => {
		const schema = new SchemaDictionary();
		await schema.processSchemaSync({
			tables: ["users"],
			fields: [["id", "name"]],
		});

		const decoded = schema.decodeValue(0, {
			0: packDocId("u1"),
			1: "Alice",
		} as unknown as Record<number, unknown>);
		expect(decoded).toEqual({ id: "u1", name: "Alice" });
	});
});
