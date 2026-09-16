// Profiling only: collect real server tick timing without changing production code.
import { writeFileSync } from "node:fs";
import { ZyncBaseClient } from "@zyncbase/client";
import { World } from "./world";

const ticks: { at: number; ms: number }[] = [];
const commits: { at: number; ms: number; operations: number }[] = [];
const resources: { at: number; user: number; system: number; rss: number }[] =
	[];
const tick = World.prototype.tick;
World.prototype.tick = function (now) {
	const started = performance.now();
	tick.call(this, now);
	ticks.push({ at: Date.now(), ms: performance.now() - started });
};
// Automatic reconnects run through ConnectionManager.connect(), but an
// explicit second connect() would wrap store.batch a second time and record
// every commit twice; keep the wrapper per store.
const wrapped = new WeakSet<object>();
const connect = ZyncBaseClient.prototype.connect;
ZyncBaseClient.prototype.connect = async function () {
	if (wrapped.has(this.store)) return connect.call(this);
	wrapped.add(this.store);
	const batch = this.store.batch.bind(this.store);
	this.store.batch = async (operations, options) => {
		const started = performance.now();
		const result = await batch(operations, options);
		commits.push({
			at: Date.now(),
			ms: performance.now() - started,
			operations: operations.length,
		});
		return result;
	};
	return connect.call(this);
};
const sample = () =>
	resources.push({
		at: Date.now(),
		...process.cpuUsage(),
		rss: process.memoryUsage.rss(),
	});
sample();
setInterval(sample, 1000).unref();
process.on("exit", () => {
	sample();
	writeFileSync(
		process.env.GAME_PROFILE_OUTPUT as string,
		JSON.stringify({ ticks, commits, resources }),
	);
});
