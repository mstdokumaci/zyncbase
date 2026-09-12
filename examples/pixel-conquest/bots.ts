import { HEIGHT, WIDTH } from "./shared";
import type { World } from "./world";

export type BotPlan = { patch: number; cells: number[] };
const SIDE = 9;

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

const AREA_CELLS = SIDE * SIDE;
const EDGE_CELLS = SIDE * 4 - 4;
const areaScratch: number[] = new Array(AREA_CELLS);
const edgeScratch: number[] = new Array(EDGE_CELLS);
function fillPerimeter(cells: number[], left: number, top: number) {
	let i = 0;
	for (let x = 0; x < SIDE; x++) cells[i++] = top * WIDTH + left + x;
	for (let y = 1; y < SIDE; y++)
		cells[i++] = (top + y) * WIDTH + left + SIDE - 1;
	for (let x = SIDE - 2; x >= 0; x--)
		cells[i++] = (top + SIDE - 1) * WIDTH + left + x;
	for (let y = SIDE - 2; y > 0; y--) cells[i++] = (top + y) * WIDTH + left;
	return cells;
}

function segmentAllLand(
	world: World,
	start: number,
	step: number,
	count: number,
) {
	for (let i = 0, cell = start; i < count; i++, cell += step)
		if (!world.land[cell]) return false;
	return true;
}

function isAllLand(world: World, left: number, top: number) {
	return (
		segmentAllLand(world, top * WIDTH + left, 1, SIDE) &&
		segmentAllLand(
			world,
			(top + 1) * WIDTH + left + SIDE - 1,
			WIDTH,
			SIDE - 1,
		) &&
		segmentAllLand(world, (top + SIDE - 1) * WIDTH + left, 1, SIDE) &&
		segmentAllLand(world, (top + 1) * WIDTH + left, WIDTH, SIDE - 1)
	);
}

// Scores the same cell sequence planBot used to build (approach, sweep,
// optional loop closure or coastal return) without building per-candidate
// cell arrays; only the winner is materialized.
// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: the step body is written out at the three walk sites so cost/cur stay in locals.
function scoreCells(
	world: World,
	code: number,
	from: number,
	route: number[],
	reverse: boolean,
	horizontalFirst: boolean,
	loop: boolean,
	painted: Set<number>,
) {
	const owners = world.owners,
		land = world.land;
	let cost = 0;
	let cur = from;
	const last = route.length - 1;
	const entry = reverse ? route[last] : route[0];
	// Same two-phase L walk as approach(), scored inline without allocating.
	// The step body is written out at each site: a closure would put cost/cur
	// in context-allocated storage and cost more than the arrays it replaces.
	let x = cur % WIDTH,
		y = Math.floor(cur / WIDTH);
	const tx = entry % WIDTH,
		ty = Math.floor(entry / WIDTH);
	for (const horizontal of [horizontalFirst, !horizontalFirst]) {
		while (horizontal ? x !== tx : y !== ty) {
			if (horizontal) x += Math.sign(tx - x);
			else y += Math.sign(ty - y);
			const next = y * WIDTH + x;
			cost += world.stepCost(
				code,
				cur,
				next,
				painted.has(next) ? code : owners[next],
			);
			if (land[next]) painted.add(next);
			cur = next;
		}
	}
	for (let k = 1; k < route.length; k++) {
		const next = reverse ? route[last - k] : route[k];
		cost += world.stepCost(
			code,
			cur,
			next,
			painted.has(next) ? code : owners[next],
		);
		if (land[next]) painted.add(next);
		cur = next;
	}
	if (loop) {
		cost += world.stepCost(
			code,
			cur,
			entry,
			painted.has(entry) ? code : owners[entry],
		);
	} else if (from === entry) {
		const exit = reverse ? route[0] : route[last];
		let rx = exit % WIDTH,
			ry = Math.floor(exit / WIDTH);
		const fx = from % WIDTH,
			fy = Math.floor(from / WIDTH);
		for (const horizontal of [horizontalFirst, !horizontalFirst]) {
			while (horizontal ? rx !== fx : ry !== fy) {
				if (horizontal) rx += Math.sign(fx - rx);
				else ry += Math.sign(fy - ry);
				const next = ry * WIDTH + rx;
				cost += world.stepCost(
					code,
					cur,
					next,
					painted.has(next) ? code : owners[next],
				);
				if (land[next]) painted.add(next);
				cur = next;
			}
		}
	}
	return cost;
}

// compare two L-shaped approaches to nearby patches; add pathfinding only if long voyages need it.
// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: bounded candidate search evaluates complete travel-and-sweep plans together.
export function planBot(
	world: World,
	bot: { id: string; x: number; y: number; country_id: number },
): BotPlan | undefined {
	const rival = [...world.countries.values()]
		.filter((country) => country.code !== bot.country_id)
		.sort((a, b) => b.count - a.count)[0]?.code;
	const reserved = new Set(
		[...world.players.values()]
			.filter(
				(other) => other.id !== bot.id && other.country_id === bot.country_id,
			)
			.map((other) => other.plan?.patch),
	);
	const from = bot.y * WIDTH + bot.x;
	let bestGain = 0;
	let bestCost = 1;
	let bestPatch = 0,
		bestRoute: number[] | undefined,
		bestReverse = false,
		bestHorizontalFirst = true,
		bestLoop = false;
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
			let gain = 0;
			let i = 0;
			for (let y = 0; y < SIDE; y++) {
				for (let x = 0; x < SIDE; x++) {
					const cell = (top + y) * WIDTH + left + (y % 2 ? SIDE - 1 - x : x);
					areaScratch[i++] = cell;
					if (!world.land[cell] || world.owners[cell] === bot.country_id)
						continue;
					gain += world.owners[cell] === rival ? 2 : 1;
				}
			}
			if (!gain) continue;
			const loop = isAllLand(world, left, top);
			const route = loop ? fillPerimeter(edgeScratch, left, top) : areaScratch;
			for (const reverse of [false, true]) {
				const entry = reverse ? (route.at(-1) as number) : route[0];
				const lowerBound =
					Math.abs((entry % WIDTH) - bot.x) +
					Math.abs(Math.floor(entry / WIDTH) - bot.y) +
					route.length -
					1 +
					(loop ? 1 : 0);
				for (const horizontalFirst of [true, false]) {
					if (bestGain && gain * bestCost <= bestGain * lowerBound) continue;
					const cost = scoreCells(
						world,
						bot.country_id,
						from,
						route,
						reverse,
						horizontalFirst,
						loop,
						new Set<number>(),
					);
					if (gain * bestCost > bestGain * cost) {
						bestGain = gain;
						bestCost = cost;
						bestPatch = patch;
						bestRoute = route.slice();
						bestReverse = reverse;
						bestHorizontalFirst = horizontalFirst;
						bestLoop = loop;
					}
				}
			}
		}
	}
	if (!bestRoute) return;
	// Materialize the winner exactly as before; only one cells array per think.
	const order = bestReverse ? [...bestRoute].reverse() : bestRoute;
	const cells = [
		...approach(from, order[0], bestHorizontalFirst),
		...order.slice(1),
	];
	if (bestLoop) cells.push(order[0]);
	// A coastal sweep must enter its starting cell too; water cannot close a boundary.
	else if (from === order[0])
		cells.push(...approach(order.at(-1) as number, from, bestHorizontalFirst));
	return { patch: bestPatch, cells };
}
