import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { parseArgs } from "node:util";
import {
	buildServerIfNeeded,
	createE2ETestContext,
	PRESENCE_E2E_JWT_SECRET,
	withServer,
} from "../../tests/e2e/src/harness";

const { values } = parseArgs({
	args: Bun.argv.slice(2),
	options: {
		shards: { type: "string", default: "1" },
		corpus: { type: "string", default: "benchmark/corpus/combo.json" },
	},
});

// The corpus has four logical roles per shard (2 rooms x 2 tables), each with
// 2,500 clients. A single worker per shard is fastest at 50k/100k; the 10k run
// keeps two workers because one worker's event loop slows setup there.
const processesPerShard = 4;
const shards = Number(values.shards);
const rolesPerWorker = Number(
	process.env.BENCH_ROLES_PER_WORKER ?? (shards <= 1 ? 2 : 4),
);
const clientsPerRole = 2500;
const clientsPerProcess = rolesPerWorker * clientsPerRole;
const workersPerShard = processesPerShard / rolesPerWorker;
const internal = process.env.BENCH_INTERNAL === "1";
const latency = process.env.BENCH_LATENCY === "1";
const profileDir = process.env.ZYNCBASE_COMBO_PROFILE_DIR;
const root = path.resolve(import.meta.dir, "../..");
const corpusPath = path.resolve(root, values.corpus);
const processCount = workersPerShard * shards;
const hostCpus = os.availableParallelism();

if (!Number.isInteger(shards) || shards < 1) {
	throw new Error("combo: invalid --shards");
}
if (
	!Number.isInteger(rolesPerWorker) ||
	rolesPerWorker < 1 ||
	rolesPerWorker > processesPerShard ||
	processesPerShard % rolesPerWorker !== 0
) {
	throw new Error("combo: roles per worker must divide the four shard roles");
}
if (profileDir) fs.mkdirSync(profileDir, { recursive: true });

type WorkerResult = {
	cpuMs: number;
	connections: number;
	closed: number;
	frames: number;
	bytes: number;
	phaseFrames: Record<string, number>;
	setupFail: Record<string, number>;
	latency: Record<string, LatencyHistogram>;
	shard: number;
};

type LatencyHistogram = {
	buckets: number[];
	samples: number;
	overflow: number;
	maxMs: number;
};

type ServerStats = {
	messages: { received_total: number; sent_total: number };
};

type ThreadSample = {
	tid: number;
	name: string;
	cpuSeconds: number;
};

type PhaseSample = {
	ms: number;
	sent: number;
	received: number;
	generatorCpuMs: number;
	serverCpuSeconds: number;
	threadCpu: ThreadSample[];
};

type WorkerState = {
	global: number;
	shard: number;
	local: number;
	proc: Bun.Subprocess;
	stopping: boolean;
	failure: Error | null;
	ready: PromiseWithResolvers<void>;
	armed: PromiseWithResolvers<void>;
	fired: PromiseWithResolvers<void>;
	collected: PromiseWithResolvers<{
		framesBefore: number;
		framesAfter: number;
		subscriberFrames: number;
	}>;
	result: PromiseWithResolvers<WorkerResult>;
	readyCpuMs: number;
	readyStages: Record<
		string,
		{ count: number; totalMs: number; maxMs: number }
	>;
	readyPairAGaps: number[];
	readyPairBGaps: number[];
	readyPairASameFrame: number;
	readyPairBSameFrame: number;
	readyFramesTotal: number;
	readyMessagesTotal: number;
	readySetupConnections: number;
	phaseCpu: Map<string, number>;
	phaseWaiters: Map<
		string,
		{ resolve: () => void; reject: (error: Error) => void }
	>;
};

buildServerIfNeeded();
const ctx = await createE2ETestContext(`combo-load-${shards}shard`);

