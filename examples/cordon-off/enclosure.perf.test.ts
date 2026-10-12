import { expect, spyOn, test } from "bun:test";
import { HoleFiller } from "./filler";
import { countryChunkIndex, HEIGHT, terrain, WIDTH } from "./shared";
import { World } from "./world";

// Synthetic geometry keeps this repeatable without a saved game or a database.
// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: the fixture constructs the compared shapes and resets each measured step identically.
function workload(size: number, rotated: boolean, shape: string) {
	const land = new Uint8Array(WIDTH * HEIGHT).fill(1);
	const seed = new World(land);
	const seedCountry = seed.country("Benchmark");
	if (!seedCountry) throw new Error("Missing benchmark country");
	const width = size * (shape === "square" ? 5 : 10);
	const height = size * (shape === "square" ? 5 : 7);
	const position = (x: number, y: number) =>
		rotated ? { x: 20 + y, y: 20 + x } : { x: 20 + x, y: 20 + y };
	const middle = Math.floor(height / 2);
	for (let y = 0; y < height; y++) {
		for (let x = 0; x < width; x++) {
			const wall = x < size || y < size || y >= height - size;
			const closingWall =
				shape === "closing" && x === width - 1 && y !== middle;
			if (shape !== "square" && !wall && !closingWall) continue;
			const p = position(x, y);
			seed.owners[p.y * WIDTH + p.x] = 1;
			seed.dirtyCountryChunks.add(countryChunkIndex(p.x, p.y));
		}
	}
	const world = new World(land);
	world.restore(
		[seedCountry],
		[...seed.dirtyCountryChunks].map((index) => seed.countryChunk(index)),
	);
	world.input(
		"walker",
		{
			name: "Walker",
			country_id: 1,
			direction: "idle",
			seq: 0,
		},
		0,
	);
	const player = world.players.get("walker");
	const country = world.countries.get(1);
	if (!player || !country)
		throw new Error("Missing benchmark player or country");
	const start = position(
		shape === "closing" ? width : shape === "square" ? width - 1 : size - 1,
		middle,
	);
	const target = position(
		shape === "closing" ? width - 1 : shape === "square" ? width : size,
		middle,
	);
	player.direction = shape === "closing" ? "left" : rotated ? "down" : "right";
	const initial = world.owners.slice();
	const count = country.count;
	const reset = () => {
		world.owners.set(initial);
		country.count = count;
		world.dirtyCountryChunks.clear();
		world.dirtyUserChunks.clear();
		world.dirtyCountries.clear();
		Object.assign(player, start);
		player.credit =
			world.stepCost(
				1,
				start.y * WIDTH + start.x,
				target.y * WIDTH + target.x,
			) - 1;
	};
	const step = () => world.tick(0);
	const verify = () => {
		expect([player.x, player.y]).toEqual([target.x, target.y]);
		expect(country.count).toBe(
			shape === "closing" ? width * height : count + 1,
		);
	};
	return { world, reset, step, verify, count };
}

// Per-tick budgets measured on this implementation, taken over repeated runs
// with headroom for GC and scheduling noise. The closure budget is the one that
// matters: RULES runs a 50 ms tick, so a single large enclosure must stay far
// inside one. The two large-U shapes are also what the ring-run gate buys: a
// gate that walks every exit proof queues far more enclosure work, and they are
// the shapes that notice. GAME_BENCH prints what each shape actually costs.
test.each([
	["small U", 10, false, "open", 0.02],
	["large U", 90, false, "open", 0.03],
	["rotated large U", 90, true, "open", 0.012],
	["large square", 90, false, "square", 0.012],
	["large loop closure", 90, false, "closing", 6],
] as const)("enclosure work: %s", (name, size, rotated, shape, budgetMs) => {
	const { world, reset, step, verify, count } = workload(size, rotated, shape);
	reset();
	const fill = spyOn(HoleFiller.prototype, "fill");
	try {
		step();
		expect(fill).toHaveBeenCalledTimes(shape === "closing" ? 1 : 0);
		if (shape === "closing")
			expect(fill.mock.calls[0].slice(0, 2)).toEqual([world.owners, 1]);
	} finally {
		fill.mockRestore();
	}
	verify();
	// A single step is microseconds for every shape but the closure, so the
	// fastest sample is the only one the timer noise cannot move.
	let best = Infinity;
	for (let i = 0; i < 21; i++) {
		reset();
		const started = performance.now();
		step();
		const elapsed = performance.now() - started;
		verify();
		if (i >= 3 && elapsed < best) best = elapsed;
	}
	if (process.env.GAME_BENCH === "1")
		console.log(
			JSON.stringify({
				name,
				ownedPixels: count,
				worldScans: shape === "closing" ? 1 : 0,
				bestMs: Number(best.toFixed(4)),
			}),
		);
	expect(best).toBeLessThan(budgetMs);
});

