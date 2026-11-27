import { parseArgs } from "node:util";
import {
	frameType,
	fromBase64,
	loadComboCorpus,
	makeJwt,
	messageType,
	type OpenTiming,
	probeStoreFrame,
	RawConnection,
	rebaseDocId,
	rebaseNamespace,
} from "./protocol";

const { values } = parseArgs({
	args: Bun.argv.slice(2),
	options: {
		port: { type: "string" },
		host: { type: "string", default: "127.0.0.1" },
		secret: { type: "string" },
		corpus: { type: "string" },
		processes: { type: "string" },
		shard: { type: "string", default: "0" },
		clients: { type: "string", default: "2500" },
	},
});

const port = Number(values.port);
const host = values.host;
const secret = values.secret ?? "";
const corpusPath = values.corpus;
const roleIndices =
	values.processes === undefined
		? []
		: values.processes
				.split(",")
				.map((part) => (part.trim() === "" ? Number.NaN : Number(part)));
const shard = Number(values.shard);
const clientsPerRole = Number(values.clients);

if (
	!Number.isInteger(port) ||
	!host ||
	!secret ||
	!corpusPath ||
	!Number.isInteger(shard) ||
	shard < 0 ||
	!Number.isInteger(clientsPerRole) ||
	clientsPerRole < 400 ||
	roleIndices.length < 1 ||
	roleIndices.length > 4 ||
	roleIndices.some(
		(index) => !Number.isInteger(index) || index < 0 || index >= 4,
	) ||
	new Set(roleIndices).size !== roleIndices.length
) {
	throw new Error("combo worker: invalid arguments");
}

// The captured presence frames are keyed by the original 2,500-client process
// topology; the client count may grow, but the corpus keys do not.
const corpusClientsPerProcess = 2500;

const corpus = loadComboCorpus(corpusPath);
const expectedSchema = fromBase64(corpus.schemaSync);
const storeNamespace =
	shard === 0
		? corpus.setup.storeNamespace
		: rebaseNamespace(corpus.setup.storeNamespace, `public-s${shard}`);
const presenceSubscribe = corpus.setup.presenceSubscribe;
const presenceSubscribeShared = corpus.setup.presenceSubscribeShared;

type Role = {
	processIndex: number;
	table: "items" | "events";
	room: number;
	presenceNamespace: string;
	sharedFrames: string[];
	createFrames: string[];
	updateFrames: string[];
	storeSubscribes: Record<"A" | "B", string>;
	base: number;
};

const roles: Role[] = [];
let connectionBase = 0;
for (const processIndex of roleIndices) {
	const table = processIndex % 2 === 0 ? "items" : "events";
	const room = processIndex < 2 ? 0 : 1;
	const presenceNamespace =
		shard === 0
			? corpus.setup.presenceNamespaces[String(room)]
			: rebaseNamespace(
					corpus.setup.presenceNamespaces[String(room)],
					`presence-combo-s${shard}-room-${room}`,
				);
	const createFrames = Array.from({ length: 100 }, (_, index) => {
		const frame = corpus.storeCreates[`${processIndex}:${index}`];
		if (!frame) throw new Error(`missing create ${processIndex}:${index}`);
		return rebaseDocId(frame, shard);
	});
	const updateFrames = Array.from({ length: 100 }, (_, index) => {
		const frame = corpus.storeUpdates[`${processIndex}:${index}`];
		if (!frame) throw new Error(`missing update ${processIndex}:${index}`);
		return rebaseDocId(frame, shard);
	});
	roles.push({
		processIndex,
		table,
		room,
		presenceNamespace,
		sharedFrames: corpus.presenceShared[String(room)],
		createFrames,
		updateFrames,
		storeSubscribes: corpus.setup.storeSubscribes[table],
		base: connectionBase,
	});
	connectionBase += clientsPerRole;
}
const totalClients = connectionBase;
const processIndex = roles[0].processIndex;
// 100k clients saturate the server's event loops; setup responses can take
// longer than RawConnection's 20 s default.
const setupTimeoutMs = 60_000;
const cpuStart = process.cpuUsage();

