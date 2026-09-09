import { expect, spyOn, test } from "bun:test";
import { HoleFiller } from "./filler";
import { chunkIndex, HEIGHT, WIDTH } from "./shared";
import { World } from "./world";

// Synthetic geometry keeps this repeatable without a saved game or a database.
// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: the fixture constructs the compared shapes and resets each measured step identically.
function workload(size: number, rotated: boolean, shape: string) {
	const land = new Uint8Array(WIDTH * HEIGHT).fill(1);
	const seed = new World(land);
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
			seed.dirtyChunks.add(chunkIndex(p.x, p.y));
		}
	}
	const world = new World(land);
	world.restore(
		[{ id: "1", code: 1, name: "Benchmark", color: "red", count: 0 }],
		[...seed.dirtyChunks].map((index) => seed.chunk(index)),
	);
	world.input(
		"walker",
		{ country: "Benchmark", direction: "idle", seq: 0, sentAt: 0 },
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
		world.dirtyChunks.clear();
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

test.each([
	["small U", 10, false, "open"],
	["large U", 90, false, "open"],
	["rotated large U", 90, true, "open"],
	["large square", 90, false, "square"],
	["large loop closure", 90, false, "closing"],
	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: call-count verification and optional warmup timing share the same fixture reset.
] as const)("enclosure work: %s", (name, size, rotated, shape) => {
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
	if (process.env.GAME_BENCH === "1") {
		const samples: number[] = [];
		for (let i = 0; i < 9; i++) {
			reset();
			const started = performance.now();
			step();
			const elapsed = performance.now() - started;
			verify();
			if (i >= 2) samples.push(elapsed);
		}
		samples.sort((a, b) => a - b);
		console.log(
			JSON.stringify({
				name,
				ownedPixels: count,
				worldScans: shape === "closing" ? 1 : 0,
				medianMs: Number(samples[3].toFixed(3)),
			}),
		);
	}
});