// Ordinary painting is the per-claim hot path: every mover step asks whether it
// could enclose anything. A big block beside the mover makes the gate's exit
// proofs walk the longest possible rays, which is the worst case for that work.
function paintWorkload(size: number) {
	const land = new Uint8Array(WIDTH * HEIGHT).fill(1);
	const seed = new World(land);
	const seedCountry = seed.country("Painter");
	if (!seedCountry) throw new Error("Missing painter country");
	const chunks = new Set<number>();
	for (let y = 20; y < 20 + size; y++)
		for (let x = 20; x < 20 + size; x++) {
			seed.owners[y * WIDTH + x] = 1;
			chunks.add(countryChunkIndex(x, y));
		}
	const world = new World(land);
	world.restore(
		[seedCountry],
		[...chunks].map((index) => seed.countryChunk(index)),
	);
	world.input(
		"painter",
		{ name: "Painter", country_id: 1, direction: "right", seq: 0 },
		0,
	);
	const player = world.players.get("painter");
	const country = world.countries.get(1);
	if (!player || !country) throw new Error("Missing painter or country");
	player.x = 20 + size;
	player.y = 20 + (size >> 1);
	const before = country.count;
	return {
		world,
		run: (steps: number) => {
			for (let i = 0; i < steps; i++) world.tick(i);
		},
		verify: () => expect(country.count).toBeGreaterThan(before),
	};
}

// A tick this cheap is buried in GC noise, so take the best batch rather than
// the mean: one unlucky collection must not read as a gate regression. Painting
// sits far under any of these, and the ring-run gate is measured by the U shapes
// above; these are here to catch a per-claim cost that has grown outright.
test.each([
	["beside a small block", 50, 0.3],
	["beside a large block", 200, 0.3],
] as const)("ordinary painting %s stays within budget", (name, size, budgetUs) => {
	const { run, verify } = paintWorkload(size);
	run(2000);
	const batch = 20000;
	let best = Infinity;
	for (let i = 0; i < 5; i++) {
		const started = performance.now();
		run(batch);
		best = Math.min(best, (performance.now() - started) / batch);
	}
	verify();
	const usPerStep = best * 1000;
	if (process.env.GAME_BENCH === "1")
		console.log(
			JSON.stringify({
				name,
				ownedPixels: size * size,
				worldScans: 0,
				usPerTick: Number(usPerStep.toFixed(3)),
			}),
		);
	expect(usPerStep).toBeLessThan(budgetUs);
});

// The nine spawn cities, matching the ones README.md documents.
const SPAWNS = [
	[990, 226],
	[911, 259],
	[1095, 201],
	[1535, 256],
	[1153, 416],
	[974, 555],
	[1688, 760],
	[553, 694],
	[190, 312],
] as const;

// Nine nations with their bots, contending for the real map. Every synthetic
// shape above settles after one closure; a live game keeps all nine gates busy
// for thousands of ticks, which is the only way a gate that queues enclosure
// work it can prove is unnecessary ever shows up.
// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: one fixture seeds nine countries, joins them, then runs the measured ticks.
function gameWorkload(radius: number, ticks: number) {
	const land = terrain();
	const seed = new World(land);
	const countries = [];
	const chunks = new Set<number>();
	for (const [i, spawn] of SPAWNS.entries()) {
		const country = seed.country(`Nation${i}`);
		if (!country) throw new Error("Missing benchmark country");
		countries.push(country);
		for (let dy = -radius; dy <= radius; dy++)
			for (let dx = -radius; dx <= radius; dx++) {
				if (dx * dx + dy * dy > radius * radius) continue;
				const x = spawn[0] + dx,
					y = spawn[1] + dy;
				if (x < 0 || x >= WIDTH || y < 0 || y >= HEIGHT) continue;
				if (!land[y * WIDTH + x]) continue;
				seed.owners[y * WIDTH + x] = country.country_id;
				chunks.add(countryChunkIndex(x, y));
			}
	}
	const world = new World(land);
	world.restore(
		countries,
		[...chunks].map((index) => seed.countryChunk(index)),
	);
	for (const [i, country] of countries.entries())
		world.input(
			`h${i}`,
			{
				name: `Human${i}`,
				country_id: country.country_id,
				direction: "idle",
				seq: 0,
			},
			0,
		);
	world.startBots(0);
	for (let i = 0; i < ticks; i++) world.tick(i * 50);
	return {
		players: world.players.size,
		owned: () =>
			[...world.countries.values()].reduce((sum, c) => sum + c.count, 0),
	};
}

// The world seeds its own generator, so this count is exact and does not move
// with the machine the way a millisecond budget does. One fill is one
// whole-country bbox rescan that the bounded local search failed to replace;
// a gate that skips the ray walks lands near 2949 here instead of 570.
test("contending nations stay off the whole-country fallback scan", () => {
	const fill = spyOn(HoleFiller.prototype, "fill");
	try {
		const { players, owned } = gameWorkload(110, 6000);
		expect(players).toBe(18);
		expect(fill).toHaveBeenCalledTimes(570);
		// Capture semantics, pinned. Any other total means the gate changed which
		// enclosures resolve, not merely how cheaply they are found.
		expect(owned()).toBe(288359);
	} finally {
		fill.mockRestore();
	}
});