type Phase =
	| "store-create"
	| "store-update"
	| "presence-user"
	| "presence-shared"
	| "converge";

type LatencyHistogram = {
	buckets: number[];
	samples: number;
	overflow: number;
	maxMs: number;
};

// Probe subscribers record store-set arrival times relative to the phase start
// broadcast by the parent. 5 ms buckets keep the IPC report small.
const LATENCY_BUCKET_MS = 5;
const LATENCY_BUCKET_COUNT = 1000;
const latency = process.env.BENCH_LATENCY === "1";
const internal = process.env.BENCH_INTERNAL === "1";
const latencyByPhase: Record<string, LatencyHistogram> = {};
let latencyPhaseStartEpoch: number | null = null;
let latencyBuckets = new Uint32Array(LATENCY_BUCKET_COUNT);
let latencySamples = 0;
let latencyOverflow = 0;
let latencyMaxMs = 0;

function recordLatency(at: number): void {
	if (latencyPhaseStartEpoch === null) return;
	const ms = performance.timeOrigin + at - latencyPhaseStartEpoch;
	latencySamples++;
	if (ms > latencyMaxMs) latencyMaxMs = ms;
	const bucket = Math.floor(ms / LATENCY_BUCKET_MS);
	if (bucket >= 0 && bucket < LATENCY_BUCKET_COUNT) latencyBuckets[bucket]++;
	else latencyOverflow++;
}

function startLatencyPhase(startEpoch: number): void {
	latencyBuckets = new Uint32Array(LATENCY_BUCKET_COUNT);
	latencySamples = 0;
	latencyOverflow = 0;
	latencyMaxMs = 0;
	latencyPhaseStartEpoch = startEpoch;
}

function finishLatencyPhase(name: Phase): void {
	if (latencyPhaseStartEpoch === null) return;
	latencyByPhase[name] = {
		buckets: Array.from(latencyBuckets),
		samples: latencySamples,
		overflow: latencyOverflow,
		maxMs: latencyMaxMs,
	};
	latencyPhaseStartEpoch = null;
}

const connections: RawConnection[] = new Array<RawConnection>(totalClients);
const latencyProbes: RawConnection[] = [];
let framesTotal = 0;
let bytesTotal = 0;
const setupFail: Record<string, number> = {};
type StageStat = { count: number; totalMs: number; maxMs: number };
const setupStages: Record<string, StageStat> = {};
const pairAGaps: number[] = [];
const pairBGaps: number[] = [];
let pairASameFrame = 0;
let pairBSameFrame = 0;
let setupFramesTotal = 0;
let setupMessagesTotal = 0;
let setupConnections = 0;

function recordStage(name: string, ms: number): void {
	let stat = setupStages[name];
	if (!stat) {
		stat = { count: 0, totalMs: 0, maxMs: 0 };
		setupStages[name] = stat;
	}
	stat.count++;
	stat.totalMs += ms;
	stat.maxMs = Math.max(stat.maxMs, ms);
}

function noteSetup(stage: string, conn: RawConnection): void {
	if (frameType(conn.lastFrame) !== 0x00) {
		setupFail[stage] = (setupFail[stage] ?? 0) + 1;
	}
}

async function connectWithStoreScope(
	subject: string,
	countAcks: boolean,
	timing: OpenTiming,
): Promise<RawConnection> {
	let conn: RawConnection | null = null;
	try {
		conn = await RawConnection.open(
			host,
			port,
			makeJwt(secret, subject),
			expectedSchema,
			true,
			countAcks,
			timing,
			undefined,
			(n) => {
				framesTotal++;
				bytesTotal += n;
			},
			internal,
		);
		const namespaceStart = performance.now();
		conn.sendBase64(storeNamespace);
		await conn.waitFor(2, setupTimeoutMs);
		noteSetup("store-namespace", conn);
		recordStage("ticket", timing.ticketMs ?? 0);
		recordStage("ws", timing.wsMs ?? 0);
		recordStage("store-namespace", performance.now() - namespaceStart);
		return conn;
	} catch (error) {
		conn?.close();
		throw error;
	}
}

