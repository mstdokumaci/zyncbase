import { expect, test } from "bun:test";
import {
	COUNTRY_CHUNK_WIDTH,
	countryChunkIndex,
	HEIGHT,
	movementPaints,
	WIDTH,
} from "./shared";

const land = new Uint8Array(WIDTH * HEIGHT).fill(1);
const code = () => 7;

test("movement paints follow one-cell cardinal moves", () => {
	const previous = new Map([[1, { x: 100, y: 100 }]]);
	const right = movementPaints(
		previous,
		[{ slot: 1, x: 101, y: 100 }],
		land,
		code,
	);
	expect(right).toEqual([
		{ chunk: countryChunkIndex(101, 100), cell: 100 * WIDTH + 101, code: 7 },
	]);
	expect(
		movementPaints(previous, [{ slot: 1, x: 100, y: 101 }], land, code),
	).toHaveLength(1);
	expect(
		movementPaints(previous, [{ slot: 1, x: 99, y: 100 }], land, code),
	).toHaveLength(1);
	expect(
		movementPaints(previous, [{ slot: 1, x: 100, y: 99 }], land, code),
	).toHaveLength(1);
});

test("movement paints follow the wrapped seam", () => {
	const west = movementPaints(
		new Map([[1, { x: 0, y: 50 }]]),
		[{ slot: 1, x: WIDTH - 1, y: 50 }],
		land,
		code,
	);
	expect(west).toEqual([
		{
			chunk: countryChunkIndex(WIDTH - 1, 50),
			cell: 50 * WIDTH + WIDTH - 1,
			code: 7,
		},
	]);
	const east = movementPaints(
		new Map([[1, { x: WIDTH - 1, y: 50 }]]),
		[{ slot: 1, x: 0, y: 50 }],
		land,
		code,
	);
	expect(east).toHaveLength(1);
	expect(east[0]?.chunk).toBe(countryChunkIndex(0, 50));
});

test("prediction skips teleports, stationary dots, water, and unknown colors", () => {
	const previous = new Map([[1, { x: 100, y: 100 }]]);
	expect(
		movementPaints(previous, [{ slot: 1, x: 102, y: 100 }], land, code),
	).toEqual([]);
	expect(
		movementPaints(previous, [{ slot: 1, x: 100, y: 100 }], land, code),
	).toEqual([]);
	const water = 100 * WIDTH + 101;
	land[water] = 0;
	expect(
		movementPaints(previous, [{ slot: 1, x: 101, y: 100 }], land, code),
	).toEqual([]);
	land[water] = 1;
	expect(
		movementPaints(previous, [{ slot: 1, x: 101, y: 100 }], land, () => 0),
	).toEqual([]);
	expect(
		movementPaints(new Map(), [{ slot: 1, x: 101, y: 100 }], land, code),
	).toEqual([]);
});

test("prediction returns paints for multiple moved dots", () => {
	const previous = new Map([
		[1, { x: 100, y: 100 }],
		[2, { x: COUNTRY_CHUNK_WIDTH - 1, y: 10 }],
	]);
	const paints = movementPaints(
		previous,
		[
			{ slot: 1, x: 101, y: 100 },
			{ slot: 2, x: COUNTRY_CHUNK_WIDTH, y: 10 },
		],
		land,
		code,
	);
	expect(paints).toHaveLength(2);
	expect(paints[0]?.cell).toBe(100 * WIDTH + 101);
	expect(paints[1]?.chunk).toBe(countryChunkIndex(COUNTRY_CHUNK_WIDTH, 10));
});
