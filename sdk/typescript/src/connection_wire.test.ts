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
						value: [
							[1, "Ada"],
							[2, "London"],
						],
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

	test("decodeMulti decodes all concatenated messages in a frame", async () => {
		const codec = await makeCodec();
		const ok = bufferOf({ type: "ok", id: 7 });
		const delta = bufferOf({
			type: "StoreDelta",
			subId: 1,
			ops: [
				{
					op: "set",
					path: [0, "u1"],
					value: [
						[1, "Ada"],
						[2, "London"],
					],
				},
			],
		});
		const frame = new Uint8Array(ok.byteLength + delta.byteLength);
		frame.set(new Uint8Array(ok), 0);
		frame.set(new Uint8Array(delta), ok.byteLength);

		const msgs = codec.decodeMulti(frame);
		expect(msgs).toHaveLength(2);
		expect(msgs[0]).toEqual({ type: "ok", id: 7 });
		expect(msgs[1]).toEqual({
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

	test("decodeMulti handles single-message, empty, and invalid frames", async () => {
		const codec = await makeCodec();
		const single = codec.decodeMulti(bufferOf({ type: "ok", id: 1 }));
		expect(single).toHaveLength(1);
		expect(single[0]).toEqual({ type: "ok", id: 1 });
		expect(codec.decodeMulti(new ArrayBuffer(0))).toEqual([]);
		expect(codec.decodeMulti(new Uint8Array([0xc1]))).toEqual([]);
	});

	test("decodes query response rows using pending request context", async () => {
		const codec = await makeCodec();
		const ok = codec.decodeOkResponse(
			{
				type: "ok",
				id: 2,
				value: [
					[
						[1, "Ada"],
						[2, "London"],
					],
				] as never,
			},
			{ type: "StoreQuery", responseTableIndex: 0 },
		);

		expect(ok.value).toEqual([{ name: "Ada", address__city: "London" }]);
	});
});
