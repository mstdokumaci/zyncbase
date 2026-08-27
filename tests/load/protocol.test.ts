import { describe, expect, test } from "bun:test";
import { decode, encode } from "@msgpack/msgpack";
import { WireMessageType as SdkWireMessageType } from "../../sdk/typescript/src/connection_wire";
import {
	concatBytes,
	decodeMessages,
	documentId,
	encodeMessage,
	pairValue,
	WireMessageType,
	WireSchema,
} from "./protocol";

describe("load-test wire protocol", () => {
	test("message IDs stay aligned with the SDK", () => {
		for (const [name, value] of Object.entries(WireMessageType)) {
			expect(SdkWireMessageType[name as keyof typeof SdkWireMessageType]).toBe(
				value,
			);
		}
	});

	test("decodes every MessagePack object in a concatenated frame", () => {
		const frame = concatBytes(
			encodeMessage({ type: WireMessageType.ok, id: 1 }),
			encodeMessage({ type: WireMessageType.StoreDelta, subId: 2, ops: [] }),
		);
		expect(decodeMessages(frame)).toEqual([
			{ type: WireMessageType.ok, id: 1 },
			{ type: WireMessageType.StoreDelta, subId: 2, ops: [] },
		]);
	});

	test("is wire-compatible with the SDK MessagePack codec", () => {
		const message = {
			type: WireMessageType.StoreSet,
			id: 7,
			path: [0, documentId(42)],
			value: [[1, Date.now()]],
		};
		expect(decode(encodeMessage(message))).toEqual(message);
		expect(decodeMessages(encode(message) as Uint8Array)).toEqual([message]);
	});

	test("maps schema names and pair-array values", () => {
		const schema = new WireSchema({
			type: WireMessageType.SchemaSync,
			tables: ["users", "bench"],
			fields: [["id"], ["id", "match", "writer"]],
			presenceUserFields: ["writer", "sequence"],
			presenceSharedFields: ["writer", "sequence"],
		});

		expect(schema.table("bench")).toBe(1);
		expect(schema.field(1, "match")).toBe(1);
		expect(schema.presenceUserField("sequence")).toBe(1);
		expect(schema.presenceSharedField("writer")).toBe(0);
		expect(pairValue([[0, 42]], 0)).toBe(42);
	});

	test("creates stable, distinct bin16 document IDs", () => {
		expect(documentId(1)).toHaveLength(16);
		expect(documentId(1)).toEqual(documentId(1));
		expect(documentId(1)).not.toEqual(documentId(2));
	});
});
