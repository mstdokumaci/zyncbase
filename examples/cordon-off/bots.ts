import { type Direction, HEIGHT, WIDTH, wrapX } from "./shared";
import type { World } from "./world";

export type BotPlan = {
	patch: number;
	cells: number[];
	// "seek": walk out of own territory to claimable land (window has no gain).
	// "flee": walk out of enemy territory to safe land (bot was surrounded).
	roam?: "seek" | "flee";
};
const SIDE = 9;
// Per-plan square sizes, weighted toward the small end so the planner's
// average patch area stays below the old uniform 9x9.
export const BOT_SIDES = [5, 7, 5, 7, 9, 11, 9];
const MAX_SIDE = 11;

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

const areaScratch: number[] = new Array(MAX_SIDE * MAX_SIDE);
const edgeScratch: number[] = new Array(MAX_SIDE * 4 - 4);
// Cells the candidate plan would paint, tracked per scoring. A generation
// stamp avoids both Set hashing and clearing: each scoring gets a fresh token.
const paintedFlags = new Uint32Array(WIDTH * HEIGHT);
let paintedToken = 0;
function beginScoring() {
	paintedToken = (paintedToken + 1) >>> 0;
	if (paintedToken === 0) {
		paintedFlags.fill(0);
		paintedToken = 1;
	}
	return paintedToken;
}
// Length is reset to the requested side on every call; callers fill every
// entry before scoring, so a later larger patch overwrites the stale tail.
function fillPerimeter(
	cells: number[],
	left: number,
	top: number,
	side: number,
) {
	let i = 0;
	for (let x = 0; x < side; x++) cells[i++] = top * WIDTH + left + x;
	for (let y = 1; y < side; y++)
		cells[i++] = (top + y) * WIDTH + left + side - 1;
	for (let x = side - 2; x >= 0; x--)
		cells[i++] = (top + side - 1) * WIDTH + left + x;
	for (let y = side - 2; y > 0; y--) cells[i++] = (top + y) * WIDTH + left;
	cells.length = i;
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

function isAllLand(world: World, left: number, top: number, side: number) {
	return (
		segmentAllLand(world, top * WIDTH + left, 1, side) &&
		segmentAllLand(
			world,
			(top + 1) * WIDTH + left + side - 1,
			WIDTH,
			side - 1,
		) &&
		segmentAllLand(world, (top + side - 1) * WIDTH + left, 1, side) &&
		segmentAllLand(world, (top + 1) * WIDTH + left, WIDTH, side - 1)
	);
}

// Scores the same cell sequence planBot used to build (approach, sweep,
// optional loop closure or coastal return) without building per-candidate
// cell arrays; only the winner is materialized.
// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: the step body is written out at the three walk sites so cost/cur stay in locals.
function scoreCells(
	world: World,
	countryId: number,
	from: number,
	route: number[],
	reverse: boolean,
	horizontalFirst: boolean,
	loop: boolean,
) {
	const painted = beginScoring();
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
	for (let pass = 0; pass < 2; pass++) {
		const horizontal = pass === 0 ? horizontalFirst : !horizontalFirst;
		while (horizontal ? x !== tx : y !== ty) {
			if (horizontal) x += tx > x ? 1 : -1;
			else y += ty > y ? 1 : -1;
			const next = y * WIDTH + x;
			const owner = paintedFlags[next] === painted ? countryId : owners[next];
			cost += world.stepCost(countryId, cur, next, owner);
			if (land[next]) paintedFlags[next] = painted;
			cur = next;
		}
	}
	for (let k = 1; k < route.length; k++) {
		const next = reverse ? route[last - k] : route[k];
		const owner = paintedFlags[next] === painted ? countryId : owners[next];
		cost += world.stepCost(countryId, cur, next, owner);
		if (land[next]) paintedFlags[next] = painted;
		cur = next;
	}
	if (loop) {
		const owner = paintedFlags[entry] === painted ? countryId : owners[entry];
		cost += world.stepCost(countryId, cur, entry, owner);
	} else if (from === entry) {
		const exit = reverse ? route[0] : route[last];
		let rx = exit % WIDTH,
			ry = Math.floor(exit / WIDTH);
		const fx = from % WIDTH,
			fy = Math.floor(from / WIDTH);
		for (let pass = 0; pass < 2; pass++) {
			const horizontal = pass === 0 ? horizontalFirst : !horizontalFirst;
			while (horizontal ? rx !== fx : ry !== fy) {
				if (horizontal) rx += fx > rx ? 1 : -1;
				else ry += fy > ry ? 1 : -1;
				const next = ry * WIDTH + rx;
				const owner = paintedFlags[next] === painted ? countryId : owners[next];
				cost += world.stepCost(countryId, cur, next, owner);
				if (land[next]) paintedFlags[next] = painted;
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
	side = SIDE,
): BotPlan | undefined {
	const rival = [...world.countries.values()]
		.filter((country) => country.country_id !== bot.country_id)
		.sort((a, b) => b.count - a.count)[0]?.country_id;
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
			const left = (Math.floor(bot.x / side) + dx) * side;
			const top = (Math.floor(bot.y / side) + dy) * side;
			const patch = top * WIDTH + left;
			if (
				left < 0 ||
				top < 0 ||
				left + side > WIDTH ||
				top + side > HEIGHT ||
				reserved.has(patch)
			)
				continue;
			let gain = 0;
			let i = 0;
			for (let y = 0; y < side; y++) {
				for (let x = 0; x < side; x++) {
					const cell = (top + y) * WIDTH + left + (y % 2 ? side - 1 - x : x);
					areaScratch[i++] = cell;
					if (!world.land[cell] || world.owners[cell] === bot.country_id)
						continue;
					gain += world.owners[cell] === rival ? 2 : 1;
				}
			}
			if (!gain) continue;
			areaScratch.length = i;
			const loop = isAllLand(world, left, top, side);
			const route = loop
				? fillPerimeter(edgeScratch, left, top, side)
				: areaScratch;
			for (let r = 0; r < 2; r++) {
				const reverse = r === 1;
				const entry = reverse ? (route.at(-1) as number) : route[0];
				const lowerBound =
					Math.abs((entry % WIDTH) - bot.x) +
					Math.abs(Math.floor(entry / WIDTH) - bot.y) +
					route.length -
					1 +
					(loop ? 1 : 0);
				for (let h = 0; h < 2; h++) {
					const horizontalFirst = h === 0;
					if (bestGain && gain * bestCost <= bestGain * lowerBound) continue;
					const cost = scoreCells(
						world,
						bot.country_id,
						from,
						route,
						reverse,
						horizontalFirst,
						loop,
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

// Escape line: walk straight until steerBot sees the roam's goal ahead, then
// the normal planner takes over. `patch` stays a plan shape (never a real
// patch origin).
const ROAM_STEPS: Record<Exclude<Direction, "idle">, [number, number]> = {
	up: [0, -1],
	down: [0, 1],
	left: [-1, 0],
	right: [1, 0],
};

export function roamPlan(
	bot: { x: number; y: number },
	side: number,
	direction: Exclude<Direction, "idle">,
	mode: "seek" | "flee" = "seek",
): BotPlan {
	const [dx, dy] = ROAM_STEPS[direction];
	const cells: number[] = [];
	let y = bot.y;
	let x = bot.x;
	for (let i = 0; i < side * 8; i++) {
		y += dy;
		if (y < 0 || y >= HEIGHT) break;
		x = wrapX(x + dx);
		cells.push(y * WIDTH + x);
	}
	return { patch: -1, roam: mode, cells };
}

const RAYS: [number, number][] = [
	[1, 0],
	[-1, 0],
	[0, 1],
	[0, -1],
	[1, 1],
	[1, -1],
	[-1, 1],
	[-1, -1],
];

function rayHitsEnemy(
	world: World,
	bot: { x: number; y: number; country_id: number },
	dx: number,
	dy: number,
	reach: number,
) {
	for (let step = 1; step <= reach; step++) {
		const y = bot.y + dy * step;
		if (y < 0 || y >= HEIGHT) return false;
		const cell = y * WIDTH + wrapX(bot.x + dx * step);
		if (!world.land[cell]) continue;
		const owner = world.owners[cell];
		return owner !== 0 && owner !== bot.country_id;
	}
	return false;
}

// How many of the eight compass rays hit foreign-owned land first, skipping
// water and stopping at poles. Seven or eight means the bot is boxed into
// enemy territory and should run rather than paint a square there.
export function enemyRays(
	world: World,
	bot: { x: number; y: number; country_id: number },
	reach = 6,
) {
	let enemy = 0;
	for (const [dx, dy] of RAYS)
		if (rayHitsEnemy(world, bot, dx, dy, reach)) enemy++;
	return enemy;
}
