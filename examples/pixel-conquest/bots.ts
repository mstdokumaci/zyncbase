import { type Dot, HEIGHT, WIDTH } from "./shared";
import type { World } from "./world";

export type BotPlan = { patch: number; cells: number[] };
const SIDE = 6;

function approach(from: number, to: number, horizontalFirst: boolean) {
	const cells: number[] = [];
	let x = from % WIDTH,
		y = Math.floor(from / WIDTH);
	const tx = to % WIDTH,
		ty = Math.floor(to / WIDTH);
	for (const horizontal of [horizontalFirst, !horizontalFirst]) {
		while (horizontal ? x !== tx : y !== ty) {
			if (horizontal) x += Math.sign(tx - x);
			else y += Math.sign(ty - y);
			cells.push(y * WIDTH + x);
		}
	}
	return cells;
}

function sweep(left: number, top: number) {
	const cells: number[] = [];
	for (let y = 0; y < SIDE; y++)
		for (let x = 0; x < SIDE; x++)
			cells.push((top + y) * WIDTH + left + (y % 2 ? SIDE - 1 - x : x));
	return cells;
}

function perimeter(left: number, top: number) {
	const cells: number[] = [];
	for (let x = 0; x < SIDE; x++) cells.push(top * WIDTH + left + x);
	for (let y = 1; y < SIDE; y++)
		cells.push((top + y) * WIDTH + left + SIDE - 1);
	for (let x = SIDE - 2; x >= 0; x--)
		cells.push((top + SIDE - 1) * WIDTH + left + x);
	for (let y = SIDE - 2; y > 0; y--) cells.push((top + y) * WIDTH + left);
	return cells;
}

function routeCost(world: World, code: number, from: number, cells: number[]) {
	let cost = 0;
	const painted = new Set<number>();
	for (const to of cells) {
		cost += world.stepCost(
			code,
			from,
			to,
			painted.has(to) ? code : world.owners[to],
		);
		if (world.land[to]) painted.add(to);
		from = to;
	}
	return cost;
}

// ponytail: compare two L-shaped approaches to nearby patches; add pathfinding only if long voyages need it.
// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: bounded candidate search evaluates complete travel-and-sweep plans together.
export function planBot(world: World, bot: Dot): BotPlan | undefined {
	const rival = [...world.countries.values()]
		.filter((country) => country.code !== bot.code)
		.sort((a, b) => b.count - a.count)[0]?.code;
	const reserved = new Set(
		[...world.players.values()]
			.filter((other) => other.id !== bot.id && other.code === bot.code)
			.map((other) => other.plan?.patch),
	);
	const from = bot.y * WIDTH + bot.x;
	let best = 0;
	let plan: BotPlan | undefined;
	for (let dy = -4; dy <= 4; dy++) {
		for (let dx = -4; dx <= 4; dx++) {
			const left = (Math.floor(bot.x / SIDE) + dx) * SIDE;
			const top = (Math.floor(bot.y / SIDE) + dy) * SIDE;
			const patch = top * WIDTH + left;
			if (
				left < 0 ||
				top < 0 ||
				left + SIDE > WIDTH ||
				top + SIDE > HEIGHT ||
				reserved.has(patch)
			)
				continue;
			const area = sweep(left, top);
			const gain = area.reduce(
				(sum, cell) =>
					sum +
					(!world.land[cell] || world.owners[cell] === bot.code
						? 0
						: world.owners[cell] === rival
							? 2
							: 1),
				0,
			);
			if (!gain) continue;
			const edge = perimeter(left, top);
			const loop = edge.every((cell) => world.land[cell]);
			const route = loop ? edge : area;
			for (const order of [route, [...route].reverse()]) {
				for (const horizontalFirst of [true, false]) {
					const cells = [
						...approach(from, order[0], horizontalFirst),
						...order.slice(1),
					];
					if (loop) cells.push(order[0]);
					// A coastal sweep must enter its starting cell too; water cannot close a boundary.
					else if (from === order[0])
						cells.push(
							...approach(order.at(-1) as number, from, horizontalFirst),
						);
					const score = gain / routeCost(world, bot.code, from, cells);
					if (score > best) {
						best = score;
						plan = { patch, cells };
					}
				}
			}
		}
	}
	return plan;
}
