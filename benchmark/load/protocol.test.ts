import { describe, expect, test } from "bun:test";
import { decode, encode } from "@msgpack/msgpack";
import {
	fromBase64,
	probeStoreFrame,
	rebaseDocId,
	rebaseNamespace,
} from "./protocol";

function encodeBase64(value: unknown): string {
	return Buffer.from(encode(value)).toString("base64");
}

function storeSet(id: Uint8Array, value: string) {
	return {
		type: 0x11,
		path: [1, id],
		value: [3, value],
		id: 6,
	};
}

describe("rebaseNamespace", () => {
	test("changes only the namespace", () => {
		const template = encodeBase64({ type: 0x10, namespace: "public", id: 1 });
		const decoded = decode(fromBase64(rebaseNamespace(template, "public-s2")));
		expect(decoded).toEqual({ type: 0x10, namespace: "public-s2", id: 1 });
	});
});

describe("rebaseDocId", () => {
	const id = new Uint8Array(16).fill(0x80);

	test("shard 0 keeps the captured frame", () => {
		const template = encodeBase64(storeSet(id, "item-0"));
		expect(rebaseDocId(template, 0)).toBe(template);
	});

	test("patches only the last id byte", () => {
		const template = encodeBase64(storeSet(id, "item-0"));
		const decoded = decode(fromBase64(rebaseDocId(template, 3))) as {
			path: [number, Uint8Array];
		};
		const rebased = decoded.path[1];
		expect(rebased).toBeInstanceOf(Uint8Array);
		expect([...rebased.slice(0, -1)]).toEqual([...id.slice(0, -1)]);
		expect(rebased.at(-1)).toBe(0x80 ^ 3);
	});

	test("create and update for one doc share the id", () => {
		const create = rebaseDocId(encodeBase64(storeSet(id, "item-0")), 2);
		const update = rebaseDocId(encodeBase64(storeSet(id, "updated-item-0")), 2);
		const createId = (
			decode(fromBase64(create)) as { path: [number, Uint8Array] }
		).path[1];
		const updateId = (
			decode(fromBase64(update)) as { path: [number, Uint8Array] }
		).path[1];
		expect(updateId).toEqual(createId);
	});
});

describe("probeStoreFrame", () => {
	test("replaces the string field without touching the document id", () => {
		const id = new Uint8Array(16).fill(0x80);
		const template = encodeBase64(storeSet(id, "item-0"));
		const decoded = decode(
			fromBase64(probeStoreFrame(template, "probe-1")),
		) as {
			path: [number, Uint8Array];
			value: unknown[];
		};
		expect(decoded.path[1]).toEqual(id);
		expect(decoded.value).toContain("probe-1");
		expect(decoded.value).not.toContain("item-0");
	});
});
