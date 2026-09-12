import { expect, test } from "bun:test";
import { planBot } from "./bots";
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
test("bot scoring matches executed routes, including revisits, coastal returns and ties", () => {
	const world = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	const stepCost = world.stepCost.bind(world);
	for (const patch of [0, 54 * WIDTH + 54, 981 * WIDTH + 1980]) {
		const area = Array.from({ length: 81 }, (_, i) => {
			const row = Math.floor(i / 9);
			return patch + row * WIDTH + (row % 2 ? 8 - (i % 9) : i % 9);
		});
		const edge = [
			0,
			1,
			2,
			3,
			4,
			5,
			6,
			7,
			8,
			WIDTH + 8,
			2 * WIDTH + 8,
			3 * WIDTH + 8,
			4 * WIDTH + 8,
			5 * WIDTH + 8,
			6 * WIDTH + 8,
			7 * WIDTH + 8,
			8 * WIDTH + 8,
			8 * WIDTH + 7,
			8 * WIDTH + 6,
			8 * WIDTH + 5,
			8 * WIDTH + 4,
			8 * WIDTH + 3,
			8 * WIDTH + 2,
			8 * WIDTH + 1,
			8 * WIDTH,
			7 * WIDTH,
			6 * WIDTH,
			5 * WIDTH,
			4 * WIDTH,
			3 * WIDTH,
			2 * WIDTH,
			WIDTH,
		].map((offset) => patch + offset);
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
				world.stepCost = (code, current, next, owner) => {
					actual.push([current, next, owner ?? world.owners[next]]);
					return stepCost(code, current, next, owner);
				};
				const ownersBefore = world.owners.slice();
				expect(planBot(world, bot)).toEqual({ patch, cells: bestCells });
				expect(actual).toEqual(expected);
				expect(world.owners).toEqual(ownersBefore);
			}
		}
	}
	world.owners.fill(1);
	expect(
		planBot(world, { id: "bot", country_id: 1, x: 0, y: 0 }),
	).toBeUndefined();
});
