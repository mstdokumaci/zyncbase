// Real browser + SDK peers using normal admission, subscriptions and presence.
// Run against isolated local data, or an explicitly supplied dedicated test URL.
import assert from "node:assert/strict";
import { realpathSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import { createRequire } from "node:module";
import { cpus } from "node:os";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { buildBrowser } from "./build";
import { startLocalEdge } from "./dev";
import { type Country, MAX_PLAYERS } from "./shared";

const { values } = parseArgs({
	options: {
		players: { type: "string", default: "1,32,128,256,512,1024" },
		seconds: { type: "string", default: "30" },
		countries: { type: "string", default: "32" },
		zoom: { type: "string", default: "8" },
		cpu: { type: "string", default: "1" },
		width: { type: "string", default: "1440" },
		height: { type: "string", default: "900" },
		dpr: { type: "string", default: "1" },
		channel: { type: "string", default: "msedge" },
		headed: { type: "boolean", default: false },
		profile: { type: "boolean", default: false },
		url: { type: "string" },
		port: { type: "string", default: "18080" },
		output: {
			type: "string",
			default: `test-artifacts/pixel-conquest-profile/browser-${Date.now()}`,
		},
	},
});
const stages = values.players.split(",").map(Number);
assert(
	stages.every(
		(n, i) =>
			Number.isInteger(n) &&
			n >= 1 &&
			n <= MAX_PLAYERS &&
			(!i || n > stages[i - 1]),
	),
);
const seconds = Number(values.seconds);
const countryCount = Number(values.countries);
const zoom = Number(values.zoom);
const width = Number(values.width);
const height = Number(values.height);
const cpu = Number(values.cpu);
const dpr = Number(values.dpr);
assert(seconds >= 5 && seconds <= 600);
assert(
	Number.isInteger(countryCount) && countryCount >= 1 && countryCount <= 54,
);
assert([2, 4, 6, 8, 10, 12, 14, 16].includes(zoom));
assert(width > 0 && height > 0 && cpu >= 1 && dpr > 0);
const output = resolve(values.output);
await mkdir(output, { recursive: true });
const port = Number(values.port);
const url = values.url ?? `http://localhost:${port}`;
const wsUrl = new URL("/ws", url);
wsUrl.protocol = wsUrl.protocol === "https:" ? "wss:" : "ws:";
// Production sends /ws and /auth/ticket straight to ZyncBase; only /session,
// /health and assets go through the Bun origin. SDK peers follow that path
// when this run owns the server, so the development edge proxy is not in the
// measured data path (and cannot become the bottleneck at 1024 connections).
const peerUrl = values.url ? wsUrl.toString() : `ws://127.0.0.1:${port + 2}/ws`;
// Reuse the installed CLI's package when Playwright is installed globally.
const require = createRequire(
	realpathSync(Bun.which("playwright") ?? import.meta.path),
);
const { chromium } = require("playwright");
type PeerStats = {
	lateDeltas: number;
	callbacks: number;
	heartbeatLag: number[];
	errors: string[];
	subscriptions: number;
	movingPeers: number;
	positioned: number;
	failure?: string;
};
const workers: Worker[] = [];
// Each worker handles one command at a time; parallel calls use distinct workers.
function command(worker: Worker, data: Record<string, unknown>) {
	return new Promise<PeerStats>((resolve, reject) => {
		const timer = setTimeout(
			() => reject(new Error("Peer worker timed out")),
			30000,
		);
		worker.onmessage = ({ data }: MessageEvent<PeerStats>) => {
			clearTimeout(timer);
			if (data.failure) reject(new Error(data.failure));
			else resolve(data);
		};
		worker.onerror = (event) => {
			clearTimeout(timer);
			reject(new Error(event.message));
		};
		worker.postMessage(data);
	});
}
const broadcast = (data: Record<string, unknown>) =>
	Promise.all(workers.map((worker) => command(worker, data)));
const errors: string[] = [];
const results: Record<string, unknown>[] = [];
let server: ReturnType<typeof Bun.spawn> | undefined;
let closeEdge: (() => Promise<void>) | undefined;
let admitted = 1;
let browser: Awaited<ReturnType<typeof chromium.launch>>;
const summary = (samples: number[]) => {
	const sorted = samples.toSorted((a, b) => a - b);
	const at = (p: number) =>
		sorted[Math.max(0, Math.ceil(p * sorted.length) - 1)] ?? 0;
	return {
		count: sorted.length,
		p50: at(0.5),
		p95: at(0.95),
		p99: at(0.99),
		max: sorted.at(-1) ?? 0,
		total: samples.reduce((a, b) => a + b, 0),
	};
};
async function health() {
	const response = await fetch(new URL("/health", url), {
		signal: AbortSignal.timeout(5000),
	});
	assert(response.ok, `Health failed: ${response.status}`);
	return response.json() as Promise<{
		ready: boolean;
		players: number;
		bots: number;
		countries: Country[];
	}>;
}
function processSnapshot() {
	if (!server) return [];
	const ps = Bun.spawnSync(["ps", "-ax", "-o", "pid=,ppid=,time=,rss="]);
	assert.equal(ps.exitCode, 0);
	return ps.stdout
		.toString()
		.trim()
		.split("\n")
		.flatMap((line) => {
			const [pid, parent, time, rss] = line.trim().split(/\s+/);
			if (Number(pid) !== server?.pid && Number(parent) !== server?.pid)
				return [];
			return [
				{
					pid: Number(pid),
					role: Number(pid) === server?.pid ? "bun" : "database",
					cpuSeconds: time
						.split(":")
						.reduce((n, part) => n * 60 + Number(part), 0),
					rssKiB: Number(rss),
				},
			];
		});
}
async function until(
	check: () => Promise<boolean>,
	label: string,
	timeout = 30000,
) {
	const deadline = performance.now() + timeout;
	while (!(await check())) {
		assert(performance.now() < deadline, `Timed out: ${label}`);
		await Bun.sleep(100);
	}
}

async function addPeer(codes: number[]) {
	// The server we spawn below lifts its session budget for the ramp; an
	// external --url keeps the real 120 sessions/minute budget.
	await Bun.sleep(values.url ? 550 : 20);
	const creating = codes.length < countryCount;
	const response = await fetch(new URL("/session", url), {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify(
			creating ? { countryName: `Profile ${codes.length + 1}` } : {},
		),
	});
	assert(response.ok, `Session ${admitted + 1} failed: ${response.status}`);
	const session = (await response.json()) as {
		token: string;
		countryCode?: number;
	};
	if (creating) {
		assert(session.countryCode);
		codes.push(session.countryCode);
	}
	const countryCode = creating
		? (codes.at(-1) as number)
		: codes[admitted % codes.length];
	const shard = Math.floor((admitted - 1) / 64);
	if (!workers[shard])
		workers.push(
			new Worker(new URL("./profile-peers.ts", import.meta.url).href),
		);
	await command(workers[shard], {
		type: "add",
		index: admitted,
		url: peerUrl,
		token: session.token,
		countryCode,
		width,
		height,
		zoom,
	});
	admitted++;
}

try {
	if (!values.url) {
		const assets = await buildBrowser(join(output, "assets"));
		if (values.profile) {
			const bundle = await Bun.build({
				entrypoints: [join(import.meta.dir, "client.ts")],
				outdir: assets,
				target: "browser",
				minify: { syntax: true, whitespace: true, identifiers: false },
			});
			assert(bundle.success);
		}
		server = Bun.spawn(
			[
				process.execPath,
				"--preload",
				join(import.meta.dir, "profile-live.preload.ts"),
				join(import.meta.dir, "server.ts"),
			],
			{
				env: {
					...process.env,
					GAME_ORIGIN: url,
					GAME_PORT: String(port + 1),
					GAME_DB_PORT: String(port + 2),
					GAME_DATA_DIR: join(output, "data"),
					GAME_PROFILE_OUTPUT: join(output, "server.json"),
					// Profiling ramp: admit quickly instead of pacing 1024
					// sessions over ten minutes at the public demo budget.
					GAME_SESSION_BUDGET: "100000",
				},
				stdout: Bun.file(join(output, "server.log")),
				stderr: Bun.file(join(output, "server-errors.log")),
			},
		);
		closeEdge = await startLocalEdge({
			port,
			authPort: port + 1,
			databasePort: port + 2,
			assets,
		});
	}
	await until(async () => {
		try {
			return (await health()).ready;
		} catch {
			return false;
		}
	}, "server ready");
	browser = await chromium.launch({
		channel: values.channel,
		headless: !values.headed,
	});
	const context = await browser.newContext({
		viewport: { width, height },
		deviceScaleFactor: dpr,
	});
	const page = await context.newPage();
	page.on("pageerror", (error: Error) => errors.push(error.message));
	// Observe actual painted frames, not just the 60 Hz animation callbacks.
	await page.addInitScript(`(() => {
		const data = window.__gamePerf = { frames: [], draws: [], longTasks: [], canvases: 0, labels: 0, scoreboard: 0 };
		let frame = 0, previous = 0;
		const image = CanvasRenderingContext2D.prototype.drawImage;
		CanvasRenderingContext2D.prototype.drawImage = function(...args) {
			if (this.canvas.id === 'map' && args[0].width === 2000) { frame++; const now = performance.now(); if (previous) data.frames.push(now - previous); previous = now; }
			return image.apply(this, args);
		};
		const text = CanvasRenderingContext2D.prototype.fillText;
		CanvasRenderingContext2D.prototype.fillText = function(...args) { data.labels++; return text.apply(this, args); };
		const create = Document.prototype.createElement;
		Document.prototype.createElement = function(...args) { if (args[0] === 'canvas') data.canvases++; return create.apply(this, args); };
		const raf = window.requestAnimationFrame;
		window.requestAnimationFrame = callback => raf.call(window, now => { const before = frame, start = performance.now(); callback(now); if (frame > before) data.draws.push(performance.now() - start); });
		new PerformanceObserver(list => data.longTasks.push(...list.getEntries().map(e => e.duration))).observe({ type: 'longtask', buffered: true });
		addEventListener('DOMContentLoaded', () => new MutationObserver(() => data.scoreboard++).observe(document.getElementById('countries'), { childList: true }));
		window.__resetGamePerf = () => { data.frames = []; data.draws = []; data.longTasks = []; data.canvases = data.labels = data.scoreboard = 0; previous = 0; };
	})()`);
	const cdp = await context.newCDPSession(page);
	await cdp.send("Performance.enable");
	await cdp.send("Network.enable");
	await cdp.send("Emulation.setCPUThrottlingRate", { rate: cpu });
	let rxBytes = 0,
		rxFrames = 0;
	cdp.on(
		"Network.webSocketFrameReceived",
		({ response }: { response: { opcode: number; payloadData: string } }) => {
			rxFrames++;
			rxBytes +=
				response.opcode === 2
					? Buffer.byteLength(response.payloadData, "base64")
					: Buffer.byteLength(response.payloadData);
		},
	);
	const navigationStart = performance.now();
	await page.goto(url);
	await page.locator("#country-choice").waitFor();
	await page.waitForFunction(
		() =>
			!(document.querySelector("#country-choice") as HTMLSelectElement)
				.disabled,
	);
	await page.locator("#country-choice").selectOption("new");
	await page.locator("#country").fill("Profile 1");
	await page.locator("#player-name").fill("Observer");
	const joinStart = performance.now();
	await page.locator("#join-button").click();
	await page.waitForFunction(() =>
		document.getElementById("connection")?.textContent?.startsWith("Live"),
	);
	const startup = {
		navigationToLiveMs: performance.now() - navigationStart,
		joinToLiveMs: performance.now() - joinStart,
	};
	for (let current = 8; current !== zoom; current += zoom > 8 ? 2 : -2)
		await page.locator(zoom > 8 ? "#zoom-in" : "#zoom-out").click();
	const codes = [
		(await health()).countries.find((row) => row.name === "Profile 1")?.code,
	];
	assert(codes[0]);

	for (const target of stages) {
		console.log(`Ramping to ${target} players`);
		while (admitted < target) {
			await addPeer(codes as number[]);
			if (admitted % 100 === 0) console.log(`Admitted ${admitted}/${target}`);
		}
		await until(
			async () => (await health()).players === target,
			`${target} admitted players`,
		);
		await broadcast({ type: "move", moving: true });
		await page.keyboard.down("ArrowRight");
		await Bun.sleep(5000);
		console.log(`Measuring ${target} players for ${seconds}s`);
		const before = await cdp.send("Performance.getMetrics");
		const serverBefore = processSnapshot();
		const driverBefore = process.cpuUsage();
		if (values.profile) {
			await cdp.send("Profiler.enable");
			await cdp.send("Profiler.start");
		}
		rxBytes = rxFrames = 0;
		await broadcast({ type: "reset" });
		await page.evaluate("window.__resetGamePerf()");
		const started = Date.now();
		for (let elapsed = 0; elapsed < seconds; elapsed += 2) {
			await Bun.sleep(Math.min(2, seconds - elapsed) * 1000);
			await page.keyboard.up(
				["ArrowRight", "ArrowDown", "ArrowLeft", "ArrowUp"][
					Math.floor(elapsed / 2) % 4
				],
			);
			await page.keyboard.down(
				["ArrowRight", "ArrowDown", "ArrowLeft", "ArrowUp"][
					(Math.floor(elapsed / 2) + 1) % 4
				],
			);
		}
		const perf = (await page.evaluate("window.__gamePerf")) as {
			frames: number[];
			draws: number[];
			longTasks: number[];
			canvases: number;
			labels: number;
			scoreboard: number;
		};
		const ended = Date.now();
		const peerStats = await broadcast({ type: "stats" });
		const peerErrors = peerStats.flatMap((s) => s.errors);
		const serverAfter = processSnapshot();
		const after = await cdp.send("Performance.getMetrics");
		if (values.profile) {
			const { profile } = await cdp.send("Profiler.stop");
			await Bun.write(
				join(output, `browser-${target}.cpuprofile`),
				JSON.stringify(profile),
			);
		}
		const metrics = (data: { metrics: { name: string; value: number }[] }) =>
			Object.fromEntries(data.metrics.map(({ name, value }) => [name, value]));
		const a = metrics(before),
			b = metrics(after);
		const driverCpu = process.cpuUsage(driverBefore);
		const state = await health();
		const result = {
			target,
			started,
			ended,
			elapsedMs: ended - started,
			state,
			startup,
			fps: perf.draws.length / ((ended - started) / 1000),
			frameMs: summary(perf.frames),
			drawMs: summary(perf.draws),
			framesOver50Ms: perf.frames.filter((n) => n > 50).length,
			longTasks: summary(perf.longTasks),
			canvases: perf.canvases,
			labels: perf.labels,
			scoreboardUpdates: perf.scoreboard,
			rxBytes,
			rxFrames,
			callbacks: peerStats.reduce((n, s) => n + s.callbacks, 0),
			browser: {
				taskMs: (b.TaskDuration - a.TaskDuration) * 1000,
				scriptMs: (b.ScriptDuration - a.ScriptDuration) * 1000,
				layoutMs: (b.LayoutDuration - a.LayoutDuration) * 1000,
				styleMs: (b.RecalcStyleDuration - a.RecalcStyleDuration) * 1000,
				heapBefore: a.JSHeapUsedSize,
				heapAfter: b.JSHeapUsedSize,
				nodes: b.Nodes,
			},
			driver: {
				cpuMs: (driverCpu.user + driverCpu.system) / 1000,
				rss: process.memoryUsage.rss(),
				heartbeatLag: summary(peerStats.flatMap((s) => s.heartbeatLag)),
				movingPeers: peerStats.reduce((n, s) => n + s.movingPeers, 0),
				positioned: peerStats.reduce((n, s) => n + s.positioned, 0),
				workers: workers.length,
				lateDeltas: peerStats.reduce((n, s) => n + s.lateDeltas, 0),
			},
			serverBefore,
			serverAfter,
			subscriptions: peerStats.reduce((n, s) => n + s.subscriptions, 0),
			errors: [...errors, ...peerErrors],
		};
		results.push(result);
		await Bun.write(
			join(output, "results.json"),
			JSON.stringify(
				{
					options: values,
					machine: {
						cpu: cpus()[0]?.model,
						bun: Bun.version,
						browser: browser.version(),
					},
					results,
				},
				null,
				2,
			),
		);
		await page.screenshot({ path: join(output, `browser-${target}.png`) });
		console.log(
			JSON.stringify({
				target,
				fps: result.fps,
				drawP95Ms: result.drawMs.p95,
				rxKiBs: rxBytes / (ended - started) / 1.024,
				driverCpuCores: result.driver.cpuMs / (ended - started),
				errors: result.errors.length,
			}),
		);
		assert.equal(
			state.players,
			target,
			"Players disconnected during measurement",
		);
		assert.equal(result.errors.length, 0, "Connection or browser errors");
		assert(
			result.driver.heartbeatLag.max < 1000,
			"Load generator cannot maintain input cadence; use more workers or a separate load host",
		);
		assert.equal(
			result.driver.positioned,
			target - 1,
			"Peers did not locate their spawn region; subscriptions measure the wrong chunks",
		);
		assert(
			perf.draws.length > 0 && rxFrames > 0,
			"No drawing or live updates measured",
		);
		await broadcast({ type: "move", moving: false });
		for (const key of ["ArrowRight", "ArrowDown", "ArrowLeft", "ArrowUp"])
			await page.keyboard.up(key);
	}
} catch (error) {
	await Bun.write(
		join(output, "failure.json"),
		JSON.stringify({ admitted, error: String(error), at: Date.now() }, null, 2),
	);
	throw error;
} finally {
	try {
		await broadcast({ type: "close" });
	} finally {
		for (const worker of workers) worker.terminate();
	}
	await browser?.close();
	await closeEdge?.();
	if (server) {
		server.kill("SIGTERM");
		await server.exited;
	}
	console.log(`Artifacts: ${output}`);
}