async function openLatencyProbe(
	role: Role,
	filter: "A" | "B",
): Promise<RawConnection> {
	const conn = await RawConnection.open(
		host,
		port,
		makeJwt(secret, `combo-latency-s${shard}-p${role.processIndex}-${filter}`),
		expectedSchema,
		false,
		false,
		undefined,
		(message, at) => {
			if (messageType(message) === 0x18) recordLatency(at);
		},
	);
	conn.sendBase64(storeNamespace);
	await conn.waitFor(2, setupTimeoutMs);
	conn.sendBase64(role.storeSubscribes[filter]);
	await conn.waitFor(3, setupTimeoutMs);
	return conn;
}

async function connectLocal(index: number): Promise<RawConnection> {
	const role = roles[Math.floor(index / clientsPerRole)];
	const localId = index % clientsPerRole;
	const subjectId = role.processIndex * clientsPerRole + localId;
	const subject =
		shard === 0
			? `combo-stress-${subjectId}`
			: `combo-stress-s${shard}-${subjectId}`;
	let lastError: unknown;
	for (let attempt = 0; attempt < 3; attempt++) {
		try {
			return await connectWithStoreScope(
				subject,
				localId < 200, // creators/updaters need write acks
				{},
			);
		} catch (error) {
			lastError = error;
			if (attempt < 2) await Bun.sleep(50);
		}
	}
	if (lastError instanceof Error) throw lastError;
	throw new Error(String(lastError));
}

try {
	const setupOnly = process.env.COMBO_SETUP_ONLY === "1";

	// Open probes before the client load. At 100k clients a probe opened after
	// setup can miss its 20 s schema-frame deadline while the server is busy.
	if (latency && !setupOnly) {
		for (const role of roles) {
			const [filterA, filterB] = await Promise.all([
				openLatencyProbe(role, "A"),
				openLatencyProbe(role, "B"),
			]);
			latencyProbes.push(filterA, filterB);
		}
	}

	// Match the e2e connect phase: clients connect concurrently, store scope
	// handshake included, 500 in flight. Keep the index stable.
	let next = 0;
	let failure: Error | null = null;
	const connector = async () => {
		while (failure === null) {
			const index = next++;
			if (index >= totalClients) return;
			try {
				connections[index] = await connectLocal(index);
			} catch (error) {
				const reason = error instanceof Error ? error.message : String(error);
				failure = new Error(`connect index=${index}: ${reason}`);
			}
		}
	};
	await Promise.all(Array.from({ length: 500 }, connector));
	if (failure) throw failure;

	// Match the client setup pipeline: the store subscription and presence
	// namespace are sent together; the two presence subscriptions are sent
	// together once the presence scope is ready. Wait on messages, not frames,
	// because the server may coalesce setup responses.
	if (!setupOnly)
		await Promise.all(
			connections.map(async (conn, index) => {
				const role = roles[Math.floor(index / clientsPerRole)];
				const localId = index % clientsPerRole;
				const filter = localId < clientsPerRole / 2 ? "A" : "B";
				let stageStart = performance.now();
				conn.sendBase64(role.storeSubscribes[filter]);
				conn.sendBase64(role.presenceNamespace);
				await conn.waitForMessages(4, setupTimeoutMs);
				recordStage("store-sub+presence-ns", performance.now() - stageStart);

				stageStart = performance.now();
				conn.sendBase64(presenceSubscribe);
				conn.sendBase64(presenceSubscribeShared);
				await conn.waitForMessages(6, setupTimeoutMs);
				recordStage("presence-subs", performance.now() - stageStart);

				const storeSubAt = conn.messageTimes.get(2);
				const presenceNsAt = conn.messageTimes.get(3);
				if (storeSubAt !== undefined && presenceNsAt !== undefined) {
					pairAGaps.push(Math.abs(presenceNsAt - storeSubAt));
					if (conn.messageFrames.get(2) === conn.messageFrames.get(3)) {
						pairASameFrame++;
					}
				}
				const presenceSubAt = conn.messageTimes.get(4);
				const sharedAt = conn.messageTimes.get(5);
				if (presenceSubAt !== undefined && sharedAt !== undefined) {
					pairBGaps.push(Math.abs(sharedAt - presenceSubAt));
					if (conn.messageFrames.get(4) === conn.messageFrames.get(5)) {
						pairBSameFrame++;
					}
				}
				setupFramesTotal += conn.frames;
				setupMessagesTotal += conn.messages;
				setupConnections++;

				if (conn.errors > 0) {
					setupFail.subscriptions = (setupFail.subscriptions ?? 0) + 1;
				}
				conn.countMessages = false;
				// Acks are only needed while a write is in flight; decoding every
				// later fanout frame just to count acks burns generator CPU.
				conn.countAcks = false;
			}),
		);
} catch (error) {
	process.send?.({
		type: "error",
		message: error instanceof Error ? error.message : String(error),
	});
	throw error;
}

