import { expect, test } from "bun:test";
import { LocalMotion } from "./motion";
import { type Dot, HEIGHT, RULES, WIDTH } from "./shared";
import { World } from "./world";

const dot: Dot = { id: "me", code: 1, x: 31, y: 10, seq: 1, sentAt: 0 };
const land = new Uint8Array(WIDTH * HEIGHT);

test("a 500 ms crossing animates by elapsed time and waits at one unconfirmed pixel", () => {
	const terrain = land.slice();
	terrain[dot.y * WIDTH + dot.x + 1] = 1;
	const motion = new LocalMotion(dot, "right", 0, terrain, () => 2);
	expect(motion.position(0)).toEqual({ x: 31, y: 10 });
	expect(motion.position(250)).toEqual({ x: 31.5, y: 10 });
	// Echoes/heartbeats at the same cell must not restart the animation.
	motion.update({ ...dot, seq: 2 }, "right", 250);
	expect(motion.position(250).x).toBe(31.5);
	for (const hz of [30, 60, 120, 144]) {
		for (let frame = 0; frame <= hz; frame++) {
			const now = (frame * 1000) / hz;
			expect(motion.position(now).x).toBeCloseTo(31 + Math.min(now / 500, 1));
		}
	}
	expect(motion.position(20000)).toEqual({ x: 32, y: 10 });
	expect(dot.x).toBe(31);
});

test("visual step durations match the server for every terrain and ownership combination", () => {
	const world = new World(land.slice());
	const from = dot.y * WIDTH + dot.x,
		to = from + 1;
	for (const source of [0, 1]) {
		for (const destination of [0, 1]) {
			for (const owner of [0, 1, 2]) {
				world.land[from] = source;
				world.land[to] = destination;
				world.owners[to] = owner;
				const ms = world.stepCost(dot.code, from, to) * RULES.tickMs;
				const motion = new LocalMotion(
					dot,
					"right",
					0,
					world.land,
					() => owner,
				);
				expect(motion.position(ms / 2)).toEqual({ x: 31.5, y: 10 });
				expect(motion.position(ms)).toEqual({ x: 32, y: 10 });
			}
		}
	}
});

test("destination ownership changes retime an active step without jumps or heartbeat resets", () => {
	const terrain = land.slice().fill(1);
	let owner = 2;
	const motion = new LocalMotion(dot, "right", 0, terrain, () => owner);
	expect(motion.position(50).x).toBe(31.25);
	owner = 1;
	motion.update(dot, "right", 50);
	expect(motion.position(50).x).toBe(31.25);
	expect(motion.position(75).x).toBe(31.625);
	motion.update({ ...dot, seq: 2 }, "right", 75);
	expect(motion.position(75).x).toBe(31.625);
	expect(motion.position(100).x).toBe(32);
	expect(motion.position(1000).x).toBe(32);

	const slower = new LocalMotion(dot, "right", 0, terrain, () => owner);
	expect(slower.position(25).x).toBe(31.5);
	owner = 2;
	slower.update(dot, "right", 25);
	expect(slower.position(25).x).toBe(31.5);
	expect(slower.position(125).x).toBe(31.5);
	owner = 3; // A different enemy has the same cost and must not restart timing.
	slower.update(dot, "right", 125);
	expect(slower.position(175).x).toBe(31.75);
	expect(slower.position(225).x).toBe(32);
});

test("confirmations, stops, reversals and respawns reconcile the visible position", () => {
	const motion = new LocalMotion(dot, "right", 0, land, () => 0);
	expect(motion.position(100).x).toBe(32);
	// A delayed confirmation starts the next step without jumping.
	motion.update({ ...dot, x: 32 }, "right", 400);
	expect(motion.position(400).x).toBe(32);
	expect(motion.position(450).x).toBe(32.5);
	motion.update(motion.dot, "idle", 450);
	expect(motion.position(450).x).toBe(32.5);
	expect(motion.position(500).x).toBe(32.25);
	expect(motion.position(550).x).toBe(32);
	motion.update(motion.dot, "left", 550);
	expect(motion.position(600).x).toBe(31.5);
	motion.update(motion.dot, "right", 600);
	expect(motion.position(600).x).toBe(31.5);
	expect(motion.position(700).x).toBe(33);
	// An unexpected server cell eases from the currently displayed point.
	motion.update({ ...dot, x: 32, y: 11 }, "idle", 700);
	expect(motion.position(700)).toEqual({ x: 33, y: 10 });
	expect(motion.position(750)).toEqual({ x: 32.5, y: 10.5 });
	expect(motion.position(800)).toEqual({ x: 32, y: 11 });
	motion.update({ ...dot, x: 1000, y: 300 }, "idle", 800);
	expect(motion.position(800)).toEqual({ x: 1000, y: 300 });
});

test("anticipation respects map edges and waits for unknown destination chunks", () => {
	for (const [x, y, direction] of [
		[0, 10, "left"],
		[WIDTH - 1, 10, "right"],
		[10, 0, "up"],
		[10, HEIGHT - 1, "down"],
	] as const) {
		const motion = new LocalMotion(
			{ ...dot, x, y },
			direction,
			0,
			land,
			() => 0,
		);
		expect(motion.position(1000)).toEqual({ x, y });
	}
	const unknown = new LocalMotion(dot, "right", 0, land, () => undefined);
	expect(unknown.position(1000)).toEqual({ x: 31, y: 10 });
});
