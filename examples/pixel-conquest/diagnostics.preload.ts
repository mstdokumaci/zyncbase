// Diagnostic preload for the existing harness; timings include instrumentation.
import assert from "node:assert/strict";
import { type Bounds, HoleFiller } from "./filler";
import { WIDTH } from "./shared";
import { World } from "./world";

const fill = HoleFiller.prototype.fill;
const tick = World.prototype.tick;
let times: number[] = [];
let areas: number[] = [];
let fillMs = 0;

HoleFiller.prototype.fill = function (owners, code, bounds) {
	areas.push(
		(bounds.right - bounds.left + 1) * (bounds.bottom - bounds.top + 1),
	);
	const started = performance.now();
	const result = fill.call(this, owners, code, bounds);
	fillMs += performance.now() - started;
	return result;
};

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: diagnostic-only snapshot asserts and log formatting surround the wrapped tick.
World.prototype.tick = function (now) {
	if (this.ticks === 0) {
		times = [];
		areas = [];
		fillMs = 0;
	}
	const started = performance.now();
	tick.call(this, now);
	times.push(performance.now() - started);
	if (this.ticks % 1200) return;
	const tight = new Map<number, Bounds>();
	for (let cell = 0; cell < this.owners.length; cell++) {
		const code = this.owners[cell];
		if (!code) continue;
		const x = cell % WIDTH;
		const y = Math.floor(cell / WIDTH);
		const box = tight.get(code);
		if (!box) tight.set(code, { left: x, right: x, top: y, bottom: y });
		else {
			box.left = Math.min(box.left, x);
			box.right = Math.max(box.right, x);
			box.top = Math.min(box.top, y);
			box.bottom = Math.max(box.bottom, y);
		}
	}
	const stored = (this as unknown as { bounds: Map<number, Bounds> }).bounds;
	const countries = (
		this as unknown as { countries: Map<number, { count: number }> }
	).countries;
	const boxes = [...tight].map(([code, box]) => {
		const grown = stored.get(code);
		assert(grown);
		assert(grown.left <= box.left && grown.right >= box.right);
		assert(grown.top <= box.top && grown.bottom >= box.bottom);
		const area = (b: Bounds) => (b.right - b.left + 1) * (b.bottom - b.top + 1);
		return { code, storedArea: area(grown), tightArea: area(box) };
	});
	const surplusZeroCount: number[] = [];
	for (const code of stored.keys()) {
		if (tight.has(code)) continue;
		const count = countries.get(code)?.count ?? 0;
		assert.equal(count, 0);
		surplusZeroCount.push(code);
	}
	times.sort((a, b) => a - b);
	areas.sort((a, b) => a - b);
	console.log(
		"DIAGNOSTIC",
		JSON.stringify({
			tick: this.ticks,
			simulationMs: times.reduce((sum, value) => sum + value, 0),
			p99Ms: times[Math.ceil(times.length * 0.99) - 1],
			fillCalls: areas.length,
			fillMs,
			fillAreaTotal: areas.reduce((sum, value) => sum + value, 0),
			fillAreaP50: areas[Math.floor(areas.length / 2)] ?? 0,
			fillAreaMax: areas.at(-1) ?? 0,
			boxes,
			surplusZeroCount,
		}),
	);
	times = [];
	areas = [];
	fillMs = 0;
};
