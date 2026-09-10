import { heapStats, profile } from "bun:jsc";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir } from "node:fs/promises";
import { cpus } from "node:os";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import {
	type BatchOperation,
	createClient,
	type ZyncBaseClient,
} from "@zyncbase/client";
import {
	buildServerIfNeeded,
	createE2ETestContext,
	withServer,
} from "../../tests/e2e/src/harness";
import {
	chunkIndex,
	type Direction,
	HEIGHT,
	NAMESPACE,
	RULES,
	rowId,
	WIDTH,
} from "./shared";
import { World } from "./world";

const { values } = parseArgs({
	args: process.argv.slice(2),
	options: {
		countries: { type: "string", default: "20" },
		ticks: { type: "string", default: "1200" },
		warmup: { type: "string", default: "200" },
		mode: { type: "string", default: "bots" },
		shape: { type: "string", default: "fragmented" },
		publish: { type: "boolean", default: false },
		unpaced: { type: "boolean", default: false },
		profile: { type: "boolean", default: false },
		output: {
			type: "string",
			default: "test-artifacts/pixel-conquest-profile",
		},
	},
});
const countryCount = Number(values.countries);
const ticks = Number(values.ticks);
const warmup = Number(values.warmup);
assert(
	Number.isInteger(countryCount) && countryCount >= 2 && countryCount <= 20,
);
assert(Number.isInteger(ticks) && ticks > 0);
assert(Number.isInteger(warmup) && warmup >= 0);
assert(values.mode === "scripted" || values.mode === "bots");
assert(values.shape === "compact" || values.shape === "fragmented");
const output = resolve(values.output);
await mkdir(output, { recursive: true });

// Synthetic, all-land geometry isolates territory complexity from coastlines.
// Each home region owns 26,112 pixels in both layouts. Fragmented countries
// also have a 5x5 outpost in the previous country's open bay, widening bounds.
// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: keep deterministic geometry and population setup together, outside measured code.
function fixture() {
	const seed = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	const starts: { code: number; x: number; y: number }[] = [];
	const paint = (x: number, y: number, code: number) => {
		seed.owners[y * WIDTH + x] = code;
		seed.dirtyChunks.add(chunkIndex(x, y));
	};
	for (let i = 0; i < countryCount; i++) {
		const left = 20 + (i % 5) * 390;
		const top = 20 + Math.floor(i / 5) * 240;
		for (let y = 0; y < 200; y++) {
			for (let x = 0; x < 340; x++) {
				const owned =
					values.shape === "compact"
						? x >= 32 && x < 288 && y >= 49 && y < 151
						: x < 32 || y < 32 || y >= 168;
				if (owned) paint(left + x, top + y, i + 1);
			}
		}
		const border = left + (values.shape === "compact" ? 287 : 31);
		starts.push({ code: i + 1, x: border, y: top + 100 });
		const rival = ((i + 1) % countryCount) + 1;
		starts.push({ code: rival, x: border + 6, y: top + 100 });
		if (values.shape === "fragmented") {
			for (let y = 98; y <= 102; y++)
				for (let x = 35; x <= 39; x++) paint(left + x, top + y, rival);
		}
	}
	const world = new World(seed.land);
	world.restore(
		Array.from({ length: countryCount }, (_, i) => ({
			id: rowId(i + 1),
			code: i + 1,
			name: `Country ${i + 1}`,
			color: "red",
			count: 0,
		})),
		[...seed.dirtyChunks].map((index) => seed.chunk(index)),
	);
	for (const [i, start] of starts.entries()) {
		const id = `mover-${i}`;
		world.players.set(id, {
			id,
			name: values.mode === "bots" ? undefined : `Player ${i}`,
			country_id: start.code,
			is_bot: values.mode === "bots",
			lastX: start.x,
			lastY: start.y,
			x: start.x,
			y: start.y,
			seq: 0,
			sentAt: 0,
			direction: "idle",
			credit: 0,
			heardAt: 0,
		});
		world.dirtyPlayers.add(id);
	}
	if (values.mode === "bots") {
		// Benchmark-only population policy: keep 40 bots without a human sentinel.
		// Movement, steering, route planning and captures still use World.tick.
		Object.defineProperties(world, {
			populateBots: { value: () => {} },
			humanCount: { get: () => 1 },
		});
		world.startBots(0);
	}
	world.dirtyChunks.clear();
	world.dirtyCountries.clear();
	verify(world);
	return world;
}

