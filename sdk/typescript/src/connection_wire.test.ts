import { describe, expect, test } from "bun:test";
import { decode, encode } from "@msgpack/msgpack";
import { ConnectionWireCodec, WireMessageType } from "./connection_wire.js";
import { encodeToBuffer } from "./test-helpers.js";
import type { StoreDelta } from "./types.js";

async function makeCodec(): Promise<ConnectionWireCodec> {
	const codec = new ConnectionWireCodec();
	await codec.applySchemaSync({
		type: "SchemaSync",
		tables: ["users"],
		fields: [["id", "name", "address__city"]],
		fieldFlags: [[0b10, 0, 0]],
		presenceUserFields: ["cursor__x", "cursor__y", "status"],
		presenceSharedFields: ["slide", "playing"],
	});
	return codec;
}

describe("ConnectionWireCodec", () => {
	test("preserves Unix-microsecond timestamps as exact numbers", () => {
		const timestamp = 1_800_000_000_000_003;
		expect(decode(encode(timestamp))).toBe(timestamp);
	});

	test("encodes schema-aware query fields", async () => {
		const codec = await makeCodec();
		const encoded = codec.encode(
			{
				type: "StoreQuery",
				table_index: "users",
				conditions: [["name", 0, "Ada"]],
				orderBy: [
					["address__city", 1],
					["name", 0],
				],
			},
			7,
		);

		expect(encoded.context).toEqual({
			type: "StoreQuery",
			responseTableIndex: 0,
		});
		expect(decode(encoded.bytes)).toEqual({
			type: 0x14,
			id: 7,
			table_index: 0,
			conditions: [[1, 0, "Ada"]],
			orderBy: [
				[2, 1],
				[1, 0],
			],
		});
	});

	test("keeps load-more response table context off the wire", async () => {
		const codec = await makeCodec();
		const encoded = codec.encode(
			{
				type: "StoreLoadMore",
				subId: 9,
				nextCursor: "next",
			},
			8,
			0,
		);

		expect(encoded.context).toEqual({
			type: "StoreLoadMore",
			responseTableIndex: 0,
		});
		expect(decode(encoded.bytes)).toEqual({
			type: 0x17,
			id: 8,
			subId: 9,
			nextCursor: "next",
		});
	});

	test("decodes schema-aware deltas", async () => {
		const codec = await makeCodec();
		const msg = codec.decode(
			encodeToBuffer({
				type: "StoreDelta",
				subId: 1,
				ops: [
					{
						op: "set",
						path: [0, "u1"],
						value: ["u1", "Ada", "London"],
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
					value: { id: "u1", name: "Ada", address: { city: "London" } },
				},
			],
		});
	});

	test("decodes numeric remove ids and rejects old or malformed deltas", async () => {
		const codec = await makeCodec();
		expect(
			codec.decode(encode([WireMessageType.StoreDelta, 1, 1, 0, 42])),
		).toEqual({
			type: "StoreDelta",
			subId: 1,
			ops: [{ op: "remove", path: ["users", "42"] }],
		});
		expect(
			codec.decode(encode([WireMessageType.StoreDelta, 1, 0, 0, ["u1"]])),
		).toBeNull();
		expect(
			codec.decode(encode([WireMessageType.StoreDelta, 1, 0, 0, "u1", null])),
		).toBeNull();
		expect(
			codec.decode(encode([WireMessageType.StoreDelta, 1, 1, 0, null])),
		).toBeNull();
		expect(
			codec.decode(encode([WireMessageType.StoreDelta, 1, 0, 99, []])),
		).toBeNull();
	});

	test("decodes compact presence and shared-state broadcasts", async () => {
		const codec = await makeCodec();
		const joinId = new Uint8Array(16).fill(1);
		const updateId = new Uint8Array(16).fill(2);
		const leaveId = new Uint8Array(16).fill(3);

		expect(
			codec.decode(
				encode([
					WireMessageType.PresenceBroadcast,
					7,
					[
						[
							joinId,
							0,
							[
								[0, 10],
								[1, 20],
								[2, "active"],
							],
							1234,
						],
						[updateId, 1, [[0, 11]]],
						[leaveId, 2],
					],
				]),
			),
		).toEqual({
			type: "PresenceBroadcast",
			subId: 7,
			users: [
				{
					userId: joinId,
					event: "join",
					data: { cursor: { x: 10, y: 20 }, status: "active" },
					joinedAt: 1234,
				},
				{
					userId: updateId,
					event: "update",
					data: { cursor: { x: 11 } },
				},
				{ userId: leaveId, event: "leave" },
			],
		});

		expect(
			codec.decode(
				encode([
					WireMessageType.SharedStateBroadcast,
					8,
					[[[0, 4]], [[1, true]]],
				]),
			),
		).toEqual({
			type: "SharedStateBroadcast",
			subId: 8,
			data: [{ slide: 4 }, { playing: true }],
		});
	});

	test("rejects malformed compact presence pushes and old map forms", async () => {
		const codec = await makeCodec();
		const id = new Uint8Array(16);
		const presence = WireMessageType.PresenceBroadcast;
		const shared = WireMessageType.SharedStateBroadcast;
		const malformed: Array<[string, unknown]> = [
			["unknown array type", [0x7f, 1, []]],
			["short top level", [presence, 1]],
			["long top level", [presence, 1, [], null]],
			["negative subId", [presence, -1, []]],
			["fractional subId", [presence, 1.5, []]],
			["unsafe subId", [presence, Number.MAX_SAFE_INTEGER + 1, []]],
			["non-array payload", [presence, 1, null]],
			["non-array entry", [presence, 1, [null]]],
			["short entry", [presence, 1, [[id]]]],
			["invalid tag", [presence, 1, [[id, 3]]]],
			["fractional tag", [presence, 1, [[id, 1.5, []]]]],
			["string event", [presence, 1, [[id, "join", [], 1]]]],
			["join arity mismatch", [presence, 1, [[id, 0, []]]]],
			["leave arity mismatch", [presence, 1, [[id, 2, null]]]],
			["non-binary userId", [presence, 1, [["id", 2]]]],
			["wrong userId length", [presence, 1, [[new Uint8Array(15), 2]]]],
			["non-array data", [presence, 1, [[id, 1, null]]]],
			["malformed data pair", [presence, 1, [[id, 1, [[0]]]]]],
			["negative field index", [presence, 1, [[id, 1, [[-1, 1]]]]]],
			["fractional field index", [presence, 1, [[id, 1, [[0.5, 1]]]]]],
			["unknown user field", [presence, 1, [[id, 1, [[99, 1]]]]]],
			["negative joinedAt", [presence, 1, [[id, 0, [], -1]]]],
			["fractional joinedAt", [presence, 1, [[id, 0, [], 1.5]]]],
			[
				"unsafe joinedAt",
				[presence, 1, [[id, 0, [], Number.MAX_SAFE_INTEGER + 1]]],
			],
			["shared top-level arity", [shared, 1, [], null]],
			["shared non-array payload", [shared, 1, null]],
			["shared non-array patch", [shared, 1, [null]]],
			["shared malformed pair", [shared, 1, [[[0]]]]],
			["shared invalid field index", [shared, 1, [[[99, 1]]]]],
		];

		for (const [name, raw] of malformed) {
			expect(codec.decode(encode(raw)), name).toBeNull();
		}
		expect(
			codec.decode(encode({ type: presence, subId: 1, users: [] })),
		).toBeNull();
		expect(
			codec.decode(encode({ type: shared, subId: 1, data: [] })),
		).toBeNull();
	});

	test("decodeMulti decodes compact presence and shared pushes", async () => {
		const codec = await makeCodec();
		const id = new Uint8Array(16);
		const frame = new Uint8Array([
			...encode([WireMessageType.PresenceBroadcast, 1, [[id, 2]]]),
			...encode([WireMessageType.SharedStateBroadcast, 2, [[[0, 3]]]]),
			...new Uint8Array(encodeToBuffer({ type: "ok", id: 7 })),
		]);

		expect(codec.decodeMulti(frame)).toEqual([
			{
				type: "PresenceBroadcast",
				subId: 1,
				users: [{ userId: id, event: "leave" }],
			},
			{ type: "SharedStateBroadcast", subId: 2, data: [{ slide: 3 }] },
			{ type: "ok", id: 7 },
		]);
	});

	test("decodeMulti drops malformed compact presence between valid messages", async () => {
		const codec = await makeCodec();
		const frame = new Uint8Array([
			...new Uint8Array(encodeToBuffer({ type: "ok", id: 1 })),
			...encode([
				WireMessageType.PresenceBroadcast,
				1,
				[[new Uint8Array(15), 2]],
			]),
			...new Uint8Array(encodeToBuffer({ type: "ok", id: 2 })),
		]);

		expect(codec.decodeMulti(frame)).toEqual([
			{ type: "ok", id: 1 },
			{ type: "ok", id: 2 },
		]);
	});

	test("decodeMulti decodes all concatenated messages in a frame", async () => {
		const codec = await makeCodec();
		const ok = encodeToBuffer({ type: "ok", id: 7 });
		const delta = encodeToBuffer({
			type: "StoreDelta",
			subId: 1,
			ops: [
				{
					op: "set",
					path: [0, "u1"],
					value: ["u1", "Ada", "London"],
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
					value: { id: "u1", name: "Ada", address: { city: "London" } },
				},
			],
		});
	});

	test("decodeMulti handles single-message, empty, and invalid frames", async () => {
		const codec = await makeCodec();
		const single = codec.decodeMulti(encodeToBuffer({ type: "ok", id: 1 }));
		expect(single).toHaveLength(1);
		expect(single[0]).toEqual({ type: "ok", id: 1 });
		expect(codec.decodeMulti(new ArrayBuffer(0))).toEqual([]);
		expect(codec.decodeMulti(new Uint8Array([0xc1]))).toEqual([]);
		expect(
			codec.decode(encode([WireMessageType.StoreDelta, 1, 0, 0, null])),
		).toBeNull();
	});

	test("decodeMulti drops a malformed delta and continues", async () => {
		const codec = await makeCodec();
		const malformed = encode([WireMessageType.StoreDelta, 1, 0, 0, ["u1"]]);
		const ok = new Uint8Array(encodeToBuffer({ type: "ok", id: 7 }));
		const frame = new Uint8Array(malformed.byteLength + ok.byteLength);
		frame.set(malformed, 0);
		frame.set(ok, malformed.byteLength);

		expect(codec.decodeMulti(frame)).toEqual([{ type: "ok", id: 7 }]);
	});

	test("decodes every correlated store row through one nested record path", async () => {
		const codec = await makeCodec();
		for (const type of [
			"StoreQuery",
			"StoreSubscribe",
			"StoreLoadMore",
		] as const) {
			const ok = codec.decodeOkResponse(
				{
					type: "ok",
					id: 2,
					value: [["u1", "Ada", "London"]] as never,
				},
				{ type, responseTableIndex: 0 },
			);

			expect(ok.value).toEqual([
				{ id: "u1", name: "Ada", address: { city: "London" } },
			]);
		}
	});

	test("rejects malformed correlated store rows", async () => {
		const codec = await makeCodec();
		for (const type of [
			"StoreQuery",
			"StoreSubscribe",
			"StoreLoadMore",
		] as const) {
			expect(() =>
				codec.decodeOkResponse(
					{ type: "ok", id: 2, value: null },
					{ type, responseTableIndex: 0 },
				),
			).toThrow("Invalid positional store response");
			expect(() =>
				codec.decodeOkResponse(
					{ type: "ok", id: 2, value: [null] },
					{ type, responseTableIndex: 0 },
				),
			).toThrow("Invalid positional store record");
			expect(() =>
				codec.decodeOkResponse(
					{ type: "ok", id: 2, value: [["u1"]] as never },
					{ type, responseTableIndex: 0 },
				),
			).toThrow("record field count 1 does not match schema field count 3");
		}
	});
});