await withServer(
	ctx,
	{
		schemaPath: ctx.schemaPath("schema-combo-stress.json"),
		dataDir: ctx.dataPath(`combo-load-${shards}shard`),
		configName: "zyncbase-config-combo-load.json",
		authPath: ctx.schemaPath("auth-allow-all.json"),
		jwtSecret: PRESENCE_E2E_JWT_SECRET,
		idleTimeoutSeconds: 239,
		// Latency probes are extra connections beyond the workload clients.
		maxConnections: processCount * clientsPerProcess + 1000,
	},
	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: linear benchmark orchestration
	async (server) => {
		const started = performance.now();
		const serverCpuStart = processCpuSeconds(server.process.pid);
		const threadsStart = readThreadCpu(server.process.pid);
		const statsStart = await readStats(server.port);
		const workers: WorkerState[] = [];
		const memory = startMemorySampler(server.process.pid, workers);

		for (let global = 0; global < processCount; global++) {
			const shard = Math.floor(global / workersPerShard);
			const local = global % workersPerShard;
			const roleStart = local * rolesPerWorker;
			const roleList = Array.from(
				{ length: rolesPerWorker },
				(_, offset) => roleStart + offset,
			);
			// Each shard uses its own loopback destination IP: one listener, but
			// separate source-port tuple spaces so 50k localhost sockets do not
			// exhaust the ephemeral port range.
			const host = shards === 1 ? "127.0.0.1" : `127.0.0.${shard + 1}`;
			let state: WorkerState | null = null;
			const workerArgs = [process.execPath];
			if (profileDir) {
				workerArgs.push(
					"--cpu-prof",
					"--cpu-prof-md",
					"--cpu-prof-dir",
					profileDir,
					"--cpu-prof-name",
					`combo-worker-${global}`,
				);
			}
			workerArgs.push(
				path.join(root, "benchmark/load/combo-worker.ts"),
				"--port",
				String(server.port),
				"--host",
				host,
				"--secret",
				PRESENCE_E2E_JWT_SECRET,
				"--corpus",
				corpusPath,
				"--processes",
				roleList.join(","),
				"--shard",
				String(shard),
				"--clients",
				String(clientsPerRole),
			);
			const proc = Bun.spawn(workerArgs, {
				cwd: root,
				stdio: ["ignore", "inherit", "inherit"],
				ipc: (message) => {
					if (state) handleMessage(state, message);
				},
			});
			const ready = Promise.withResolvers<void>();
			const armed = Promise.withResolvers<void>();
			const fired = Promise.withResolvers<void>();
			const collected = Promise.withResolvers<{
				framesBefore: number;
				framesAfter: number;
				subscriberFrames: number;
			}>();
			const result = Promise.withResolvers<WorkerResult>();
			// Probe deferreds are unused in single-shard runs; mark them handled
			// so a worker failure cannot surface as an unhandled rejection.
			armed.promise.catch(() => {});
			fired.promise.catch(() => {});
			collected.promise.catch(() => {});
			state = {
				global,
				shard,
				local,
				proc,
				stopping: false,
				failure: null,
				ready,
				armed,
				fired,
				collected,
				result,
				readyCpuMs: 0,
				readyStages: {},
				readyPairAGaps: [],
				readyPairBGaps: [],
				readyPairASameFrame: 0,
				readyPairBSameFrame: 0,
				readyFramesTotal: 0,
				readyMessagesTotal: 0,
				readySetupConnections: 0,
				phaseCpu: new Map(),
				phaseWaiters: new Map(),
			};
			const created = state;
			workers.push(created);
			proc.exited.then((code) => {
				if (code !== 0 && !created.stopping) {
					fail(created, new Error(`worker ${global} exited with ${code}`));
				}
			});
		}

		try {
			await Promise.all(workers.map((worker) => worker.ready.promise));
			const setupMs = performance.now() - started;
			const statsReady = await readStats(server.port);
			const setupSample: PhaseSample = {
				ms: setupMs,
				sent: statsReady.messages.sent_total - statsStart.messages.sent_total,
				received:
					statsReady.messages.received_total -
					statsStart.messages.received_total,
				generatorCpuMs: workers.reduce(
					(sum, worker) => sum + worker.readyCpuMs,
					0,
				),
				serverCpuSeconds:
					processCpuSeconds(server.process.pid) - serverCpuStart,
				threadCpu: internal
					? diffThreadCpu(threadsStart, readThreadCpu(server.process.pid))
					: [],
			};

			if (process.env.COMBO_SETUP_ONLY === "1") {
				const setupSeconds = setupSample.ms / 1000;
				const generatorCpu =
					workers.reduce((sum, worker) => sum + worker.readyCpuMs, 0) / 1000;
				const serverCpu = setupSample.serverCpuSeconds;
				memory.stop();
				console.log(
					`\nsetup-only: ${processCount * clientsPerProcess} connections in ${Math.round(setupSample.ms)}ms; ` +
						`server=${(serverCpu / setupSeconds).toFixed(2)} cores, ` +
						`generator=${(generatorCpu / setupSeconds).toFixed(2)} cores`,
				);
				reportMemory(memory, processCount * clientsPerProcess);
				reportSetupStages(workers);
				return;
			}

			const phase = async (name: string): Promise<number> => {
				for (const worker of workers) {
					if (worker.failure) throw worker.failure;
				}
				const start = performance.now();
				const startEpoch = performance.timeOrigin + start;
				const done = workers.map(
					(worker) =>
						new Promise<void>((resolve, reject) => {
							worker.phaseWaiters.set(name, { resolve, reject });
						}),
				);
				for (const worker of workers) {
					worker.proc.send({ type: "phase", phase: name, startEpoch });
				}
				await Promise.all(done);
				return performance.now() - start;
			};

			let lastStats = statsReady;
			const measurePhase = async (name: string): Promise<PhaseSample> => {
				if (!internal) {
					const ms = await phase(name);
					const after = await readStats(server.port);
					const sample: PhaseSample = {
						ms,
						sent: after.messages.sent_total - lastStats.messages.sent_total,
						received:
							after.messages.received_total - lastStats.messages.received_total,
						generatorCpuMs: workers.reduce(
							(sum, worker) => sum + (worker.phaseCpu.get(name) ?? 0),
							0,
						),
						serverCpuSeconds: 0,
						threadCpu: [],
					};
					lastStats = after;
					return sample;
				}
				const before = await readStats(server.port);
				const serverCpuBefore = processCpuSeconds(server.process.pid);
				const threadsBefore = readThreadCpu(server.process.pid);
				const ms = await phase(name);
				const serverCpuSeconds =
					processCpuSeconds(server.process.pid) - serverCpuBefore;
				const threadCpu = diffThreadCpu(
					threadsBefore,
					readThreadCpu(server.process.pid),
				);
				const after = await readStats(server.port);
				return {
					ms,
					sent: after.messages.sent_total - before.messages.sent_total,
					received:
						after.messages.received_total - before.messages.received_total,
					generatorCpuMs: workers.reduce(
						(sum, worker) => sum + (worker.phaseCpu.get(name) ?? 0),
						0,
					),
					serverCpuSeconds,
					threadCpu,
				};
			};

			const create = await measurePhase("store-create");
			const update = await measurePhase("store-update");
			const presenceUser = await measurePhase("presence-user");
			const presenceShared = await measurePhase("presence-shared");
			const converge = await measurePhase("converge");
			const createMs = create.ms;
			const updateMs = update.ms;
			const presenceUserMs = presenceUser.ms;
			const presenceSharedMs = presenceShared.ms;
			const convergeMs = converge.ms;
			const workloadMs = performance.now() - started;
			let isolationMs = 0;
			if (shards > 1) {
				const probeStart = performance.now();
				await runIsolationProbe(workers);
				isolationMs = performance.now() - probeStart;
			}
			for (const worker of workers) worker.proc.send({ type: "cleanup" });
			const results = await Promise.all(
				workers.map((worker) => worker.result.promise),
			);
			memory.stop();
			const totalMs = performance.now() - started - isolationMs;
			const cleanupMs = totalMs - workloadMs;
			const generatorCpu = results.reduce((sum, r) => sum + r.cpuMs, 0) / 1000;
			const serverCpu = processCpuSeconds(server.process.pid) - serverCpuStart;
			const elapsedSeconds = (totalMs + isolationMs) / 1000;
			const serverCores = serverCpu / elapsedSeconds;
			const generatorCores = generatorCpu / elapsedSeconds;
			const totalCores = serverCores + generatorCores;

			const failed = workers.find((worker) => worker.failure);
			if (failed?.failure) throw failed.failure;
			const closedClients = results.reduce((sum, r) => sum + r.closed, 0);
			if (closedClients > 0) {
				throw new Error(`${closedClients} clients disconnected before cleanup`);
			}
			console.log(
				`\ncombo server load test passed: ${processCount * clientsPerProcess} clients across ${processCount} processes` +
					(shards > 1 ? ` (${shards} isolated shards)` : "") +
					` in ${Math.round(totalMs)}ms`,
			);
			const phaseParts = [
				`setup=${Math.round(setupMs)}`,
				`store-create=${Math.round(createMs)}`,
				`store-update=${Math.round(updateMs)}`,
				`presence-user=${Math.round(presenceUserMs)}`,
				`presence-shared=${Math.round(presenceSharedMs)}`,
				`converge=${Math.round(convergeMs)}`,
			];
			if (internal) {
				if (shards > 1) {
					phaseParts.push(`isolation=${Math.round(isolationMs)}`);
				}
				phaseParts.push(`cleanup=${Math.round(cleanupMs)}`);
			}
			console.log(`  phases ms: ${phaseParts.join(", ")}`);
			if (internal) {
				console.log(
					`  cpu cores: host=${hostCpus}, server=${serverCores.toFixed(2)}, ` +
						`generator=${generatorCores.toFixed(2)}, total=${totalCores.toFixed(2)} (co-located)`,
				);
				console.log(
					`  connections=${results.reduce((sum, r) => sum + r.connections, 0)}`,
				);
			} else {
				console.log(
					`  cpu: host=${hostCpus} cores, server=${serverCores.toFixed(2)}, ` +
						`generator=${generatorCores.toFixed(2)}, total=${totalCores.toFixed(2)} ` +
						`(co-located)`,
				);
			}
			reportMemory(memory, processCount * clientsPerProcess);
			if (latency) reportLatency(results);
			reportMessages({
				setup: setupSample,
				phases: {
					"store-create": create,
					"store-update": update,
					"presence-user": presenceUser,
					"presence-shared": presenceShared,
					converge,
				},
				results,
				storeWrites: 100 * processesPerShard * shards,
				presenceSets: 100 * 3 * processesPerShard * shards,
				clients: processCount * clientsPerProcess,
				internal,
			});
			if (internal) {
				reportSetupStages(workers);
				reportSetupCoalescing(workers);
				reportCpu({
					serverPid: server.process.pid,
					setup: setupSample,
					phases: {
						"store-create": create,
						"store-update": update,
						"presence-user": presenceUser,
						"presence-shared": presenceShared,
						converge,
					},
				});
			}
			reportShards(workers, results, internal);
		} finally {
			memory.stop();
			if (profileDir) await Bun.sleep(500);
			for (const worker of workers) {
				worker.stopping = true;
				worker.proc.kill();
			}
			await Promise.all(
				workers.map((worker) => worker.proc.exited.catch(() => 0)),
			);
		}
	},
);

