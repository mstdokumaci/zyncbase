import { describe, expect, test } from "bun:test";
import { packDocId } from "./doc_id.js";
import { SchemaDictionary } from "./schema_dictionary.js";

describe("SchemaDictionary doc IDs", () => {
	test("decodes packed canonical UUID presence user IDs", () => {
		const id = "019c1e50-7d11-7abc-9def-0123456789ab";
		expect(new SchemaDictionary().decodeUserId(packDocId(id))).toBe(id);
	});

	test("encodes and decodes path doc IDs as bin(16)", async () => {
		const schema = new SchemaDictionary();
		await schema.processSchemaSync({
			version: "1.0.0",
			tables: ["users"],
			fields: [["id", "namespace_id", "created_at", "updated_at", "name"]],
			fieldFlags: [[0b11, 0b01, 0b01, 0b01, 0b00]],
		});

		const encoded = schema.encodePath(["users", "abc123", "name"]);
		expect(encoded[1]).toBeInstanceOf(Uint8Array);
		expect(schema.decodePath(encoded)).toEqual(["users", "abc123", "name"]);
	});

	test("encodes and decodes 3-segment nested field paths", async () => {
		const schema = new SchemaDictionary();
		await schema.processSchemaSync({
			version: "1.0.0",
			tables: ["users"],
			fields: [["id", "profile__address__city", "name"]],
			fieldFlags: [[0b11, 0b00, 0b00]],
		});

		const encoded = schema.encodePath([
			"users",
			"abc123",
			"profile.address.city",
		]);
		expect(encoded[2]).toBe(1);
		expect(schema.decodePath(encoded)).toEqual([
			"users",
			"abc123",
			"profile.address.city",
		]);
		expect(() =>
			schema.encodePath(["users", "abc123", "profile", "address"]),
		).toThrow("at most 3 segments");
	});

	test("encodeValue clears namespaces and lets explicit leaves win", async () => {
		const schema = new SchemaDictionary();
		await schema.processSchemaSync({
			version: "1.0.0",
			tables: ["users"],
			fields: [["id", "address__city", "address__zip", "name"]],
			fieldFlags: [[0b11, 0b00, 0b00, 0b00]],
		});

		expect(schema.encodeValue(0, { address: null })).toEqual([
			1,
			null,
			2,
			null,
		]);
		expect(
			schema.encodeValue(0, {
				address: null,
				address__city: "London",
			}),
		).toEqual([1, "London", 2, null]);
		expect(schema.encodeValue(0, { address__city: null })).toEqual([1, null]);
		expect(() => schema.encodeValue(0, { address: "London" })).toThrow(
			"unknown field",
		);
		expect(() => schema.encodeValue(0, { nope: null })).toThrow(
			"unknown field",
		);
	});

	test("encodes and decodes row id/reference fields using field flags", async () => {
		const schema = new SchemaDictionary();
		await schema.processSchemaSync({
			version: "1.0.0",
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
		// Field index 5 sits at an even position; its value follows.
		const ownerIndex = encoded.findIndex(
			(entry, i) => i % 2 === 0 && entry === 5,
		);
		expect(ownerIndex).toBeGreaterThanOrEqual(0);
		expect(encoded[ownerIndex + 1]).toBeInstanceOf(Uint8Array);

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
			version: "1.0.0",
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
				version: "1.0.0",
				tables: ["users"],
				fields: [["id", "name"]],
			} as unknown as {
				version: string;
				tables: string[];
				fields: string[][];
				fieldFlags: number[][];
			}),
		).rejects.toThrow("missing fieldFlags");
	});

	test("identifies bytes fields and preserves Uint8Array values without docId decoding", async () => {
		const schema = new SchemaDictionary();
		await schema.processSchemaSync({
			version: "1.0.0",
			tables: ["files"],
			fields: [["id", "data"]],
			fieldFlags: [[0b11, 0b1000]],
		});

		expect(schema.isBytesField(0, 1)).toBe(true);
		expect(schema.isBytesField(0, 0)).toBe(false);

		const raw = new Uint8Array([10, 20, 30, 40]);
		const decoded = schema.decodeRecord(0, [packDocId("file_1"), raw]);
		expect(decoded).toEqual({
			id: "file_1",
			data: raw,
		});
	});
});

describe("SchemaDictionary schema changes", () => {
	const store = {
		version: "1.0.0",
		tables: ["users"],
		fields: [["id", "name"]],
		fieldFlags: [[3, 0]],
	};

	test("detects action-only changes", async () => {
		const schema = new SchemaDictionary();
		expect(await schema.processSchemaSync(store)).toBeNull();
		expect(
			await schema.processSchemaSync({
				...store,
				actions: ["greet"],
				actionParams: [["message"]],
				actionReturns: [["reply"]],
				actionFlags: [1],
			}),
		).toEqual({ previousVersion: "1.0.0", version: "1.0.0" });
		expect(
			await schema.processSchemaSync({
				...store,
				actions: ["greet"],
				actionParams: [["message"]],
				actionReturns: [["reply"]],
				actionFlags: [1],
			}),
		).toBeNull();
	});

	test("tracks the schema version and reports version-only changes", async () => {
		const schema = new SchemaDictionary();
		expect(schema.getVersion()).toBeNull();
		expect(await schema.processSchemaSync(store)).toBeNull();
		expect(schema.getVersion()).toBe("1.0.0");
		expect(
			await schema.processSchemaSync({ ...store, version: "2.0.0" }),
		).toEqual({ previousVersion: "1.0.0", version: "2.0.0" });
		expect(schema.getVersion()).toBe("2.0.0");
	});

	test("rejects a SchemaSync without a version", async () => {
		const schema = new SchemaDictionary();
		const { version: _version, ...withoutVersion } = store;
		await expect(
			schema.processSchemaSync(withoutVersion as unknown as typeof store),
		).rejects.toThrow("missing version");
		expect(schema.isReady()).toBe(false);
	});
});