function verify(world: World) {
	assert.equal(world.players.size, countryCount * 2);
	assert.equal(world.countries.size, countryCount);
	const counts = new Uint32Array(countryCount + 1);
	for (const code of world.owners) {
		assert(code <= countryCount);
		counts[code]++;
	}
	for (const country of world.countries.values())
		assert.equal(country.count, counts[country.code]);
	for (const player of world.players.values())
		assert(
			player.x >= 0 && player.x < WIDTH && player.y >= 0 && player.y < HEIGHT,
		);
}

function steer(world: World, tick: number) {
	if (values.mode !== "scripted") return;
	const directions: Direction[] = ["right", "down", "left", "up"];
	let index = 0;
	for (const player of world.players.values()) {
		player.heardAt = tick * RULES.tickMs;
		player.direction =
			directions[(Math.floor(tick / 120) + (index++ % 2) * 2) % 4];
	}
}

// Match server.ts: full dirty chunk rows, country rows, player rows, then committed batches.
function changes(world: World) {
	const chunks = [...world.dirtyChunks].map((index) => world.chunk(index));
	const operations: BatchOperation[] = [...world.dirtyCountries].map((code) => {
		const country = world.countries.get(code);
		assert(country);
		const { id, ...value } = country;
		return { op: "set", path: ["countries", id], value };
	});
	for (const id of world.dirtyPlayers) {
		const row = world.playerRow(id);
		assert(row);
		operations.push({ op: "set", path: ["players", id], value: row });
	}
	for (const { id, ...value } of chunks)
		operations.push({ op: "set", path: ["chunks", id], value });
	world.dirtyChunks.clear();
	world.dirtyCountries.clear();
	world.dirtyPlayers.clear();
	return {
		operations,
		chunks: chunks.length,
		bytes: chunks.reduce(
			(sum, chunk) => sum + chunk.owners.byteLength + chunk.dots.byteLength,
			0,
		),
	};
}

function summary(samples: number[]) {
	const sorted = samples.toSorted((a, b) => a - b);
	const percentile = (p: number) =>
		sorted[Math.max(0, Math.ceil(sorted.length * p) - 1)] ?? 0;
	return {
		totalMs: samples.reduce((sum, value) => sum + value, 0),
		p50Ms: percentile(0.5),
		p95Ms: percentile(0.95),
		p99Ms: percentile(0.99),
		maxMs: sorted.at(-1) ?? 0,
	};
}

function checksum(world: World) {
	return createHash("sha256")
		.update(new Uint8Array(world.owners.buffer))
		.update(JSON.stringify([...world.players.values()]))
		.digest("hex");
}