function reportSetupStages(workers: WorkerState[]): void {
	const totals = new Map<
		string,
		{ count: number; totalMs: number; maxMs: number }
	>();
	for (const worker of workers) {
		for (const [name, stat] of Object.entries(worker.readyStages)) {
			const current = totals.get(name) ?? { count: 0, totalMs: 0, maxMs: 0 };
			current.count += stat.count;
			current.totalMs += stat.totalMs;
			current.maxMs = Math.max(current.maxMs, stat.maxMs);
			totals.set(name, current);
		}
	}
	const order = [
		"ticket",
		"ws",
		"store-namespace",
		"store-sub+presence-ns",
		"presence-subs",
	];
	console.log("  setup stages (avg ms/connection, worst worker max):");
	for (const name of order) {
		const stat = totals.get(name);
		if (!stat || stat.count === 0) continue;
		console.log(
			`    ${name.padEnd(24)} avg=${(stat.totalMs / stat.count).toFixed(2)} ` +
				`max=${stat.maxMs.toFixed(1)}`,
		);
	}
}

function reportSetupCoalescing(workers: WorkerState[]): void {
	const pairA: number[] = [];
	const pairB: number[] = [];
	let sameA = 0;
	let sameB = 0;
	let frames = 0;
	let messages = 0;
	let connections = 0;
	for (const worker of workers) {
		pairA.push(...worker.readyPairAGaps);
		pairB.push(...worker.readyPairBGaps);
		sameA += worker.readyPairASameFrame;
		sameB += worker.readyPairBSameFrame;
		frames += worker.readyFramesTotal;
		messages += worker.readyMessagesTotal;
		connections += worker.readySetupConnections;
	}
	if (connections === 0) return;
	const percentile = (values: number[], p: number) => {
		if (values.length === 0) return 0;
		const sorted = [...values].sort((a, b) => a - b);
		return sorted[
			Math.min(sorted.length - 1, Math.ceil(p * sorted.length) - 1)
		];
	};
	const share = (count: number, total: number) =>
		total === 0 ? "0" : ((count / total) * 100).toFixed(1);
	console.log(
		`  setup coalescing: frames/conn=${(frames / connections).toFixed(2)}, ` +
			`messages/conn=${(messages / connections).toFixed(2)}`,
	);
	console.log(
		`    pair A (store sub / presence ns): p50=${percentile(pairA, 0.5).toFixed(2)}ms ` +
			`p95=${percentile(pairA, 0.95).toFixed(2)}ms same-frame=${share(sameA, pairA.length)}%`,
	);
	console.log(
		`    pair B (presence sub / shared):  p50=${percentile(pairB, 0.5).toFixed(2)}ms ` +
			`p95=${percentile(pairB, 0.95).toFixed(2)}ms same-frame=${share(sameB, pairB.length)}%`,
	);
}

