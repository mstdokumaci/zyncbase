import { expect, test } from "bun:test";
import { enemyRays, planBot, roamPlan } from "./bots";
import { HEIGHT, WIDTH } from "./shared";
import { World } from "./world";

// Array-based reference walks keep route construction independent of scoring.
function walk(from: number, to: number, horizontalFirst: boolean) {
	const cells: number[] = [];
	const corner = horizontalFirst
		? Math.floor(from / WIDTH) * WIDTH + (to % WIDTH)
		: Math.floor(to / WIDTH) * WIDTH + (from % WIDTH);
	for (const end of [corner, to]) {
		const step =
			Math.sign(end - from) * (end % WIDTH === from % WIDTH ? WIDTH : 1);
		while (from !== end) {
			from += step;
			cells.push(from);
		}
	}
	return cells;
}

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: compare all four scoring traces with materialized routes across land, coast and border fixtures.
test("bot scoring matches executed routes across square sizes, including revisits, coastal returns and ties", () => {
	const world = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	const stepCost = world.stepCost.bind(world);
	for (const side of [5, 13]) {
		for (const [left, top] of [
			[0, 0],
			[Math.floor(54 / side) * side, Math.floor(54 / side) * side],
			[Math.floor(1980 / side) * side, Math.floor(981 / side) * side],
		] as const) {
			const patch = top * WIDTH + left;
			const area = Array.from({ length: side * side }, (_, i) => {
				const row = Math.floor(i / side);
				return (
					patch + row * WIDTH + (row % 2 ? side - 1 - (i % side) : i % side)
				);
			});
			const edge: number[] = [];
			for (let x = 0; x < side; x++) edge.push(patch + x);
			for (let y = 1; y < side; y++) edge.push(patch + y * WIDTH + side - 1);
			for (let x = side - 2; x >= 0; x--)
				edge.push(patch + (side - 1) * WIDTH + x);
			for (let y = side - 2; y > 0; y--) edge.push(patch + y * WIDTH);
			for (const loop of [true, false]) {
				world.land.fill(1);
				world.owners.fill(1);
				for (const [i, cell] of area.entries()) world.owners[cell] = i % 3;
				if (!loop) world.land[patch + 1] = 0;
				const route = loop ? edge : area;
				for (const from of [
					route[0],
					route[route.length - 1],
					patch + 2 * WIDTH + 2,
					patch + 13 * WIDTH + 13,
				]) {
					const bot = {
						id: "bot",
						country_id: 1,
						x: from % WIDTH,
						y: Math.floor(from / WIDTH),
					};
					const expected: number[][] = [];
					let bestCost = Number.POSITIVE_INFINITY;
					let bestCells: number[] = [];
					for (const order of [route, route.toReversed()]) {
						for (const horizontalFirst of [true, false]) {
							const cells = [
								...walk(from, order[0], horizontalFirst),
								...order.slice(1),
							];
							if (loop) cells.push(order[0]);
							else if (from === order[0])
								cells.push(
									...walk(order[order.length - 1], from, horizontalFirst),
								);
							const owners = world.owners.slice();
							let cost = 0,
								current = from;
							for (const next of cells) {
								expected.push([current, next, owners[next]]);
								cost += stepCost(bot.country_id, current, next, owners[next]);
								if (world.land[next]) owners[next] = bot.country_id;
								current = next;
							}
							if (cost < bestCost) {
								bestCost = cost;
								bestCells = cells;
							}
						}
					}
					const actual: number[][] = [];
					world.stepCost = (countryId, current, next, owner) => {
						actual.push([current, next, owner ?? world.owners[next]]);
						return stepCost(countryId, current, next, owner);
					};
					const ownersBefore = world.owners.slice();
					expect(planBot(world, bot, side)).toEqual({
						patch,
						cells: bestCells,
					});
					expect(actual).toEqual(expected);
					expect(world.owners).toEqual(ownersBefore);
				}
			}
		}
	}
	world.owners.fill(1);
	expect(
		planBot(world, { id: "bot", country_id: 1, x: 0, y: 0 }),
	).toBeUndefined();
});

test("roam plans are straight lines that wrap the seam and stop at poles", () => {
	const right = roamPlan({ x: WIDTH - 1, y: 4 }, 9, "right");
	expect(right.patch).toBe(-1);
	expect(right.roam).toBe("seek");
	expect(right.cells).toHaveLength(72);
	expect(right.cells[0]).toBe(4 * WIDTH);
	expect(right.cells.at(-1)).toBe(4 * WIDTH + 71);
	expect(roamPlan({ x: 5, y: 3 }, 9, "up", "flee").roam).toBe("flee");
	const up = roamPlan({ x: 5, y: 3 }, 9, "up");
	expect(up.cells).toEqual([2 * WIDTH + 5, WIDTH + 5, 5]);
	expect(roamPlan({ x: 5, y: 0 }, 9, "up").cells).toHaveLength(0);
	expect(roamPlan({ x: 5, y: HEIGHT - 1 }, 9, "down").cells).toHaveLength(0);
});

test("enemy rays count first foreign land, skip water, and stop at poles", () => {
	const world = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	const bot = { x: 100, y: 100, country_id: 1 };
	world.owners.fill(2);
	expect(enemyRays(world, bot)).toBe(8);
	world.owners[99 * WIDTH + 100] = 1;
	expect(enemyRays(world, bot)).toBe(7);
	world.owners[99 * WIDTH + 100] = 0;
	expect(enemyRays(world, bot)).toBe(7);
	// Water is skipped: the ray keeps looking and finds land beyond it.
	world.land[99 * WIDTH + 100] = 0;
	expect(enemyRays(world, bot)).toBe(8);
	world.owners[98 * WIDTH + 100] = 0;
	expect(enemyRays(world, bot)).toBe(7);
	// Rays crossing the map edge see no land: only 5 directions exist at y=0.
	world.land.fill(1);
	world.owners.fill(2);
	expect(enemyRays(world, { x: 100, y: 0, country_id: 1 })).toBe(5);
	// Reach is bounded, so foreign land past the limit is not seen.
	world.owners.fill(1);
	for (let step = 1; step <= 6; step++)
		world.land[100 * WIDTH + 100 + step] = 0;
	world.owners[100 * WIDTH + 100 + 7] = 2;
	expect(enemyRays(world, bot, 6)).toBe(0);
	expect(enemyRays(world, bot, 7)).toBe(1);
});
