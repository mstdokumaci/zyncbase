import { expect, test } from "bun:test";
import {
	enclosedOnRestore,
	enclosedRegion,
	enclosureStarts,
} from "./enclosure";
import { chunkIndex, type Direction, HEIGHT, WIDTH } from "./shared";
import { World } from "./world";

type Pixel = [number, number, number];

test.each([
	[3, 20, 20],
	[3, 0, 0],
	[3, WIDTH - 3, 0],
	[3, 0, HEIGHT - 3],
	[3, WIDTH - 3, HEIGHT - 3],
	[4, 20, 20],
	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: exhaust the small bitmaps and compare each eligible paint against the exterior flood.
])("local checks match a full exterior flood: size %i at %i,%i", (size, left, top) => {
	const owners = new Uint16Array(WIDTH * HEIGHT);
	const bounds = { left, top, right: left + size - 1, bottom: top + size - 1 };
	const cells = Array.from(
		{ length: size * size },
		(_, i) => (top + Math.floor(i / size)) * WIDTH + left + (i % size),
	);
	// Every position on 3x3 maps covers edges and diagonal joins. The 4x4
	// maps add paths beyond the local ring for an interior painted cell.
	for (let mask = 0; mask < 2 ** cells.length; mask++) {
		for (const painted of size === 3 ? cells : [cells[size + 1]]) {
			for (const [i, cell] of cells.entries()) owners[cell] = (mask >> i) & 1;
			// Normal movement starts from a world whose existing enclosures are filled.
			for (const cell of enclosedOnRestore(owners, 1, bounds)) owners[cell] = 1;
			if (owners[painted]) continue;
			owners[painted] = 1;
			const expected = enclosedOnRestore(owners, 1, bounds);
			const captured = new Set<number>();
			for (const start of enclosureStarts(owners, 1, painted))
				for (const cell of enclosedRegion(owners, 1, bounds, start))
					captured.add(cell);
			expect([...captured].sort((a, b) => a - b)).toEqual(expected);
		}
	}
});

function scenario(pixels: Pixel[], water: [number, number][] = []) {
	const land = new Uint8Array(WIDTH * HEIGHT).fill(1);
	for (const [x, y] of water) land[y * WIDTH + x] = 0;
	const seed = new World(land);
	for (const code of [1, 2])
		seed.countries.set(code, {
			id: String(code),
			code,
			name: String(code),
			color: "old",
			count: 0,
		});
	const chunks = new Set<number>();
	for (const [x, y, code] of pixels) {
		seed.owners[y * WIDTH + x] = code;
		chunks.add(chunkIndex(x, y));
	}
	const world = new World(land);
	world.restore(
		[...seed.countries.values()],
		[...chunks].map((index) => seed.chunk(index)),
	);
	world.dirtyChunks.clear();
	let now = 0,
		seq = 0;
	const input = (id: string, country: number, direction: Direction) =>
		world.input(
			id,
			{ country: String(country), direction, seq: ++seq, sentAt: now },
			now,
		);
	const actor = (id: string, code: number, x: number, y: number) => {
		input(id, code, "idle");
		const player = world.players.get(id);
		if (!player) throw new Error("Missing player");
		player.x = x;
		player.y = y;
		return player;
	};
	const move = (id: string, direction: Direction) => {
		const player = world.players.get(id);
		if (!player) throw new Error("Missing player");
		const offset = { up: -WIDTH, down: WIDTH, left: -1, right: 1, idle: 0 }[
			direction
		];
		const from = player.y * WIDTH + player.x;
		const cost = world.stepCost(player.code, from, from + offset);
		input(id, player.code, direction);
		for (let i = 0; i < cost; i++) world.tick(++now);
		input(id, player.code, "idle");
	};
	return {
		world,
		chunks,
		actor,
		move,
		owner: (x: number, y: number) => world.owners[y * WIDTH + x],
	};
}

test("closing ordinary territory captures enclosed land, updates all chunks and scores, and survives restart", () => {
	const pixels: Pixel[] = [
		[32, 32, 2],
		[40, 40, 2],
	];
	for (let y = 30; y <= 36; y++)
		for (let x = 30; x <= 36; x++) {
			if (
				(x === 30 || x === 36 || y === 30 || y === 36) &&
				!(x === 33 && y === 36)
			)
				pixels.push([x, y, 1]);
		}
	const { world, chunks, actor, move, owner } = scenario(pixels, [[34, 34]]);
	expect(owner(32, 32)).toBe(2);
	actor("attacker", 1, 32, 36);
	move("attacker", "right");
	expect(owner(32, 32)).toBe(1);
	expect(owner(34, 34)).toBe(0);
	expect(owner(40, 40)).toBe(2);
	expect(world.countries.get(1)?.count).toBe(48);
	expect(world.countries.get(2)?.count).toBe(1);
	for (const [x, y] of [
		[31, 31],
		[32, 31],
		[31, 32],
		[32, 32],
	])
		expect(world.dirtyChunks.has(chunkIndex(x, y))).toBe(true);
	const restored = new World(world.land);
	restored.restore(
		[...world.countries.values()],
		[...chunks].map((index) => world.chunk(index)),
	);
	expect(restored.owners).toEqual(world.owners);
	expect([...restored.countries.values()]).toEqual([
		...world.countries.values(),
	]);
});

test("a defensive enclosure reclaims a severed extension and new paint until reconnection or escape", () => {
	const pixels: Pixel[] = [];
	for (let y = 30; y <= 40; y++)
		for (let x = 30; x <= 40; x++) pixels.push([x, y, 1]);
	for (let x = 28; x <= 37; x++) pixels.push([x, 35, 2]);
	const { actor, move, owner } = scenario(pixels);
	const attacker = actor("attacker", 2, 37, 35);
	actor("defender", 1, 33, 34);
	expect(owner(37, 35)).toBe(2);
	move("defender", "down");
	expect(owner(32, 35)).toBe(2);
	expect(owner(33, 35)).toBe(1);
	expect(owner(37, 35)).toBe(1);
	move("attacker", "right");
	expect(attacker.x).toBe(38);
	expect(owner(38, 35)).toBe(1);
	for (let i = 0; i < 4; i++) move("attacker", "left");
	expect(owner(34, 35)).toBe(1);
	move("attacker", "left");
	expect(owner(33, 35)).toBe(2);
	move("attacker", "right");
	expect(owner(34, 35)).toBe(2);
	const escape_line = actor("escape", 2, 38, 35);
	for (let i = 0; i < 5; i++) move("escape", "up");
	expect(escape_line.y).toBe(30);
	expect(owner(38, 31)).toBe(1);
	expect(owner(38, 30)).toBe(2);
});

test("water gaps keep an area open and do not become a painted boundary", () => {
	const pixels: Pixel[] = [[33, 33, 2]];
	for (let y = 30; y <= 36; y++)
		for (let x = 30; x <= 36; x++) {
			if (
				(x === 30 || x === 36 || y === 30 || y === 36) &&
				!(x === 33 && y === 36)
			)
				pixels.push([x, y, 1]);
		}
	const { actor, move, owner } = scenario(pixels, [[33, 36]]);
	actor("walker", 1, 32, 36);
	move("walker", "right");
	expect(owner(33, 36)).toBe(0);
	expect(owner(33, 33)).toBe(2);
});