function reportCpu(args: {
	serverPid: number;
	setup: PhaseSample;
	phases: {
		"store-create": PhaseSample;
		"store-update": PhaseSample;
		"presence-user": PhaseSample;
		"presence-shared": PhaseSample;
		converge: PhaseSample;
	};
}): void {
	const { serverPid, setup, phases } = args;
	const label = (thread: ThreadSample) =>
		thread.tid === serverPid ? "main" : `${thread.name}#${thread.tid}`;
	const rows = [
		["setup", setup],
		["store-create", phases["store-create"]],
		["store-update", phases["store-update"]],
		["presence-user", phases["presence-user"]],
		["presence-shared", phases["presence-shared"]],
		["converge", phases.converge],
	] as const;

	console.log("  cpu by phase (cores: server / generator; top server thread):");
	for (const [name, sample] of rows) {
		const seconds = sample.ms / 1000;
		const top = sample.threadCpu[0];
		const topText = top
			? `${label(top)} ${(top.cpuSeconds / seconds).toFixed(2)}`
			: "none";
		console.log(
			`    ${name.padEnd(16)} server=${(sample.serverCpuSeconds / seconds).toFixed(2)} ` +
				`generator=${(sample.generatorCpuMs / 1000 / seconds).toFixed(2)} ` +
				`top=${topText}`,
		);
	}

	const byThread = new Map<number, ThreadSample>();
	let workloadSeconds = 0;
	for (const sample of Object.values(phases)) {
		workloadSeconds += sample.ms / 1000;
		for (const thread of sample.threadCpu) {
			const current = byThread.get(thread.tid);
			if (current) current.cpuSeconds += thread.cpuSeconds;
			else byThread.set(thread.tid, { ...thread });
		}
	}
	const threads = [...byThread.values()].sort(
		(a, b) => b.cpuSeconds - a.cpuSeconds,
	);
	console.log("  server threads (workload, top 6):");
	for (const thread of threads.slice(0, 6)) {
		console.log(
			`    ${label(thread).padEnd(20)} ${thread.cpuSeconds.toFixed(2)}s ` +
				`(${(thread.cpuSeconds / workloadSeconds).toFixed(2)} cores)`,
		);
	}
}

