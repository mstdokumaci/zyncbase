import { describe, expect, test } from "bun:test";

import { ChunkAssembler, chunkPayload } from "./storage.js";

describe("chunkPayload", () => {
	test("splits at the boundary and pads the final part", () => {
		const bytes = new Uint8Array([1, 2, 3, 4, 5]);
		expect(chunkPayload(bytes, 2).map((part) => [...part])).toEqual([
			[1, 2],
			[3, 4],
			[5],
		]);
	});

	test("keeps a payload that exactly fills one chunk as one part", () => {
		expect(chunkPayload(new Uint8Array(4), 4).length).toBe(1);
	});

	test("returns no parts for empty bytes", () => {
		expect(chunkPayload(new Uint8Array(0), 4)).toEqual([]);
	});

	test("rejects invalid chunk sizes", () => {
		expect(() => chunkPayload(new Uint8Array(1), 0)).toThrow(RangeError);
		expect(() => chunkPayload(new Uint8Array(1), 1.5)).toThrow(RangeError);
	});
});

describe("ChunkAssembler", () => {
	test("completes a single-part payload without a commit row", () => {
		const assembler = new ChunkAssembler();
		const result = assembler.add({
			id: "row-1",
			payloadId: "u1",
			part: 0,
			parts: 1,
			data: new Uint8Array([1, 2, 3]),
		});
		expect(result?.payloadId).toBe("u1");
		expect([...(result?.bytes ?? [])]).toEqual([1, 2, 3]);
	});

	test("assembles parts in any order once the commit row arrives", () => {
		const assembler = new ChunkAssembler();
		expect(
			assembler.add({
				id: "row-2",
				payloadId: "u2",
				part: 1,
				parts: 2,
				data: new Uint8Array([3, 4]),
			}),
		).toBeNull();
		expect(
			assembler.add({
				id: "row-1",
				payloadId: "u2",
				part: 0,
				parts: 2,
				data: new Uint8Array([1, 2]),
			}),
		).toBeNull();
		const result = assembler.add({
			id: "row-3",
			payloadId: "u2",
			part: 2,
			parts: 2,
		});
		expect([...(result?.bytes ?? [])]).toEqual([1, 2, 3, 4]);
		expect(assembler.size).toBe(0);
	});

	test("does not complete a multi-part payload without a commit row", () => {
		const assembler = new ChunkAssembler();
		assembler.add({
			id: "row-1",
			payloadId: "u3",
			part: 0,
			parts: 2,
			data: new Uint8Array([1]),
		});
		expect(
			assembler.add({
				id: "row-2",
				payloadId: "u3",
				part: 1,
				parts: 2,
				data: new Uint8Array([2]),
			}),
		).toBeNull();
	});

	test("does not complete with a missing part", () => {
		const assembler = new ChunkAssembler();
		expect(
			assembler.add({
				id: "row-1",
				payloadId: "u4",
				part: 0,
				parts: 2,
				data: new Uint8Array([1]),
			}),
		).toBeNull();
		expect(
			assembler.add({ id: "row-2", payloadId: "u4", part: 2, parts: 2 }),
		).toBeNull();
	});

	test("ignores malformed rows", () => {
		const assembler = new ChunkAssembler();
		expect(
			assembler.add({
				id: "r",
				payloadId: "u5",
				part: 3,
				parts: 2,
				data: new Uint8Array([1]),
			}),
		).toBeNull();
		expect(
			assembler.add({ id: "r", payloadId: "u5", part: 0, parts: 1 }),
		).toBeNull();
		expect(
			assembler.add({
				id: "r",
				payloadId: "u5",
				part: 0,
				parts: 1,
				data: null,
			}),
		).toBeNull();
	});

	test("reset drops incomplete payloads", () => {
		const assembler = new ChunkAssembler();
		assembler.add({
			id: "r",
			payloadId: "u6",
			part: 0,
			parts: 2,
			data: new Uint8Array([1]),
		});
		assembler.reset();
		expect(assembler.size).toBe(0);
	});
});
