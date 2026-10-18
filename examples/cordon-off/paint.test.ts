import { expect, test } from "bun:test";
import {
	COUNTRY_CHUNK_WIDTH,
	countryChunkIndex,
	HEIGHT,
	movementPaints,
	WIDTH,
	wrapX,
} from "./shared";

const land = new Uint8Array(WIDTH * HEIGHT).fill(1);
const code = () => 7;
const noOwner = () => 0;
const ring = [
	[-1, -1],
	[0, -1],
	[1, -1],
	[-1, 0],
	[1, 0],
	[-1, 1],
	[0, 1],
	[1, 1],
] as const;

/** Owners for a cluster of cells; everything else is unowned. */
function cluster(cells: Iterable<readonly [number, number]>, owner: number) {
	const owned = new Set<number>();
	for (const [x, y] of cells) owned.add(y * WIDTH + x);
	return (x: number, y: number) =>
		owned.has(y * WIDTH + x) ? owner : undefined;
}

test("movement paints follow one-cell cardinal moves", () => {
	const previous = new Map([[1, { x: 100, y: 100 }]]);
	const right = movementPaints(
		previous,
		[{ slot: 1, x: 101, y: 100 }],
		land,
		code,
		noOwner,
	);
	expect(right).toEqual([
		{ chunk: countryChunkIndex(101, 100), cell: 100 * WIDTH + 101, code: 7 },
	]);
	expect(
		movementPaints(
			previous,
			[{ slot: 1, x: 100, y: 101 }],
			land,
			code,
			noOwner,
		),
	).toHaveLength(1);
	expect(
		movementPaints(previous, [{ slot: 1, x: 99, y: 100 }], land, code, noOwner),
	).toHaveLength(1);
	expect(
		movementPaints(previous, [{ slot: 1, x: 100, y: 99 }], land, code, noOwner),
	).toHaveLength(1);
});

test("movement paints follow the wrapped seam", () => {
	const west = movementPaints(
		new Map([[1, { x: 0, y: 50 }]]),
		[{ slot: 1, x: WIDTH - 1, y: 50 }],
		land,
		code,
		noOwner,
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
		noOwner,
	);
	expect(east).toHaveLength(1);
	expect(east[0]?.chunk).toBe(countryChunkIndex(0, 50));
});

test("prediction skips teleports, stationary dots, water, and unknown colors", () => {
	const previous = new Map([[1, { x: 100, y: 100 }]]);
	expect(
		movementPaints(
			previous,
			[{ slot: 1, x: 102, y: 100 }],
			land,
			code,
			noOwner,
		),
	).toEqual([]);
	expect(
		movementPaints(
			previous,
			[{ slot: 1, x: 100, y: 100 }],
			land,
			code,
			noOwner,
		),
	).toEqual([]);
	const water = 100 * WIDTH + 101;
	land[water] = 0;
	expect(
		movementPaints(
			previous,
			[{ slot: 1, x: 101, y: 100 }],
			land,
			code,
			noOwner,
		),
	).toEqual([]);
	land[water] = 1;
	expect(
		movementPaints(
			previous,
			[{ slot: 1, x: 101, y: 100 }],
			land,
			() => 0,
			noOwner,
		),
	).toEqual([]);
	expect(
		movementPaints(
			new Map(),
			[{ slot: 1, x: 101, y: 100 }],
			land,
			code,
			noOwner,
		),
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
		noOwner,
	);
	expect(paints).toHaveLength(2);
	expect(paints[0]?.cell).toBe(100 * WIDTH + 101);
	expect(paints[1]?.chunk).toBe(countryChunkIndex(COUNTRY_CHUNK_WIDTH, 10));
});

test("prediction skips a pixel fully surrounded by one enemy country", () => {
	const x = 100,
		y = 100,
		cell = y * WIDTH + x;
	const around: [number, number][] = [
		[x, y],
		...ring.map(([dx, dy]) => [x + dx, y + dy] as [number, number]),
	];
	const previous = new Map([[1, { x: x - 1, y }]]);
	expect(
		movementPaints(
			previous,
			[{ slot: 1, x, y }],
			land,
			code,
			cluster(around, 9),
		),
	).toEqual([]);
	// Any other owner in the ring leaves the pixel a real route out.
	expect(
		movementPaints(
			previous,
			[{ slot: 1, x, y }],
			land,
			code,
			cluster(
				around.filter(([cx, cy]) => cy * WIDTH + cx !== cell - WIDTH),
				9,
			),
		),
	).toHaveLength(1);
});

test("the surround test wraps the seam but not the poles", () => {
	const y = 50;
	const seam: [number, number][] = [
		[0, y],
		...ring.map(([dx, dy]) => [wrapX(dx), y + dy] as [number, number]),
	];
	expect(
		movementPaints(
			new Map([[1, { x: 1, y }]]),
			[{ slot: 1, x: 0, y }],
			land,
			code,
			cluster(seam, 9),
		),
	).toEqual([]);
	const pole: [number, number][] = [
		[100, 0],
		[99, 0],
		[101, 0],
		[99, 1],
		[101, 1],
		[100, 1],
	];
	expect(
		movementPaints(
			new Map([[1, { x: 99, y: 0 }]]),
			[{ slot: 1, x: 100, y: 0 }],
			land,
			code,
			cluster(pole, 9),
		),
	).toHaveLength(1);
});

test("a neutral centre is not treated as enemy territory", () => {
	const x = 100,
		y = 100;
	const around: [number, number][] = ring.map(([dx, dy]) => [x + dx, y + dy]);
	expect(
		movementPaints(
			new Map([[1, { x: x - 1, y }]]),
			[{ slot: 1, x, y }],
			land,
			code,
			cluster(around, 9),
		),
	).toHaveLength(1);
});