function reportMessages(args: {
	setup: PhaseSample;
	phases: {
		"store-create": PhaseSample;
		"store-update": PhaseSample;
		"presence-user": PhaseSample;
		"presence-shared": PhaseSample;
		converge: PhaseSample;
	};
	results: WorkerResult[];
	storeWrites: number;
	presenceSets: number;
	clients: number;
	internal: boolean;
}): void {
	const {
		setup,
		phases,
		results,
		storeWrites,
		presenceSets,
		clients,
		internal,
	} = args;
	const formatCount = (value: number) =>
		Math.round(value).toLocaleString("en-US");
	const formatRate = (value: number) =>
		`${Math.round(value).toLocaleString("en-US")}/s`;
	const frames = (name: string) =>
		results.reduce((sum, result) => sum + (result.phaseFrames[name] ?? 0), 0);
	const setupSeconds = setup.ms / 1000;

	console.log(
		`  setup: ${formatCount(clients)} connections in ${(setup.ms / 1000).toFixed(1)}s ` +
			`(${formatRate(clients / setupSeconds)})` +
			(internal
				? `; server sent=${formatCount(setup.sent)}, received=${formatCount(setup.received)}`
				: ""),
	);
	console.log(
		internal
			? "  server messages (phase averages):"
			: "  fanout messages (phase averages):",
	);

	// Latency probes are extra subscribers; exclude their copies so fanout
	// numbers stay comparable with runs that do not measure latency.
	const probeMessages = (label: string) =>
		latency
			? results.reduce(
					(sum, result) => sum + (result.latency[label]?.samples ?? 0),
					0,
				)
			: 0;

	const row = (
		label: string,
		sample: PhaseSample,
		ops: number,
		opName: "write" | "set" | "",
	) => {
		const seconds = sample.ms / 1000;
		const sent = Math.max(0, sample.sent - probeMessages(label));
		const fanout = Math.max(0, sent - ops);
		const frameCount = frames(label);
		if (internal) {
			const perOp =
				ops > 0 ? ` fanout/${opName}=${(fanout / ops).toFixed(1)}` : "";
			const perFrame =
				frameCount > 0 ? ` msgs/frame=${(sent / frameCount).toFixed(1)}` : "";
			const opsText = ops > 0 ? ` ops=${formatCount(ops)}` : "";
			console.log(
				`    ${label.padEnd(16)} sent=${formatCount(sent).padStart(10)} ` +
					`(${formatRate(sent / seconds)})  ` +
					`fanout=${formatCount(fanout).padStart(10)} ` +
					`(${formatRate(fanout / seconds)})${opsText}${perOp}${perFrame}`,
			);
		} else {
			const perOp =
				ops > 0 ? `  ${(fanout / ops).toFixed(1)} per ${opName}` : "";
			console.log(
				`    ${label.padEnd(16)} ${formatCount(fanout).padStart(10)} ` +
					`(${formatRate(fanout / seconds)})${perOp}`,
			);
		}
	};

	const fanoutOf = (sample: PhaseSample, ops: number, label: string) =>
		Math.max(0, sample.sent - probeMessages(label) - ops);

	row("store-create", phases["store-create"], storeWrites, "write");
	row("store-update", phases["store-update"], storeWrites, "write");
	if (internal) {
		row("presence-user", phases["presence-user"], presenceSets, "set");
		row("presence-shared", phases["presence-shared"], presenceSets, "set");
		row("converge", phases.converge, 0, "");
	}

	const labels = [
		"store-create",
		"store-update",
		"presence-user",
		"presence-shared",
		"converge",
	] as const;
	const ordered = labels.map((label) => phases[label]);
	const totalMs = ordered.reduce((sum, phase) => sum + phase.ms, 0);
	const totalSent = labels.reduce(
		(sum, label) => sum + phases[label].sent - probeMessages(label),
		0,
	);
	const totalOps = storeWrites * 2 + presenceSets * 2;
	const totalFanout = Math.max(0, totalSent - totalOps);
	const totalFrames = labels.reduce((sum, label) => sum + frames(label), 0);
	const storeFanout =
		fanoutOf(phases["store-create"], storeWrites, "store-create") +
		fanoutOf(phases["store-update"], storeWrites, "store-update");
	const storeMs = phases["store-create"].ms + phases["store-update"].ms;
	const presenceFanout = Math.max(0, totalFanout - storeFanout);

	if (internal) {
		console.log(
			`    ${"workload".padEnd(16)} sent=${formatCount(totalSent).padStart(10)} ` +
				`(${formatRate(totalSent / (totalMs / 1000))})  ` +
				`fanout=${formatCount(totalFanout).padStart(10)} ` +
				`(${formatRate(totalFanout / (totalMs / 1000))})` +
				` msgs/frame=${(totalSent / Math.max(1, totalFrames)).toFixed(1)}`,
		);
		console.log(
			"    note: fanout = sent - acks; phase numbers are averages and may include spillover",
		);
	} else {
		console.log(
			`    ${"store total".padEnd(16)} ${formatCount(storeFanout).padStart(10)} ` +
				`(${formatRate(storeFanout / (storeMs / 1000))})`,
		);
		const presenceMs =
			phases["presence-user"].ms +
			phases["presence-shared"].ms +
			phases.converge.ms;
		console.log(
			`    ${"presence total".padEnd(16)} ${formatCount(presenceFanout).padStart(10)} ` +
				`(${formatRate(presenceFanout / (presenceMs / 1000))})`,
		);
		console.log(
			`    ${"workload total".padEnd(16)} ${formatCount(totalFanout).padStart(10)}`,
		);
	}
}

