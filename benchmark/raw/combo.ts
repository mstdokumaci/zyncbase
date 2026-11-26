import * as fs from "node:fs";
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

// The corpus is captured for 2,500 clients per process and embeds their
// connection/global ids; only the shard count may vary.
const clientsPerProcess = 2500;
const shards = Number(values.shards);
const root = path.resolve(import.meta.dir, "../..");
const corpusPath = path.resolve(root, values.corpus);
const processesPerShard = 4;
const processCount = processesPerShard * shards;

if (!Number.isInteger(shards) || shards < 1) {
	throw new Error("combo: invalid --shards");
}

type WorkerResult = {
	cpuMs: number;
	connections: number;
	closed: number;
	frames: number;
	bytes: number;
	phaseFrames: Record<string, number>;
	setupFail: Record<string, number>;
	shard: number;
};

type WorkerState = {
	global: number;
	shard: number;
	local: number;
	proc: Bun.Subprocess;
	stopping: boolean;
	ready: PromiseWithResolvers<void>;
	armed: PromiseWithResolvers<void>;
	fired: PromiseWithResolvers<void>;
	collected: PromiseWithResolvers<{
		framesBefore: number;
		framesAfter: number;
	}>;
	result: PromiseWithResolvers<WorkerResult>;
	phaseWaiters: Map<
		string,
		{ resolve: () => void; reject: (error: Error) => void }
	>;
};

buildServerIfNeeded();
const ctx = await createE2ETestContext(`raw-combo-${shards}shard`);