async function commitBatch(
	client: ZyncBaseClient,
	operations: BatchOperation[],
	label = "fixture setup",
) {
	let timer: ReturnType<typeof setTimeout> | undefined;
	try {
		await Promise.race([
			client.store.batch(operations, { confirm: "committed" }),
			new Promise<never>((_, reject) => {
				timer = setTimeout(
					() =>
						reject(new Error(`Commit timed out after 10 seconds: ${label}`)),
					10000,
				);
			}),
		]);
	} finally {
		clearTimeout(timer);
	}
}

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: setup, warmup and verification intentionally surround one measured interval.
async function run(client?: ZyncBaseClient) {
	let world = fixture();
	for (let tick = 0; tick < warmup; tick++) {
		steer(world, tick);
		world.tick(tick * RULES.tickMs);
		changes(world);
	}
	// Reset after warming code: every mode measures from the original fixture.
	world = fixture();
	const initialChecksum = checksum(world);
	const initialOwnedPixels = [...world.countries.values()].reduce(
		(sum, c) => sum + c.count,
		0,
	);
	if (client) {
		for (let cell = 0; cell < world.owners.length; cell++)
			if (world.owners[cell])
				world.dirtyChunks.add(
					chunkIndex(cell % WIDTH, Math.floor(cell / WIDTH)),
				);
		for (const code of world.countries.keys()) world.dirtyCountries.add(code);
		const initial = changes(world).operations;
		for (let i = 0; i < initial.length; i += 100)
			await commitBatch(client, initial.slice(i, i + 100));
	}
	console.log(
		`Measuring ${ticks} ticks: ${countryCount} countries, ${values.mode}, ${values.shape}, database=${!!client}`,
	);
	Bun.gc(true);
	const simulation: number[] = [],
		serialization: number[] = [],
		commit: number[] = [],
		total: number[] = [];
	let chunkWrites = 0,
		payloadBytes = 0,
		flushes = 0;
	const cpu = process.cpuUsage();
	const heapBefore = heapStats();
	const started = performance.now();
	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: keep phase timers in one loop so the measured work is explicit.
	const measure = async () => {
		for (let tick = 0; tick < ticks; tick++) {
			steer(world, tick);
			const t0 = performance.now();
			world.tick(tick * RULES.tickMs);
			const t1 = performance.now();
			const batch = changes(world);
			const t2 = performance.now();
			if (client && batch.operations.length) {
				await commitBatch(
					client,
					batch.operations,
					`tick ${tick}, ${batch.operations.length} operations after ${flushes} commits`,
				);
				flushes++;
			}
			const t3 = performance.now();
			simulation.push(t1 - t0);
			serialization.push(t2 - t1);
			commit.push(t3 - t2);
			total.push(t3 - t0);
			chunkWrites += batch.chunks;
			payloadBytes += batch.bytes;
			if (client && (tick + 1) % 200 === 0)
				console.log(`Committed ${tick + 1}/${ticks} ticks`);
			// Publishing defaults to the game's 20 Hz rate. --unpaced stresses commits.
			if (client && !values.unpaced)
				await Bun.sleep(Math.max(0, RULES.tickMs - (performance.now() - t0)));
		}
	};
	const sampling = values.profile ? await profile(measure) : await measure();
	const elapsedMs = performance.now() - started;
	const cpuUsed = process.cpuUsage(cpu);
	const heapAfter = heapStats();
	const result = {
		options: values,
		machine: {
			bun: Bun.version,
			platform: process.platform,
			arch: process.arch,
			cpu: cpus()[0]?.model,
		},
		countries: countryCount,
		movers: world.players.size,
		initialOwnedPixels,
		initialChecksum,
		finalChecksum: checksum(world),
		elapsedMs,
		simulatedMs: ticks * RULES.tickMs,
		cpuUserMs: cpuUsed.user / 1000,
		cpuSystemMs: cpuUsed.system / 1000,
		heapBefore: {
			heapSize: heapBefore.heapSize,
			extraMemorySize: heapBefore.extraMemorySize,
		},
		heapAfter: {
			heapSize: heapAfter.heapSize,
			extraMemorySize: heapAfter.extraMemorySize,
		},
		simulation: summary(simulation),
		serialization: summary(serialization),
		commit: summary(commit),
		total: summary(total),
		ticksOverBudget: total.filter((ms) => ms > RULES.tickMs).length,
		chunkWrites,
		payloadBytes,
		flushes,
	};
	verify(world);
	const label = `${countryCount}-${values.shape}-${values.mode}-${client ? "database" : "local"}${values.profile ? "-profile" : ""}`;
	await Bun.write(
		join(output, `${label}.json`),
		JSON.stringify(result, null, 2),
	);
	if (sampling) {
		await Bun.write(
			join(output, `${label}.profile.json`),
			JSON.stringify(sampling),
		);
		console.log(sampling.functions);
	}
	console.log(JSON.stringify(result, null, 2));
}

if (values.publish) {
	buildServerIfNeeded();
	const ctx = await createE2ETestContext("pixel-conquest-profile");
	await withServer(
		ctx,
		{
			schemaPath: join(import.meta.dir, "schema.json"),
			dataDir: ctx.dataDir,
			authPath: "tests/e2e/auth-allow-all.json",
		},
		async ({ port }) => {
			const client = createClient({
				url: `ws://127.0.0.1:${port}`,
				storeNamespace: NAMESPACE,
				reconnect: false,
			});
			try {
				await client.connect();
				await run(client);
			} finally {
				client.disconnect();
			}
		},
	);
} else await run();