function histogramPercentile(
	histogram: LatencyHistogram,
	fraction: number,
): number | null {
	if (histogram.samples === 0) return null;
	const target = Math.ceil(histogram.samples * fraction);
	let cumulative = 0;
	for (let i = 0; i < histogram.buckets.length; i++) {
		cumulative += histogram.buckets[i];
		if (cumulative >= target) return (i + 1) * 5;
	}
	return null;
}

function mergeLatency(
	results: WorkerResult[],
	phase: string,
): LatencyHistogram | null {
	const merged: LatencyHistogram = {
		buckets: [],
		samples: 0,
		overflow: 0,
		maxMs: 0,
	};
	for (const result of results) {
		const histogram = result.latency[phase];
		if (!histogram || histogram.samples === 0) continue;
		if (merged.buckets.length === 0) {
			merged.buckets = new Array<number>(histogram.buckets.length).fill(0);
		}
		for (let i = 0; i < histogram.buckets.length; i++) {
			merged.buckets[i] += histogram.buckets[i];
		}
		merged.samples += histogram.samples;
		merged.overflow += histogram.overflow;
		merged.maxMs = Math.max(merged.maxMs, histogram.maxMs);
	}
	return merged.samples === 0 ? null : merged;
}

function reportLatency(results: WorkerResult[]): void {
	const phases = ["store-create", "store-update"] as const;
	const rows: string[] = [];
	for (const phase of phases) {
		const merged = mergeLatency(results, phase);
		if (!merged) continue;
		const p50 = histogramPercentile(merged, 0.5);
		const p95 = histogramPercentile(merged, 0.95);
		const p99 = histogramPercentile(merged, 0.99);
		rows.push(
			`    ${phase.padEnd(16)} p50=${p50 === null ? ">" : p50}ms ` +
				`p95=${p95 === null ? ">" : p95}ms ` +
				`p99=${p99 === null ? ">" : p99}ms ` +
				`max=${Math.round(merged.maxMs)}ms (${merged.samples.toLocaleString("en-US")} samples)`,
		);
	}
	if (rows.length === 0) return;
	console.log(
		"  store fanout latency (phase start -> probe receive, 5 ms buckets):",
	);
	for (const row of rows) console.log(row);
}

function reportShards(
	workers: WorkerState[],
	results: WorkerResult[],
	internal: boolean,
): void {
	const shardCount = Math.max(...workers.map((worker) => worker.shard)) + 1;
	for (let shard = 0; shard < shardCount; shard++) {
		const members = results.filter((r) => r.shard === shard);
		const frames = members.reduce((sum, r) => sum + r.frames, 0);
		const bytes = members.reduce((sum, r) => sum + r.bytes, 0);
		console.log(
			`  shard ${shard}: clients=${members.reduce((sum, r) => sum + r.connections, 0)}, ` +
				`closed=${members.reduce((sum, r) => sum + r.closed, 0)}` +
				(internal
					? `, frames=${frames}, bytes=${(bytes / 1e6).toFixed(1)}MB`
					: ""),
		);
		const stages = new Set<string>();
		for (const r of members) {
			for (const stage of Object.keys(r.setupFail)) stages.add(stage);
		}
		const failures = [...stages]
			.map(
				(stage) =>
					`${stage}=${members.reduce((sum, r) => sum + (r.setupFail[stage] ?? 0), 0)}`,
			)
			.filter((entry) => !entry.endsWith("=0"));
		if (failures.length > 0) {
			console.log(`    setup failures: ${failures.join(", ")}`);
		}
	}
}

