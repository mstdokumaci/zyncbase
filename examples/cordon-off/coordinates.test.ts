import { expect, test } from "bun:test";
import {
	COORDINATES_HEADER_BYTES,
	encodeCoordinates,
	MAX_PLAYERS,
	readCoordinates,
	USER_CHUNK_COUNT,
	USER_CHUNK_HEIGHT,
	USER_CHUNK_WIDTH,
	USER_COLUMNS,
} from "./shared";

test("packed coordinates round-trip across chunk origins", () => {
	for (const index of [
		0,
		USER_COLUMNS - 1,
		USER_COLUMNS,
		USER_CHUNK_COUNT - 1,
	]) {
		const originX = (index % USER_COLUMNS) * USER_CHUNK_WIDTH;
		const originY = Math.floor(index / USER_COLUMNS) * USER_CHUNK_HEIGHT;
		const dots = [
			{ slot: 1, x: originX, y: originY },
			{
				slot: 65535,
				x: originX + USER_CHUNK_WIDTH - 1,
				y: originY + USER_CHUNK_HEIGHT - 1,
			},
			{ slot: 42, x: originX + 7, y: originY + 3 },
		];
		const row = encodeCoordinates(index, dots);
		expect(row.byteLength).toBe(COORDINATES_HEADER_BYTES + dots.length * 4);
		expect(readCoordinates(row)).toEqual(dots);
	}
});

test("empty user chunks round-trip", () => {
	const row = encodeCoordinates(5, []);
	expect(row.byteLength).toBe(COORDINATES_HEADER_BYTES);
	expect(readCoordinates(row)).toEqual([]);
});

test("a full live population fits one chunk's packed dots", () => {
	// Humans cap at MAX_PLAYERS, but bots ride the same chunks, so the packer
	// must accept more than MAX_PLAYERS entries.
	const count = MAX_PLAYERS + 18;
	const dots = Array.from({ length: count }, (_, index) => ({
		slot: index + 1,
		x: index % USER_CHUNK_WIDTH,
		y: Math.floor(index / USER_CHUNK_WIDTH),
	}));
	expect(readCoordinates(encodeCoordinates(0, dots))).toEqual(dots);
});

test("packed coordinates reject malformed rows", () => {
	expect(() => readCoordinates(new Uint8Array(0))).toThrow();
	expect(() => readCoordinates(new Uint8Array(4))).toThrow();
	const good = encodeCoordinates(0, [{ slot: 1, x: 1, y: 2 }]);
	const badVersion = good.slice();
	badVersion[0] = 2;
	expect(() => readCoordinates(badVersion)).toThrow();
	expect(() => readCoordinates(good.slice(0, good.byteLength - 1))).toThrow();
	const extra = new Uint8Array(good.byteLength + 1);
	extra.set(good);
	expect(() => readCoordinates(extra)).toThrow();
	const zeroSlot = good.slice();
	zeroSlot[COORDINATES_HEADER_BYTES] = 0;
	zeroSlot[COORDINATES_HEADER_BYTES + 1] = 0;
	expect(() => readCoordinates(zeroSlot)).toThrow();
	const outOfChunkX = good.slice();
	outOfChunkX[COORDINATES_HEADER_BYTES + 2] = USER_CHUNK_WIDTH;
	expect(() => readCoordinates(outOfChunkX)).toThrow();
	const outOfChunkY = good.slice();
	outOfChunkY[COORDINATES_HEADER_BYTES + 3] = USER_CHUNK_HEIGHT;
	expect(() => readCoordinates(outOfChunkY)).toThrow();
	expect(() => encodeCoordinates(USER_CHUNK_COUNT, [])).toThrow();
	expect(() =>
		encodeCoordinates(0, [{ slot: 1, x: USER_CHUNK_WIDTH, y: 0 }]),
	).toThrow();
	expect(() => encodeCoordinates(0, [{ slot: 0, x: 0, y: 0 }])).toThrow();
});