const failedSetup = Object.entries(setupFail).filter(([, count]) => count > 0);
if (failedSetup.length > 0) {
	const message = `setup failures: ${failedSetup
		.map(([stage, count]) => `${stage}=${count}`)
		.join(", ")}`;
	process.send?.({ type: "error", message });
	throw new Error(message);
}

const setupCpu = process.cpuUsage(cpuStart);
process.send?.({
	type: "ready",
	process: processIndex,
	connections: connections.length,
	cpuMs: (setupCpu.user + setupCpu.system) / 1000,
	stages: setupStages,
	pairAGaps,
	pairBGaps,
	pairASameFrame,
	pairBSameFrame,
	setupFramesTotal,
	setupMessagesTotal,
	setupConnections,
});

function phaseCreates(): Promise<void> {
	return Promise.all(
		roles.flatMap((role) =>
			role.createFrames.map(async (frame, idx) => {
				const conn = connections[role.base + idx];
				const target = conn.acks + 1;
				conn.countAcks = true;
				conn.sendBase64(frame);
				await conn.waitForAcks(target, setupTimeoutMs);
				conn.countAcks = false;
			}),
		),
	).then(() => {});
}

function phaseUpdates(): Promise<void> {
	return Promise.all(
		roles.flatMap((role) =>
			role.updateFrames.map(async (frame, idx) => {
				const conn = connections[role.base + 100 + idx];
				const target = conn.acks + 1;
				conn.countAcks = true;
				conn.sendBase64(frame);
				await conn.waitForAcks(target, setupTimeoutMs);
				conn.countAcks = false;
			}),
		),
	).then(() => {});
}

async function phasePresenceUser(): Promise<void> {
	for (let tick = 0; tick < 3; tick++) {
		for (const role of roles) {
			for (let i = 0; i < 100; i++) {
				const localId = 200 + i;
				const conn = connections[role.base + localId];
				const globalId = role.processIndex * corpusClientsPerProcess + localId;
				const frames = corpus.presenceUser[String(globalId)];
				if (!frames) throw new Error(`missing presence user ${globalId}`);
				conn.sendBase64(frames[tick]);
			}
		}
		if (tick < 2) await Bun.sleep(25);
	}
}

async function phasePresenceShared(): Promise<void> {
	for (let tick = 0; tick < 3; tick++) {
		for (const role of roles) {
			for (let i = 0; i < 100; i++) {
				connections[role.base + 300 + i].sendBase64(role.sharedFrames[tick]);
			}
		}
		if (tick < 2) await Bun.sleep(25);
	}
}

function totalFrames(): number {
	return framesTotal;
}

function totalBytes(): number {
	return bytesTotal;
}

function countClosed(): number {
	let closed = 0;
	for (const conn of connections) if (conn.closed) closed++;
	return closed;
}

let probeFramesBefore = 0;
let probeSubscriberFramesBefore = 0;
let workloadFrames = -1;
let workloadBytes = -1;