type MemorySampler = {
	baselineServerBytes: number;
	peakServerBytes: number;
	peakGeneratorBytes: number;
	stop: () => void;
};

function readRssBytes(pid: number): number {
	try {
		const status = fs.readFileSync(`/proc/${pid}/status`, "utf8");
		const match = /VmRSS:\s+(\d+) kB/.exec(status);
		return match ? Number(match[1]) * 1024 : 0;
	} catch {
		return 0;
	}
}

function startMemorySampler(
	serverPid: number,
	workers: WorkerState[],
): MemorySampler {
	let running = true;
	const sampler: MemorySampler = {
		baselineServerBytes: readRssBytes(serverPid),
		peakServerBytes: 0,
		peakGeneratorBytes: 0,
		stop: () => {
			running = false;
		},
	};
	sampler.peakServerBytes = sampler.baselineServerBytes;
	const tick = async () => {
		while (running) {
			sampler.peakServerBytes = Math.max(
				sampler.peakServerBytes,
				readRssBytes(serverPid),
			);
			let generatorBytes = 0;
			for (const worker of workers) {
				generatorBytes += readRssBytes(worker.proc.pid);
			}
			sampler.peakGeneratorBytes = Math.max(
				sampler.peakGeneratorBytes,
				generatorBytes,
			);
			await Bun.sleep(100);
		}
	};
	void tick();
	return sampler;
}

function reportMemory(memory: MemorySampler, clients: number): void {
	const mb = (bytes: number) => (bytes / 1e6).toFixed(1);
	const delta = Math.max(
		0,
		memory.peakServerBytes - memory.baselineServerBytes,
	);
	const perThousand = clients > 0 ? (delta / clients) * 1000 : 0;
	console.log(
		`  memory: server peak=${mb(memory.peakServerBytes)} MB ` +
			`(idle ${mb(memory.baselineServerBytes)}, +${mb(delta)} MB = ` +
			`${mb(perThousand)} MB/1k clients), ` +
			`generator peak=${mb(memory.peakGeneratorBytes)} MB`,
	);
}

// shortcut: Linux CLK_TCK assumed 100; benchmark-only, never used by the server.
function processCpuSeconds(pid: number): number {
	try {
		const stat = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
		const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
		return (Number(fields[11]) + Number(fields[12])) / 100;
	} catch {
		return 0;
	}
}

function readThreadCpu(pid: number): Map<number, ThreadSample> {
	const threads = new Map<number, ThreadSample>();
	let entries: string[];
	try {
		entries = fs.readdirSync(`/proc/${pid}/task`);
	} catch {
		return threads;
	}
	for (const entry of entries) {
		const tid = Number(entry);
		try {
			const stat = fs.readFileSync(`/proc/${pid}/task/${tid}/stat`, "utf8");
			const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
			const cpuSeconds = (Number(fields[11]) + Number(fields[12])) / 100;
			const name = fs
				.readFileSync(`/proc/${pid}/task/${tid}/comm`, "utf8")
				.trim();
			threads.set(tid, { tid, name, cpuSeconds });
		} catch {
			// Thread exited while sampling.
		}
	}
	return threads;
}

function diffThreadCpu(
	before: Map<number, ThreadSample>,
	after: Map<number, ThreadSample>,
): ThreadSample[] {
	const deltas: ThreadSample[] = [];
	for (const [tid, sample] of after) {
		const previous = before.get(tid)?.cpuSeconds ?? 0;
		const cpuSeconds = sample.cpuSeconds - previous;
		if (cpuSeconds > 0.0005) {
			deltas.push({ ...sample, cpuSeconds });
		}
	}
	return deltas.sort((a, b) => b.cpuSeconds - a.cpuSeconds);
}

async function readStats(port: number): Promise<ServerStats> {
	const response = await fetch(`http://127.0.0.1:${port}/stats`);
	if (!response.ok) {
		throw new Error(`stats request failed: ${response.status}`);
	}
	return (await response.json()) as ServerStats;
}

