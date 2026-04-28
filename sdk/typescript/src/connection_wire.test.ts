import { describe, expect, test } from "bun:test";
import { decode, encode } from "@msgpack/msgpack";
import { ConnectionWireCodec } from "./connection_wire.js";
import type { StoreDelta } from "./types.js";

function bufferOf(value: unknown): ArrayBuffer {
	const bytes = encode(value);
	return bytes.buffer.slice(
		bytes.byteOffset,
		bytes.byteOffset + bytes.byteLength,
	) as ArrayBuffer;
}

async function makeCodec(): Promise<ConnectionWireCodec> {
	const codec = new ConnectionWireCodec();
	await codec.applySchemaSync({
		type: "SchemaSync",
		tables: ["users"],
		fields: [["id", "name", "address__city"]],
		fieldFlags: [[0, 0, 0]],
	});
	return codec;
}

describe("ConnectionWireCodec", () => {
	test("encodes schema-aware query fields", async () => {
		const codec = await makeCodec();
		const encoded = codec.encode(
			{
				type: "StoreQuery",
				table_index: "users",
				conditions: [["name", 0, "Ada"]],
				orderBy: ["address__city", 1],
			},
			7,
		);

		expect(encoded.context).toEqual({
			type: "StoreQuery",
			responseTableIndex: 0,
		});
		expect(decode(encoded.bytes)).toEqual({
			type: "StoreQuery",
			id: 7,
			table_index: 0,
			conditions: [[1, 0, "Ada"]],
			orderBy: [2, 1],
		});
	});

	test("decodes schema-aware deltas", async () => {
		const codec = await makeCodec();
		const msg = codec.decode(
			bufferOf({
				type: "StoreDelta",
				subId: 1,
				ops: [
					{
						op: "set",
						path: [0, "u1"],
						value: { 1: "Ada", 2: "London" },
					},
				],
			}),
		) as StoreDelta;

		expect(msg).toEqual({
			type: "StoreDelta",
			subId: 1,
			ops: [
				{
					op: "set",
					path: ["users", "u1"],
					value: { name: "Ada", address__city: "London" },
				},
			],
		});
	});

	test("decodes query response rows using pending request context", async () => {
		const codec = await makeCodec();
		const ok = codec.decodeOkResponse(
			{
				type: "ok",
				id: 2,
				value: [{ 1: "Ada", 2: "London" } as never],
			},
			{ type: "StoreQuery", responseTableIndex: 0 },
		);

		expect(ok.value).toEqual([{ name: "Ada", address__city: "London" }]);
	});
});
