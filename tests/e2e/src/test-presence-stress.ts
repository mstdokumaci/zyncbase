import {
	createClient,
	type PresenceEntry,
	type ZyncBaseClient,
} from "@zyncbase/client";
import { createTestJwt } from "./harness";

function envInt(name: string, fallback: number, min = 1): number {
	const raw = process.env[name];
	if (raw === undefined || raw === "") return fallback;
	const value = Number(raw);
	if (!Number.isInteger(value) || value < min) {
		throw new Error(`${name} must be an integer >= ${min}, got ${raw}`);
	}
	return value;
}

const ROOM_COUNT = 2;
const PROCESSES_PER_ROOM = 2;
const CLIENTS_PER_PROCESS = envInt(
	"ZYNCBASE_PRESENCE_CLIENTS_PER_PROCESS",
	500,
);
const CLIENTS_PER_ROOM = PROCESSES_PER_ROOM * CLIENTS_PER_PROCESS;
const PROCESS_COUNT = ROOM_COUNT * PROCESSES_PER_ROOM;
const TOTAL_CLIENTS = PROCESS_COUNT * CLIENTS_PER_PROCESS;
const CONNECT_CONCURRENCY = envInt(
	"ZYNCBASE_PRESENCE_CONNECT_CONCURRENCY",
	100,
);
const PROCESS_MUTATION_STAGGER_MS = envInt(
	"ZYNCBASE_PRESENCE_MUTATION_STAGGER_MS",
	50,
	0,
);

const CURSOR_GROUP_SIZE = 10;
const FIRST_CURSOR_TICKS = 40;
const SECOND_CURSOR_TICKS = 80;
const CURSOR_INTERVAL_MS = 8;

const SHARED_INTERVAL_MS = 20;

const QUIET_WINDOW_MS = envInt("ZYNCBASE_PRESENCE_QUIET_WINDOW_MS", 25, 0);
const VERIFY_RETRY_INTERVAL_MS = envInt(
	"ZYNCBASE_PRESENCE_VERIFY_RETRY_MS",
	250,
	0,
);
const VERIFY_SAMPLE_STRIDE = envInt("ZYNCBASE_PRESENCE_VERIFY_STRIDE", 2);
const CONVERGENCE_TIMEOUT_MS = 20_000;
const CONNECT_TIMEOUT_MS = 45_000;
const PRESENCE_NAMESPACE_PREFIX = "presence-stress";
const NAME_PREFIX = "client-";
const EXPECTED_NAMES = Array.from(
	{ length: TOTAL_CLIENTS },
	(_, globalId) => `${NAME_PREFIX}${globalId}`,
);

const BARRIER_PHASES = [
	"ready",
	"join",
	"cursor",
	"shared-before-remove",
	"remove",
	"rejoin",
	"shared-after-rejoin",
	"disconnect",
] as const;

type BarrierPhase = (typeof BARRIER_PHASES)[number];

type ClientState = {
	client: ZyncBaseClient;
	globalId: number;
	userReady: boolean;
	sharedReady: boolean;
	ready: boolean;
	userCallbacks: number;
	sharedCallbacks: number;
	viewRevision: number;
	scannedEpoch: number;
	scannedRevision: number;
	scannedExpectedCount: number;
	cachedScanFailure: string | null;
	sharedRevision: number;
	sharedScannedRevision: number;
	sharedScannedRound: number;
	cachedSharedFailure: string | null;
	disconnected: boolean;
	expectedDisconnect: boolean;
};

type ProcessContext = {
	processIndex: number;
	roomIndex: number;
	clients: ClientState[];
	generation: number;
	verifyEpoch: number;
	lastChangeMs: number;
	errorCount: number;
	errorSamples: string[];
	downClients: Set<ClientState>;
	readyCount: number;
	readyWaiters: Array<{
		resolve: () => void;
		reject: (error: Error) => void;
	}>;
	verifyMs: number;
	verifyPasses: number;
};

type ProcessMetrics = {
	processIndex: number;
	clientCreateMs: number;
	connectMs: number;
	connectOnlyMs: number;
	subscribeMs: number;
	readinessMs: number;
	cleanupMs: number;
	barrierWaitMs: Partial<Record<BarrierPhase, number>>;
	joinMs: number;
	cursorWriteMs: number;
	cursorConvergeMs: number;
	sharedWriteMs: number;
	sharedConvergeMs: number;
	removeMs: number;
	rejoinMs: number;
	disconnectMs: number;
	verifyMs: number;
	verifyPasses: number;
	userCallbacks: number[];
	sharedCallbacks: number[];
};

type WorkerResultMessage = {
	type: "result";
	processIndex: number;
	result: ProcessMetrics;
};

type ParentContinueMessage = {
	type: "continue";
	phase: BarrierPhase;
};

type BarrierWaiter = ReturnType<typeof Promise.withResolvers<void>>;