async function fireProbe(): Promise<void> {
	const role = roles[0];
	const writer = connections[role.base];
	const target = writer.acks + 1;
	writer.countAcks = true;
	writer.sendBase64(
		probeStoreFrame(role.createFrames[0], `probe-${process.pid}-${Date.now()}`),
	);
	await writer.waitForAcks(target, setupTimeoutMs);
	writer.countAcks = false;
}

async function phaseConverge(): Promise<void> {
	let last = totalFrames();
	let quietMs = 0;
	while (quietMs < 100) {
		await Bun.sleep(10);
		const current = totalFrames();
		if (current === last) quietMs += 10;
		else {
			last = current;
			quietMs = 0;
		}
	}
}

const phaseFrames: Record<string, number> = {};

async function runPhase(phase: Phase): Promise<void> {
	const before = totalFrames();
	switch (phase) {
		case "store-create":
			await phaseCreates();
			break;
		case "store-update":
			await phaseUpdates();
			break;
		case "presence-user":
			await phasePresenceUser();
			break;
		case "presence-shared":
			await phasePresenceShared();
			break;
		case "converge":
			await phaseConverge();
			break;
	}
	phaseFrames[phase] = totalFrames() - before;
}

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: flat message dispatch
process.on("message", (message: unknown) => {
	if (!message || typeof message !== "object") return;
	const record = message as {
		type?: string;
		phase?: Phase;
		startEpoch?: number;
	};
	if (record.type === "phase" && record.phase) {
		const phase = record.phase;
		const phaseCpuStart = process.cpuUsage();
		startLatencyPhase(record.startEpoch ?? 0);
		runPhase(phase)
			.then(() => {
				finishLatencyPhase(phase);
				const phaseCpu = process.cpuUsage(phaseCpuStart);
				process.send?.({
					type: "phase-done",
					process: processIndex,
					shard,
					phase,
					cpuMs: (phaseCpu.user + phaseCpu.system) / 1000,
				});
			})
			.catch((error: unknown) => {
				process.send?.({
					type: "error",
					message: error instanceof Error ? error.message : String(error),
				});
			});
	}
	if (record.type === "probe-arm") {
		workloadFrames = totalFrames();
		workloadBytes = totalBytes();
		probeFramesBefore = workloadFrames;
		// Filter B matches createFrames[0]; the last client is filter B and is
		// not the writer.
		probeSubscriberFramesBefore =
			connections[roles[0].base + clientsPerRole - 1].frames;
		process.send?.({ type: "probe-armed", shard, process: processIndex });
	}
	if (record.type === "probe-fire") {
		fireProbe()
			.then(() => process.send?.({ type: "probe-fired" }))
			.catch((error: unknown) => {
				process.send?.({
					type: "error",
					message: error instanceof Error ? error.message : String(error),
				});
			});
	}
	if (record.type === "probe-collect") {
		process.send?.({
			type: "probe-collected",
			shard,
			process: processIndex,
			framesBefore: probeFramesBefore,
			framesAfter: totalFrames(),
			subscriberFrames:
				connections[roles[0].base + clientsPerRole - 1].frames -
				probeSubscriberFramesBefore,
		});
	}
	if (record.type === "cleanup") {
		const closed = countClosed();
		for (const conn of connections) conn.close();
		const cpu = process.cpuUsage(cpuStart);
		process.send?.({
			type: "result",
			process: processIndex,
			shard,
			connections: connections.length,
			closed,
			phaseFrames,
			frames: workloadFrames >= 0 ? workloadFrames : totalFrames(),
			bytes: workloadBytes >= 0 ? workloadBytes : totalBytes(),
			setupFail,
			latency: latencyByPhase,
			cpuMs: (cpu.user + cpu.system) / 1000,
		});
		if (process.env.ZYNCBASE_COMBO_PROFILE_DIR) {
			// Let Bun flush the CPU profile before the parent tears the worker down.
			setTimeout(() => process.exit(0), 100);
		}
	}
});