await withServer(
	ctx,
	{
		schemaPath: ctx.schemaPath("schema-combo-stress.json"),
		dataDir: ctx.dataPath(`combo-${shards}shard`),
		configName: "zyncbase-config-combo.json",
		authPath: ctx.schemaPath("auth-allow-all.json"),
		jwtSecret: PRESENCE_E2E_JWT_SECRET,
		idleTimeoutSeconds: 239,
	},
	async (server) => {
		const started = performance.now();
		const serverCpuStart = processCpuSeconds(server.process.pid);
		const workers: WorkerState[] = [];

		for (let global = 0; global < processCount; global++) {
			const shard = Math.floor(global / processesPerShard);
			const local = global % processesPerShard;
			// Each shard uses its own loopback destination IP: one listener, but
			// separate source-port tuple spaces so 50k localhost sockets do not
			// exhaust the ephemeral port range.
			const host = shards === 1 ? "127.0.0.1" : `127.0.0.${shard + 1}`;
			let state: WorkerState | null = null;
			const proc = Bun.spawn(
				[
					process.execPath,
					path.join(root, "benchmark/raw/combo-worker.ts"),
					"--port",
					String(server.port),
					"--host",
					host,
					"--secret",
					PRESENCE_E2E_JWT_SECRET,
					"--corpus",
					corpusPath,
					"--process",
					String(local),
					"--shard",
					String(shard),
					"--clients",
					String(clientsPerProcess),
				],
				{
					cwd: root,
					stdio: ["ignore", "inherit", "inherit"],
					ipc: (message) => {
						if (state) handleMessage(state, message);
					},
				},
			);
			const ready = Promise.withResolvers<void>();
			const armed = Promise.withResolvers<void>();
			const fired = Promise.withResolvers<void>();
			const collected = Promise.withResolvers<{
				framesBefore: number;
				framesAfter: number;
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
				ready,
				armed,
				fired,
				collected,
				result,
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

			const phase = async (name: string): Promise<number> => {
				const start = performance.now();
				const done = workers.map(
					(worker) =>
						new Promise<void>((resolve, reject) => {
							worker.phaseWaiters.set(name, { resolve, reject });
						}),
				);
				for (const worker of workers) {
					worker.proc.send({ type: "phase", phase: name });
				}
				await Promise.all(done);
				return performance.now() - start;
			};

			const createMs = await phase("store-create");
			const updateMs = await phase("store-update");
			const presenceUserMs = await phase("presence-user");
			const presenceSharedMs = await phase("presence-shared");
			const convergeMs = await phase("converge");
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
			const totalMs = performance.now() - started - isolationMs;
			const cleanupMs = totalMs - workloadMs;
			const cpuTotal = results.reduce((sum, r) => sum + r.cpuMs, 0) / 1000;
			const cpuMax = Math.max(...results.map((r) => r.cpuMs)) / 1000;
			const serverCpu = processCpuSeconds(server.process.pid) - serverCpuStart;
			const serverCores = serverCpu / ((totalMs + isolationMs) / 1000);

			console.log(
				`\nraw combo passed: ${processCount * clientsPerProcess} clients across ${processCount} processes` +
					(shards > 1 ? ` (${shards} isolated shards)` : "") +
					` in ${Math.round(totalMs)}ms`,
			);
			console.log(
				`  phases ms: setup=${Math.round(setupMs)}, ` +
					`store-create=${Math.round(createMs)}, store-update=${Math.round(updateMs)}, ` +
					`presence-user=${Math.round(presenceUserMs)}, presence-shared=${Math.round(presenceSharedMs)}, ` +
					`converge=${Math.round(convergeMs)}, ` +
					(shards > 1 ? `isolation=${Math.round(isolationMs)}, ` : "") +
					`cleanup=${Math.round(cleanupMs)}`,
			);
			console.log(
				`  client cpu: total=${cpuTotal.toFixed(2)}s, max=${cpuMax.toFixed(2)}s; ` +
					`server cpu=${serverCpu.toFixed(2)}s (${serverCores.toFixed(2)} cores); ` +
					`connections=${results.reduce((sum, r) => sum + r.connections, 0)}`,
			);
			reportShards(workers, results, clientsPerProcess);
		} finally {
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

function reportShards(
	workers: WorkerState[],
	results: WorkerResult[],
	clientsPerProcess: number,
): void {
	const shardCount = Math.max(...workers.map((worker) => worker.shard)) + 1;
	for (let shard = 0; shard < shardCount; shard++) {
		const members = results.filter((r) => r.shard === shard);
		const frames = members.reduce((sum, r) => sum + r.frames, 0);
		const bytes = members.reduce((sum, r) => sum + r.bytes, 0);
		const cpu = members.reduce((sum, r) => sum + r.cpuMs, 0) / 1000;
		console.log(
			`  shard ${shard}: clients=${members.length * clientsPerProcess}, ` +
				`closed=${members.reduce((sum, r) => sum + r.closed, 0)}, ` +
				`frames=${frames}, bytes=${(bytes / 1e6).toFixed(1)}MB, cpu=${cpu.toFixed(2)}s`,
		);
		const phaseSum = (name: string) =>
			members.reduce((sum, r) => sum + (r.phaseFrames[name] ?? 0), 0);
		console.log(
			`    phases: create=${phaseSum("store-create")}, update=${phaseSum("store-update")}, ` +
				`presence-user=${phaseSum("presence-user")}, presence-shared=${phaseSum("presence-shared")}, ` +
				`converge=${phaseSum("converge")}`,
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
	if (shardZero <= 0) {
		throw new Error("isolation probe: shard 0 saw no probe fanout");
	}
	for (const [shard, frames] of perShard) {
		if (shard !== 0 && frames !== 0) {
			throw new Error(
				`isolation probe: shard ${shard} saw ${frames} cross-shard frames`,
			);
		}
	}
	console.log(
		`  isolation: shard 0 fanout=${shardZero} frames; other shards 0`,
	);
}

type WorkerMessage = {
	type?: string;
	phase?: string;
	message?: string;
	framesBefore?: number;
	framesAfter?: number;
	cpuMs?: number;
	connections?: number;
	closed?: number;
	frames?: number;
	bytes?: number;
	shard?: number;
	phaseFrames?: Record<string, number>;
	setupFail?: Record<string, number>;
};

function handleMessage(state: WorkerState, message: unknown): void {
	if (!message || typeof message !== "object") return;
	const record = message as WorkerMessage;
	if (handleProbeMessage(state, record)) return;
	switch (record.type) {
		case "ready":
			state.ready.resolve();
			break;
		case "phase-done":
			if (record.phase) {
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
			});
			return true;
		default:
			return false;
	}
}

function fail(state: WorkerState, error: Error): void {
	state.ready.reject(error);
	state.result.reject(error);
	state.armed.reject(error);
	state.fired.reject(error);
	state.collected.reject(error);
	for (const waiter of state.phaseWaiters.values()) waiter.reject(error);
	state.phaseWaiters.clear();
}