async function runIsolationProbe(workers: WorkerState[]): Promise<void> {
	// Let any workload traffic drain before snapshotting frame counts.
	await Bun.sleep(200);
	for (const worker of workers) worker.proc.send({ type: "probe-arm" });
	await Promise.all(workers.map((worker) => worker.armed.promise));

	const writer = workers.find(
		(worker) => worker.shard === 0 && worker.local === 0,
	);
	if (!writer) throw new Error("isolation probe: missing shard 0 writer");
	writer.proc.send({ type: "probe-fire" });
	await writer.fired.promise;
	await Bun.sleep(1000);

	for (const worker of workers) worker.proc.send({ type: "probe-collect" });
	const collected = await Promise.all(
		workers.map((worker) => worker.collected.promise),
	);
	const perShard = new Map<number, number>();
	for (let i = 0; i < workers.length; i++) {
		const delta = collected[i].framesAfter - collected[i].framesBefore;
		const shard = workers[i].shard;
		perShard.set(shard, (perShard.get(shard) ?? 0) + delta);
	}

	const shardZero = perShard.get(0) ?? 0;
	// shortcut: delivery is inferred from one quiet-window subscriber's frame
	// count; decode the frame if unrelated traffic can overlap the probe.
	const probeDelivered =
		collected[workers.indexOf(writer)]?.subscriberFrames ?? 0;
	if (probeDelivered <= 0) {
		throw new Error("isolation probe: shard 0 subscriber saw no probe fanout");
	}
	for (const [shard, frames] of perShard) {
		if (shard !== 0 && frames !== 0) {
			throw new Error(
				`isolation probe: shard ${shard} saw ${frames} cross-shard frames`,
			);
		}
	}
	console.log(
		`  isolation: shard 0 fanout=${shardZero} frames, probe deliveries=${probeDelivered}; other shards 0`,
	);
}

type WorkerMessage = {
	type?: string;
	phase?: string;
	message?: string;
	framesBefore?: number;
	framesAfter?: number;
	subscriberFrames?: number;
	cpuMs?: number;
	connections?: number;
	closed?: number;
	frames?: number;
	bytes?: number;
	phaseFrames?: Record<string, number>;
	stages?: Record<string, { count: number; totalMs: number; maxMs: number }>;
	pairAGaps?: number[];
	pairBGaps?: number[];
	pairASameFrame?: number;
	pairBSameFrame?: number;
	setupFramesTotal?: number;
	setupMessagesTotal?: number;
	setupConnections?: number;
	shard?: number;
	setupFail?: Record<string, number>;
	latency?: Record<string, LatencyHistogram>;
};

function handleMessage(state: WorkerState, message: unknown): void {
	if (!message || typeof message !== "object") return;
	const record = message as WorkerMessage;
	if (handleProbeMessage(state, record)) return;
	switch (record.type) {
		case "ready":
			applyReady(state, record);
			state.ready.resolve();
			break;
		case "phase-done":
			if (record.phase) {
				state.phaseCpu.set(
					record.phase,
					(state.phaseCpu.get(record.phase) ?? 0) + (record.cpuMs ?? 0),
				);
				state.phaseWaiters.get(record.phase)?.resolve();
				state.phaseWaiters.delete(record.phase);
			}
			break;
		case "result":
			state.result.resolve(toWorkerResult(state, record));
			break;
		case "error":
			fail(state, new Error(record.message ?? "worker failed"));
			break;
	}
}

function applyReady(state: WorkerState, record: WorkerMessage): void {
	state.readyCpuMs = record.cpuMs ?? 0;
	state.readyStages = record.stages ?? {};
	state.readyPairAGaps = record.pairAGaps ?? [];
	state.readyPairBGaps = record.pairBGaps ?? [];
	state.readyPairASameFrame = record.pairASameFrame ?? 0;
	state.readyPairBSameFrame = record.pairBSameFrame ?? 0;
	state.readyFramesTotal = record.setupFramesTotal ?? 0;
	state.readyMessagesTotal = record.setupMessagesTotal ?? 0;
	state.readySetupConnections = record.setupConnections ?? 0;
}

function toWorkerResult(
	state: WorkerState,
	record: WorkerMessage,
): WorkerResult {
	return {
		cpuMs: record.cpuMs ?? 0,
		connections: record.connections ?? 0,
		closed: record.closed ?? 0,
		frames: record.frames ?? 0,
		bytes: record.bytes ?? 0,
		phaseFrames: record.phaseFrames ?? {},
		setupFail: record.setupFail ?? {},
		latency: record.latency ?? {},
		shard: record.shard ?? state.shard,
	};
}

function handleProbeMessage(
	state: WorkerState,
	record: WorkerMessage,
): boolean {
	switch (record.type) {
		case "probe-armed":
			state.armed.resolve();
			return true;
		case "probe-fired":
			state.fired.resolve();
			return true;
		case "probe-collected":
			state.collected.resolve({
				framesBefore: record.framesBefore ?? 0,
				framesAfter: record.framesAfter ?? 0,
				subscriberFrames: record.subscriberFrames ?? 0,
			});
			return true;
		default:
			return false;
	}
}

function fail(state: WorkerState, error: Error): void {
	if (!state.failure) state.failure = error;
	state.ready.reject(error);
	state.result.reject(error);
	state.armed.reject(error);
	state.fired.reject(error);
	state.collected.reject(error);
	for (const waiter of state.phaseWaiters.values()) waiter.reject(error);
	state.phaseWaiters.clear();
}