function delay(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

async function withTimeout<T>(
	promise: Promise<T>,
	timeoutMs: number,
	label: string,
): Promise<T> {
	let timer: ReturnType<typeof setTimeout> | undefined;
	try {
		return await Promise.race([
			promise,
			new Promise<never>((_resolve, reject) => {
				timer = setTimeout(
					() => reject(new Error(`${label} timed out after ${timeoutMs}ms`)),
					timeoutMs,
				);
			}),
		]);
	} finally {
		if (timer !== undefined) clearTimeout(timer);
	}
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function formatError(error: unknown): string {
	if (error instanceof Error) return error.message;
	if (isRecord(error)) {
		const code = typeof error.code === "string" ? `${error.code}: ` : "";
		if (typeof error.message === "string") return `${code}${error.message}`;
	}
	return String(error);
}

function failReadiness(context: ProcessContext, message: string): void {
	const error = new Error(`[process ${context.processIndex}] ${message}`);
	for (const waiter of context.readyWaiters.splice(0)) waiter.reject(error);
}

function markClientReady(context: ProcessContext, state: ClientState): void {
	if (state.ready || !state.userReady || !state.sharedReady) return;
	state.ready = true;
	context.readyCount++;
	if (context.readyCount >= context.clients.length) {
		for (const waiter of context.readyWaiters.splice(0)) waiter.resolve();
	}
}

function makeClientState(
	context: ProcessContext,
	port: number,
	jwtSecret: string,
	localId: number,
): ClientState {
	const globalId = context.processIndex * CLIENTS_PER_PROCESS + localId;
	const client = createClient({
		url: `ws://127.0.0.1:${port}/v1/ws`,
		auth: {
			token: createTestJwt(jwtSecret, `presence-stress-${globalId}`),
		},
		presenceNamespace: `${PRESENCE_NAMESPACE_PREFIX}-${context.roomIndex}`,
		retryRateLimits: false,
		liveness: { enabled: false },
	});
	const state: ClientState = {
		client,
		globalId,
		userReady: false,
		sharedReady: false,
		ready: false,
		userCallbacks: 0,
		sharedCallbacks: 0,
		viewRevision: 0,
		scannedEpoch: -1,
		scannedRevision: -1,
		scannedExpectedCount: -1,
		cachedScanFailure: null,
		sharedRevision: 0,
		sharedScannedRevision: -1,
		sharedScannedRound: -1,
		cachedSharedFailure: null,
		disconnected: false,
		expectedDisconnect: false,
	};

	client.on("error", (error) => {
		if (state.expectedDisconnect && formatError(error) === "Disconnected")
			return;
		context.errorCount++;
		const sample = `client ${globalId}: ${formatError(error)}`;
		if (context.errorSamples.length < 3) context.errorSamples.push(sample);
		failReadiness(context, sample);
	});
	client.on("disconnected", () => {
		state.disconnected = true;
		if (!state.expectedDisconnect) {
			context.downClients.add(state);
			if (!state.ready) {
				failReadiness(
					context,
					`client ${globalId} disconnected before readiness`,
				);
			}
		}
	});
	client.on("connected", () => {
		state.disconnected = false;
		context.downClients.delete(state);
	});

	return state;
}

function healthIssue(context: ProcessContext): string | null {
	if (context.errorCount > 0) {
		return `${context.errorCount} client error(s): ${context.errorSamples.join("; ")}`;
	}
	for (const state of context.downClients) {
		if (!state.expectedDisconnect && state.disconnected) {
			return `client ${state.globalId} disconnected unexpectedly`;
		}
	}
	return null;
}

async function waitForReadiness(context: ProcessContext): Promise<void> {
	const issue = healthIssue(context);
	if (issue) throw new Error(`[process ${context.processIndex}] ${issue}`);
	if (context.readyCount >= context.clients.length) return;
	await new Promise<void>((resolve, reject) => {
		context.readyWaiters.push({ resolve, reject });
	});
}

async function connectClient(state: ClientState): Promise<void> {
	try {
		await state.client.connect();
	} catch (error) {
		throw new Error(
			`client ${state.globalId} failed to connect: ${formatError(error)}`,
		);
	}
}

async function connectClientsWithConcurrency(
	clients: ClientState[],
	limit: number,
): Promise<void> {
	let next = 0;
	let failure: Error | null = null;
	const worker = async (): Promise<void> => {
		while (failure === null) {
			const index = next++;
			if (index >= clients.length) return;
			try {
				await connectClient(clients[index]);
			} catch (error) {
				failure = error instanceof Error ? error : new Error(String(error));
			}
		}
	};
	await Promise.all(
		Array.from({ length: Math.min(limit, clients.length) }, worker),
	);
	if (failure) throw failure;
}

type PreparationMetrics = {
	clientCreateMs: number;
	connectOnlyMs: number;
	subscribeMs: number;
	readinessMs: number;
};

async function subscribeClient(
	context: ProcessContext,
	state: ClientState,
): Promise<void> {
	await Promise.all([
		state.client.presence.subscribe(() => {
			state.userCallbacks++;
			state.viewRevision++;
			state.userReady = true;
			context.generation++;
			context.lastChangeMs = performance.now();
			markClientReady(context, state);
		}),
		state.client.presence.subscribeShared(() => {
			state.sharedCallbacks++;
			state.viewRevision++;
			state.sharedRevision++;
			state.sharedReady = true;
			context.generation++;
			context.lastChangeMs = performance.now();
			markClientReady(context, state);
		}),
	]);
}

async function prepareClients(
	context: ProcessContext,
	port: number,
	jwtSecret: string,
): Promise<PreparationMetrics> {
	const preparation: PreparationMetrics = {
		clientCreateMs: 0,
		connectOnlyMs: 0,
		subscribeMs: 0,
		readinessMs: 0,
	};

	await withTimeout(
		(async () => {
			const createStart = performance.now();
			for (let localId = 0; localId < CLIENTS_PER_PROCESS; localId++) {
				context.clients.push(
					makeClientState(context, port, jwtSecret, localId),
				);
			}
			preparation.clientCreateMs = performance.now() - createStart;

			const connectStart = performance.now();
			await connectClientsWithConcurrency(context.clients, CONNECT_CONCURRENCY);
			preparation.connectOnlyMs = performance.now() - connectStart;

			const subscribeStart = performance.now();
			await Promise.all(
				context.clients.map((state) => subscribeClient(context, state)),
			);
			preparation.subscribeMs = performance.now() - subscribeStart;

			const readinessStart = performance.now();
			await waitForReadiness(context);
			preparation.readinessMs = performance.now() - readinessStart;
		})(),
		CONNECT_TIMEOUT_MS,
		`process ${context.processIndex} connection and subscription readiness`,
	);

	return preparation;
}

type EntryScan = {
	/** Generation-stamped seen-set shared across scans; read it only against `generation`. */
	seen: Uint32Array;
	generation: number;
	samples: string[];
	invalid: number;
	duplicate: number;
	extra: number;
	stale: number;
};

function addSample(scan: EntryScan, message: string) {
	if (scan.samples.length < 5) scan.samples.push(message);
}

const scanSeenScratch = new Uint32Array(TOTAL_CLIENTS);
let scanGeneration = 0;

/** One pass over an observer's entries: identity, duplicate, extra and data checks. Kept fused to avoid per-entry call overhead in the hot verify loop. */
function scanEntries(
	entries: PresenceEntry[],
	active: Uint8Array,
	expectedY: Int32Array,
): EntryScan {
	const seen = scanSeenScratch;
	// Wrapping back to 0 is harmless: a stale stamp only has to differ from
	// the current generation, and wrap-around needs 2^32 scans to collide.
	scanGeneration = (scanGeneration + 1) >>> 0;
	const generation = scanGeneration;
	const scan: EntryScan = {
		seen,
		generation,
		samples: [],
		invalid: 0,
		duplicate: 0,
		extra: 0,
		stale: 0,
	};

	for (let i = 0; i < entries.length; i++) {
		const entry = entries[i];
		const data = entry.data;
		const cursor = data.cursor;
		if (!isRecord(cursor)) {
			scan.invalid++;
			addSample(scan, `invalid cursor identity ${String(cursor)}`);
			continue;
		}
		const globalId = cursor.x;
		if (
			typeof globalId !== "number" ||
			!Number.isInteger(globalId) ||
			globalId < 0 ||
			globalId >= TOTAL_CLIENTS
		) {
			scan.invalid++;
			addSample(scan, `invalid cursor identity ${String(cursor)}`);
			continue;
		}

		if (seen[globalId] === generation) {
			scan.duplicate++;
			addSample(scan, `duplicate ${globalId}`);
		} else {
			seen[globalId] = generation;
		}
		if (active[globalId] === 0) {
			scan.extra++;
			addSample(scan, `extra ${globalId}`);
		}
		if (
			data.name !== EXPECTED_NAMES[globalId] ||
			data.status !== "active" ||
			cursor.y !== expectedY[globalId] ||
			typeof entry.userId !== "string" ||
			entry.userId.length === 0 ||
			!Number.isFinite(entry.joinedAt) ||
			entry.joinedAt <= 0
		) {
			scan.stale++;
			addSample(scan, `stale ${globalId}`);
		}
	}
	return scan;
}

function countMissing(
	context: ProcessContext,
	active: Uint8Array,
	scan: EntryScan,
): number {
	const firstClient = context.roomIndex * CLIENTS_PER_ROOM;
	const end = firstClient + CLIENTS_PER_ROOM;
	let missing = 0;
	for (let globalId = firstClient; globalId < end; globalId++) {
		if (active[globalId] === 1 && scan.seen[globalId] !== scan.generation) {
			missing++;
			addSample(scan, `missing ${globalId}`);
		}
	}
	return missing;
}

function verifyObserver(
	context: ProcessContext,
	state: ClientState,
	active: Uint8Array,
	expectedCount: number,
	expectedY: Int32Array,
): string | null {
	if (
		state.scannedEpoch === context.verifyEpoch &&
		state.scannedRevision === state.viewRevision &&
		state.scannedExpectedCount === expectedCount &&
		state.cachedScanFailure === null
	) {
		return null;
	}

	const entries = state.client.presence.getAll({ includeSelf: true });
	const scan = scanEntries(entries, active, expectedY);
	const missing = countMissing(context, active, scan);
	let failure: string | null = null;
	if (
		entries.length !== expectedCount ||
		scan.invalid !== 0 ||
		scan.duplicate !== 0 ||
		scan.extra !== 0 ||
		scan.stale !== 0 ||
		missing !== 0
	) {
		failure =
			`observer ${state.globalId}: expected ${expectedCount}, got ${entries.length}; ` +
			`missing=${missing}, extra=${scan.extra}, duplicate=${scan.duplicate}, invalid=${scan.invalid}, stale=${scan.stale}` +
			(scan.samples.length > 0 ? ` (${scan.samples.join(", ")})` : "");
	}

	state.scannedEpoch = context.verifyEpoch;
	state.scannedRevision = state.viewRevision;
	state.scannedExpectedCount = expectedCount;
	state.cachedScanFailure = failure;
	return failure;
}

function verifyUsers(
	context: ProcessContext,
	active: Uint8Array,
	expectedCount: number,
	expectedY: Int32Array,
	stride = VERIFY_SAMPLE_STRIDE,
): string | null {
	const failures: string[] = [];
	for (let i = 0; i < context.clients.length; i += stride) {
		const state = context.clients[i];
		if (state.expectedDisconnect) continue;
		const failure = verifyObserver(
			context,
			state,
			active,
			expectedCount,
			expectedY,
		);
		if (failure) failures.push(failure);
		if (failures.length === 5) break;
	}
	return failures.length === 0 ? null : failures.join(" | ");
}

function verifyFullJoinSelfFilter(context: ProcessContext): string | null {
	for (const state of context.clients) {
		const all = state.client.presence.getAll({ includeSelf: true });
		const others = state.client.presence.getAll();
		const ownName = EXPECTED_NAMES[state.globalId];
		if (
			all.length !== CLIENTS_PER_ROOM ||
			others.length !== CLIENTS_PER_ROOM - 1 ||
			!all.some((entry) => entry.data.name === ownName) ||
			others.some((entry) => entry.data.name === ownName)
		) {
			return `observer ${state.globalId}: self filter expected ${CLIENTS_PER_ROOM}/${CLIENTS_PER_ROOM - 1} include/default entries and own marker only in include-self view; got ${all.length}/${others.length}`;
		}
	}
	return null;
}

function sharedState(context: ProcessContext, round: number) {
	return {
		slide: context.roomIndex * 100 + round,
		playing: round % 2 === 1,
	};
}

function verifyShared(context: ProcessContext, round: number): string | null {
	const expected = sharedState(context, round);
	for (const state of context.clients) {
		if (state.expectedDisconnect) continue;
		if (
			state.sharedScannedRevision === state.sharedRevision &&
			state.sharedScannedRound === round &&
			state.cachedSharedFailure === null
		) {
			continue;
		}

		const shared = state.client.presence.getShared();
		let failure: string | null = null;
		if (
			shared === null ||
			Object.keys(shared).length !== 2 ||
			shared.slide !== expected.slide ||
			shared.playing !== expected.playing
		) {
			failure = `observer ${state.globalId}: expected shared slide=${expected.slide}, playing=${expected.playing}; got ${JSON.stringify(shared)}`;
		}

		state.sharedScannedRevision = state.sharedRevision;
		state.sharedScannedRound = round;
		state.cachedSharedFailure = failure;
		if (failure) return failure;
	}
	return null;
}

type GenerationState = {
	lastGeneration: number;
	lastChanged: number;
	lastVerified: number;
};

function observeGeneration(
	context: ProcessContext,
	state: GenerationState,
): boolean {
	if (context.generation === state.lastGeneration) return false;
	state.lastGeneration = context.generation;
	state.lastChanged = performance.now();
	state.lastVerified = 0;
	return true;
}

function assertHealthy(context: ProcessContext, label: string) {
	const issue = healthIssue(context);
	if (issue) {
		throw new Error(`[process ${context.processIndex}] ${label}: ${issue}`);
	}
}

function shouldWaitForQuiet(
	context: ProcessContext,
	state: GenerationState,
	now: number,
): boolean {
	if (observeGeneration(context, state)) return true;
	if (now - state.lastChanged < QUIET_WINDOW_MS) return true;
	return now - state.lastVerified < VERIFY_RETRY_INTERVAL_MS;
}

async function waitForConvergence(
	context: ProcessContext,
	label: string,
	verify: () => string | null,
): Promise<number> {
	const started = performance.now();
	const deadline = started + CONVERGENCE_TIMEOUT_MS;
	const generation: GenerationState = {
		lastGeneration: context.generation,
		lastChanged: context.lastChangeMs,
		lastVerified: 0,
	};
	let lastFailure = "no quiet window";

	while (performance.now() < deadline) {
		assertHealthy(context, label);
		const now = performance.now();
		if (shouldWaitForQuiet(context, generation, now)) {
			await delay(10);
			continue;
		}

		const generationBeforeCheck = context.generation;
		generation.lastVerified = performance.now();
		const verifyStart = performance.now();
		const failure = verify();
		context.verifyMs += performance.now() - verifyStart;
		context.verifyPasses++;
		if (context.generation !== generationBeforeCheck) {
			observeGeneration(context, generation);
			await delay(10);
			continue;
		}
		if (failure === null) return performance.now() - started;
		lastFailure = failure;

		await delay(10);
	}

	throw new Error(
		`[process ${context.processIndex}] ${label} did not converge in ${CONVERGENCE_TIMEOUT_MS}ms: ${lastFailure}`,
	);
}

function setFullPresence(state: ClientState, y: number) {
	state.client.presence.set({
		name: EXPECTED_NAMES[state.globalId],
		status: "active",
		cursor: { x: state.globalId, y },
	});
}

function markMovers(context: ProcessContext, expectedY: Int32Array) {
	const firstProcess = context.roomIndex * PROCESSES_PER_ROOM;
	for (
		let processIndex = firstProcess;
		processIndex < firstProcess + PROCESSES_PER_ROOM;
		processIndex++
	) {
		const firstClient = processIndex * CLIENTS_PER_PROCESS;
		for (let localId = 0; localId < CURSOR_GROUP_SIZE; localId++) {
			expectedY[firstClient + localId] = FIRST_CURSOR_TICKS - 1;
			expectedY[firstClient + CURSOR_GROUP_SIZE + localId] =
				SECOND_CURSOR_TICKS - 1;
		}
	}
}

async function cleanupClients(clients: ClientState[]) {
	for (const state of clients) {
		state.expectedDisconnect = true;
		state.client.disconnect();
	}
	await delay(0);
}

function setActiveEvery(
	context: ProcessContext,
	active: Uint8Array,
	step: number,
	value: 0 | 1,
) {
	const firstClient = context.roomIndex * CLIENTS_PER_ROOM;
	const end = firstClient + CLIENTS_PER_ROOM;
	for (let globalId = firstClient; globalId < end; globalId += step) {
		active[globalId] = value;
	}
}

async function mutateAfterProcessStagger(
	context: ProcessContext,
	clients: ClientState[],
	mutate: (state: ClientState) => void,
) {
	await delay(
		(context.processIndex % PROCESSES_PER_ROOM) * PROCESS_MUTATION_STAGGER_MS,
	);
	for (const state of clients) mutate(state);
	context.lastChangeMs = performance.now();
}

async function runJoinPhase(
	context: ProcessContext,
	active: Uint8Array,
	expectedY: Int32Array,
): Promise<number> {
	const started = performance.now();
	context.verifyEpoch++;
	await mutateAfterProcessStagger(context, context.clients, (state) =>
		setFullPresence(state, 0),
	);
	await waitForConvergence(
		context,
		"join",
		() =>
			verifyUsers(context, active, CLIENTS_PER_ROOM, expectedY, 1) ??
			verifyFullJoinSelfFilter(context),
	);
	return performance.now() - started;
}

async function runCursorPhase(
	context: ProcessContext,
	active: Uint8Array,
	expectedY: Int32Array,
): Promise<{ writeMs: number; convergeMs: number }> {
	context.verifyEpoch++;
	const firstGroup = context.clients.slice(0, CURSOR_GROUP_SIZE);
	const secondGroup = context.clients.slice(
		CURSOR_GROUP_SIZE,
		CURSOR_GROUP_SIZE * 2,
	);
	const started = performance.now();
	for (let tick = 0; tick < SECOND_CURSOR_TICKS; tick++) {
		if (tick < FIRST_CURSOR_TICKS) {
			for (const state of firstGroup) {
				state.client.presence.set({
					cursor: { x: state.globalId, y: tick },
				});
			}
		}
		for (const state of secondGroup) {
			state.client.presence.set({
				cursor: { x: state.globalId, y: tick },
			});
		}
		if (tick + 1 < SECOND_CURSOR_TICKS) await delay(CURSOR_INTERVAL_MS);
	}
	const writeMs = performance.now() - started;
	context.lastChangeMs = performance.now();
	markMovers(context, expectedY);
	const convergeMs = await waitForConvergence(context, "cursor flood", () =>
		verifyUsers(context, active, CLIENTS_PER_ROOM, expectedY),
	);
	return { writeMs, convergeMs };
}

async function writeSharedRounds(
	context: ProcessContext,
	firstRound: number,
	roundCount: number,
): Promise<number> {
	const writers = context.clients.filter((state) => state.globalId % 2 === 0);
	const started = performance.now();
	for (let offset = 0; offset < roundCount; offset++) {
		const update = sharedState(context, firstRound + offset);
		for (const state of writers) state.client.presence.setShared(update);
		if (offset + 1 < roundCount) await delay(SHARED_INTERVAL_MS);
	}
	context.lastChangeMs = performance.now();
	return performance.now() - started;
}

async function runSharedPhase(
	context: ProcessContext,
	firstRound: number,
	roundCount: number,
	label: string,
): Promise<{ writeMs: number; convergeMs: number }> {
	const writeMs = await writeSharedRounds(context, firstRound, roundCount);
	const finalRound = firstRound + roundCount - 1;
	const convergeMs = await waitForConvergence(context, label, () =>
		verifyShared(context, finalRound),
	);
	return { writeMs, convergeMs };
}

async function runRemovePhase(
	context: ProcessContext,
	active: Uint8Array,
	expectedY: Int32Array,
): Promise<number> {
	setActiveEvery(context, active, 2, 0);
	context.verifyEpoch++;
	const started = performance.now();
	await mutateAfterProcessStagger(
		context,
		context.clients.filter((state) => state.globalId % 2 === 0),
		(state) => state.client.presence.remove(),
	);
	await waitForConvergence(
		context,
		"remove half",
		() =>
			verifyUsers(context, active, CLIENTS_PER_ROOM / 2, expectedY) ??
			verifyShared(context, 0),
	);
	return performance.now() - started;
}

async function runRejoinPhase(
	context: ProcessContext,
	active: Uint8Array,
	expectedY: Int32Array,
): Promise<number> {
	setActiveEvery(context, active, 2, 1);
	context.verifyEpoch++;
	const started = performance.now();
	await mutateAfterProcessStagger(
		context,
		context.clients.filter((state) => state.globalId % 2 === 0),
		(state) => setFullPresence(state, expectedY[state.globalId]),
	);
	await waitForConvergence(
		context,
		"rejoin half",
		() =>
			verifyUsers(context, active, CLIENTS_PER_ROOM, expectedY, 1) ??
			verifyShared(context, 0),
	);
	return performance.now() - started;
}

async function runDisconnectPhase(
	context: ProcessContext,
	active: Uint8Array,
	expectedY: Int32Array,
): Promise<number> {
	setActiveEvery(context, active, 4, 0);
	context.verifyEpoch++;
	const started = performance.now();
	await mutateAfterProcessStagger(
		context,
		context.clients.filter((state) => state.globalId % 4 === 0),
		(state) => {
			state.expectedDisconnect = true;
			state.client.disconnect();
		},
	);
	await waitForConvergence(
		context,
		"disconnect quarter",
		() =>
			verifyUsers(
				context,
				active,
				CLIENTS_PER_ROOM - CLIENTS_PER_ROOM / 4,
				expectedY,
				1,
			) ?? verifyShared(context, 2),
	);
	return performance.now() - started;
}

async function runProcess(
	port: number,
	processIndex: number,
	jwtSecret: string,
	barrier: (phase: BarrierPhase) => Promise<void>,
): Promise<ProcessMetrics> {
	const roomIndex = Math.floor(processIndex / PROCESSES_PER_ROOM);
	const context: ProcessContext = {
		processIndex,
		roomIndex,
		clients: [],
		generation: 0,
		verifyEpoch: 0,
		lastChangeMs: performance.now(),
		errorCount: 0,
		errorSamples: [],
		downClients: new Set(),
		readyCount: 0,
		readyWaiters: [],
		verifyMs: 0,
		verifyPasses: 0,
	};
	const active = new Uint8Array(TOTAL_CLIENTS);
	const firstRoomClient = roomIndex * CLIENTS_PER_ROOM;
	active.fill(1, firstRoomClient, firstRoomClient + CLIENTS_PER_ROOM);
	const expectedY = new Int32Array(TOTAL_CLIENTS);
	const metrics: ProcessMetrics = {
		processIndex,
		clientCreateMs: 0,
		connectMs: 0,
		connectOnlyMs: 0,
		subscribeMs: 0,
		readinessMs: 0,
		cleanupMs: 0,
		barrierWaitMs: {},
		joinMs: 0,
		cursorWriteMs: 0,
		cursorConvergeMs: 0,
		sharedWriteMs: 0,
		sharedConvergeMs: 0,
		removeMs: 0,
		rejoinMs: 0,
		disconnectMs: 0,
		verifyMs: 0,
		verifyPasses: 0,
		userCallbacks: [],
		sharedCallbacks: [],
	};

	const waitAtBarrier = async (phase: BarrierPhase): Promise<void> => {
		const start = performance.now();
		await barrier(phase);
		metrics.barrierWaitMs[phase] = performance.now() - start;
	};

	try {
		const started = performance.now();
		const preparation = await prepareClients(context, port, jwtSecret);
		metrics.connectMs = performance.now() - started;
		metrics.clientCreateMs = preparation.clientCreateMs;
		metrics.connectOnlyMs = preparation.connectOnlyMs;
		metrics.subscribeMs = preparation.subscribeMs;
		metrics.readinessMs = preparation.readinessMs;
		await waitAtBarrier("ready");

		metrics.joinMs = await runJoinPhase(context, active, expectedY);
		await waitAtBarrier("join");

		const cursor = await runCursorPhase(context, active, expectedY);
		metrics.cursorWriteMs = cursor.writeMs;
		metrics.cursorConvergeMs = cursor.convergeMs;
		await waitAtBarrier("cursor");

		const sharedBeforeRemove = await runSharedPhase(
			context,
			0,
			1,
			"shared before remove",
		);
		metrics.sharedWriteMs += sharedBeforeRemove.writeMs;
		metrics.sharedConvergeMs += sharedBeforeRemove.convergeMs;
		await waitAtBarrier("shared-before-remove");

		metrics.removeMs = await runRemovePhase(context, active, expectedY);
		await waitAtBarrier("remove");

		metrics.rejoinMs = await runRejoinPhase(context, active, expectedY);
		await waitAtBarrier("rejoin");

		const sharedAfterRejoin = await runSharedPhase(
			context,
			1,
			2,
			"shared after rejoin",
		);
		metrics.sharedWriteMs += sharedAfterRejoin.writeMs;
		metrics.sharedConvergeMs += sharedAfterRejoin.convergeMs;
		await waitAtBarrier("shared-after-rejoin");

		metrics.disconnectMs = await runDisconnectPhase(context, active, expectedY);
		await waitAtBarrier("disconnect");

		metrics.verifyMs = context.verifyMs;
		metrics.verifyPasses = context.verifyPasses;
		metrics.userCallbacks = context.clients.map((state) => state.userCallbacks);
		metrics.sharedCallbacks = context.clients.map(
			(state) => state.sharedCallbacks,
		);
		return metrics;
	} finally {
		const cleanupStart = performance.now();
		await cleanupClients(context.clients);
		metrics.cleanupMs = performance.now() - cleanupStart;
	}
}

function isBarrierPhase(value: unknown): value is BarrierPhase {
	return BARRIER_PHASES.includes(value as BarrierPhase);
}

function childBarrier(
	processIndex: number,
	phase: BarrierPhase,
): Promise<void> {
	return new Promise((resolve, reject) => {
		process.once("message", (message: unknown) => {
			if (
				isRecord(message) &&
				message.type === "continue" &&
				message.phase === phase
			) {
				resolve();
				return;
			}
			reject(
				new Error(
					`[process ${processIndex}] expected continue for ${phase}, got ${JSON.stringify(message)}`,
				),
			);
		});
		process.send?.({ type: "barrier", processIndex, phase });
	});
}

function spawnWorker(port: number, processIndex: number, jwtSecret: string) {
	const result = Promise.withResolvers<ProcessMetrics>();
	const reached = new Set<BarrierPhase>();
	const waiters = new Map<BarrierPhase, BarrierWaiter>();
	let expectedBarrierIndex = 0;
	let failure: Error | null = null;
	let resultReceived = false;

	const fail = (error: Error) => {
		failure ??= error;
		for (const waiter of waiters.values()) waiter.reject(error);
		waiters.clear();
		if (!resultReceived) result.reject(error);
	};
	const handleBarrier = (phase: BarrierPhase) => {
		const expected = BARRIER_PHASES[expectedBarrierIndex];
		if (phase !== expected) {
			fail(
				new Error(
					`Presence worker ${processIndex} reached ${phase}, expected ${expected}`,
				),
			);
			return;
		}
		expectedBarrierIndex++;
		reached.add(phase);
		waiters.get(phase)?.resolve();
		waiters.delete(phase);
	};
	const handleMessage = (message: unknown) => {
		if (!isRecord(message) || message.processIndex !== processIndex) {
			fail(
				new Error(
					`Presence worker ${processIndex} sent an invalid IPC message`,
				),
			);
			return;
		}
		if (message.type === "barrier") {
			if (isBarrierPhase(message.phase)) handleBarrier(message.phase);
			else fail(new Error(`Presence worker ${processIndex} sent a bad phase`));
			return;
		}
		if (message.type === "result") {
			resultReceived = true;
			result.resolve((message as unknown as WorkerResultMessage).result);
			return;
		}
		fail(new Error(`Presence worker ${processIndex} sent an unknown message`));
	};

	const workerCommand = [process.execPath];
	const profileDir = process.env.ZYNCBASE_PRESENCE_PROFILE_DIR;
	if (profileDir) {
		workerCommand.push(
			"--cpu-prof",
			"--cpu-prof-md",
			"--cpu-prof-dir",
			profileDir,
			"--cpu-prof-name",
			`client-${processIndex + 1}.cpuprofile`,
		);
	}
	workerCommand.push(
		import.meta.path,
		"--worker",
		String(port),
		String(processIndex),
		jwtSecret,
	);

	const worker = Bun.spawn(workerCommand, {
		stdio: ["ignore", profileDir ? "inherit" : "ignore", "inherit"],
		ipc: handleMessage,
	});

	worker.exited.then((exitCode) => {
		if (exitCode !== 0 || !resultReceived) {
			fail(
				new Error(
					`Presence worker ${processIndex} exited with code ${exitCode}${resultReceived ? "" : " before reporting results"}`,
				),
			);
		}
	});

	const waitForBarrier = (phase: BarrierPhase): Promise<void> => {
		if (failure) return Promise.reject(failure);
		if (reached.has(phase)) return Promise.resolve();
		const waiter = Promise.withResolvers<void>();
		waiters.set(phase, waiter);
		return waiter.promise;
	};

	return { worker, result: result.promise, waitForBarrier };
}

function percentile(values: number[], fraction: number): number {
	if (values.length === 0) return 0;
	const sorted = values.toSorted((a, b) => a - b);
	return sorted[Math.ceil(sorted.length * fraction) - 1];
}

function reportMetrics(results: ProcessMetrics[], elapsedMs: number) {
	const max = (key: keyof ProcessMetrics) =>
		Math.round(Math.max(...results.map((result) => result[key] as number)));
	const round = (value: number) => Math.round(value);
	const userCallbacks = results.flatMap((result) => result.userCallbacks);
	const sharedCallbacks = results.flatMap((result) => result.sharedCallbacks);
	console.log(
		`Presence stress passed: ${TOTAL_CLIENTS} clients across ${ROOM_COUNT} rooms in ${Math.round(elapsedMs)}ms; ` +
			`phase max ms connect=${max("connectMs")}, join=${max("joinMs")}, ` +
			`cursor-write=${max("cursorWriteMs")}, cursor-converge=${max("cursorConvergeMs")}, ` +
			`shared-write=${max("sharedWriteMs")}, shared-converge=${max("sharedConvergeMs")}, ` +
			`remove=${max("removeMs")}, rejoin=${max("rejoinMs")}, disconnect=${max("disconnectMs")}; ` +
			`verify=${max("verifyMs")} (passes=${max("verifyPasses")}); ` +
			`user callbacks p50/p95/max=${percentile(userCallbacks, 0.5)}/${percentile(userCallbacks, 0.95)}/${Math.max(...userCallbacks)}, ` +
			`shared callbacks p50/p95/max=${percentile(sharedCallbacks, 0.5)}/${percentile(sharedCallbacks, 0.95)}/${Math.max(...sharedCallbacks)}`,
	);
	console.log(
		`Presence stress setup max ms client-create=${max("clientCreateMs")}, ` +
			`connect-only=${max("connectOnlyMs")}, subscribe=${max("subscribeMs")}, ` +
			`readiness=${max("readinessMs")}, cleanup=${max("cleanupMs")}`,
	);
	for (const result of results) {
		console.log(
			`  proc ${result.processIndex}: create=${round(result.clientCreateMs)} ` +
				`connect=${round(result.connectMs)} (only=${round(result.connectOnlyMs)}, ` +
				`subscribe=${round(result.subscribeMs)}, ready=${round(result.readinessMs)}) ` +
				`join=${round(result.joinMs)} ` +
				`cursor=${round(result.cursorWriteMs)}/${round(result.cursorConvergeMs)} ` +
				`shared=${round(result.sharedWriteMs)}/${round(result.sharedConvergeMs)} ` +
				`remove=${round(result.removeMs)} rejoin=${round(result.rejoinMs)} ` +
				`disconnect=${round(result.disconnectMs)} ` +
				`verify=${round(result.verifyMs)}/${result.verifyPasses} ` +
				`cleanup=${round(result.cleanupMs)} ` +
				`barrier=${JSON.stringify(
					Object.fromEntries(
						Object.entries(result.barrierWaitMs).map(([phase, ms]) => [
							phase,
							round(ms as number),
						]),
					),
				)}`,
		);
	}
}

export async function run(port: number, jwtSecret: string) {
	const started = performance.now();
	const workers = Array.from({ length: PROCESS_COUNT - 1 }, (_, index) =>
		spawnWorker(port, index + 1, jwtSecret),
	);
	const remoteResults = Promise.all(workers.map((worker) => worker.result));

	const parentBarrier = async (phase: BarrierPhase) => {
		await Promise.all(workers.map((worker) => worker.waitForBarrier(phase)));
		const message: ParentContinueMessage = { type: "continue", phase };
		for (const { worker } of workers) worker.send(message);
	};

	const localResult = runProcess(port, 0, jwtSecret, parentBarrier).catch(
		(error) => {
			for (const { worker } of workers) worker.kill();
			throw error;
		},
	);

	try {
		const settled = await Promise.allSettled([localResult, remoteResults]);
		const local = settled[0];
		const remote = settled[1];
		if (local.status === "rejected") throw local.reason;
		if (remote.status === "rejected") throw remote.reason;

		const exitCodes = await Promise.all(
			workers.map(({ worker }) => worker.exited),
		);
		const failedWorker = exitCodes.findIndex((exitCode) => exitCode !== 0);
		if (failedWorker !== -1) {
			throw new Error(
				`Presence worker ${failedWorker + 1} exited with code ${exitCodes[failedWorker]}`,
			);
		}

		reportMetrics([local.value, ...remote.value], performance.now() - started);
	} finally {
		for (const { worker } of workers) worker.kill();
		await Promise.all(
			workers.map(({ worker }) => worker.exited.catch(() => {})),
		);
	}
}

if (import.meta.main) {
	const [mode, portArg, processIndexArg, jwtSecret] = Bun.argv.slice(2);
	const port = Number(portArg);
	const processIndex = Number(processIndexArg);
	if (
		mode !== "--worker" ||
		!Number.isInteger(port) ||
		port < 1 ||
		port > 65_535 ||
		!Number.isInteger(processIndex) ||
		processIndex < 1 ||
		processIndex >= PROCESS_COUNT ||
		!jwtSecret
	) {
		throw new Error(
			"usage: test-presence-stress.ts --worker <port> <process-index> <jwt-secret>",
		);
	}
	if (!process.send) {
		throw new Error("Presence stress worker requires an IPC channel");
	}
	const result = await runProcess(port, processIndex, jwtSecret, (phase) =>
		childBarrier(processIndex, phase),
	);
	const message: WorkerResultMessage = {
		type: "result",
		processIndex,
		result,
	};
	process.send(message);
}
