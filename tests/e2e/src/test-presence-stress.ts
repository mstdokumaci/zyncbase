import {
	createClient,
	type PresenceEntry,
	type ZyncBaseClient,
} from "@zyncbase/client";
import { createTestJwt } from "./harness";

const PROCESS_COUNT = 4;
const CLIENTS_PER_PROCESS = 500;
const TOTAL_CLIENTS = PROCESS_COUNT * CLIENTS_PER_PROCESS;
const CONNECT_BATCH_SIZE = 50;
const PROCESS_MUTATION_STAGGER_MS = 250;

const MOVERS_PER_PROCESS = 10;
const CURSOR_TICKS = 120;
const CURSOR_INTERVAL_MS = 8;

const SHARED_TICKS = 80;
const SHARED_INTERVAL_MS = 20;

const QUIET_WINDOW_MS = 100;
const CONVERGENCE_TIMEOUT_MS = 20_000;
const CONNECT_TIMEOUT_MS = 45_000;
const PRESENCE_NAMESPACE = "presence-stress";
const NAME_PREFIX = "client-";
const EXPECTED_NAMES = Array.from(
	{ length: TOTAL_CLIENTS },
	(_, globalId) => `${NAME_PREFIX}${globalId}`,
);

const BARRIER_PHASES = [
	"ready",
	"join",
	"cursor",
	"shared",
	"remove",
	"rejoin",
	"disconnect",
] as const;

type BarrierPhase = (typeof BARRIER_PHASES)[number];

type ClientState = {
	client: ZyncBaseClient;
	globalId: number;
	unsubscribeUsers?: () => void;
	unsubscribeShared?: () => void;
	userReady: boolean;
	sharedReady: boolean;
	userCallbacks: number;
	sharedCallbacks: number;
	errorCount: number;
	errorSamples: string[];
	disconnected: boolean;
	expectedDisconnect: boolean;
};

type ProcessContext = {
	processIndex: number;
	clients: ClientState[];
	generation: number;
};

type ProcessMetrics = {
	processIndex: number;
	connectMs: number;
	joinMs: number;
	cursorWriteMs: number;
	cursorConvergeMs: number;
	sharedWriteMs: number;
	sharedConvergeMs: number;
	removeMs: number;
	rejoinMs: number;
	disconnectMs: number;
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
		presenceNamespace: PRESENCE_NAMESPACE,
		retryRateLimits: false,
	});
	const state: ClientState = {
		client,
		globalId,
		userReady: false,
		sharedReady: false,
		userCallbacks: 0,
		sharedCallbacks: 0,
		errorCount: 0,
		errorSamples: [],
		disconnected: false,
		expectedDisconnect: false,
	};

	client.on("error", (error) => {
		state.errorCount++;
		if (state.errorSamples.length < 3) {
			state.errorSamples.push(formatError(error));
		}
	});
	client.on("disconnected", () => {
		state.disconnected = true;
	});

	return state;
}

function healthIssue(context: ProcessContext): string | null {
	for (const state of context.clients) {
		if (state.errorCount > 0) {
			return `client ${state.globalId} emitted ${state.errorCount} error(s): ${state.errorSamples.join("; ")}`;
		}
		if (state.disconnected && !state.expectedDisconnect) {
			return `client ${state.globalId} disconnected unexpectedly`;
		}
	}
	return null;
}

async function waitForReadiness(context: ProcessContext): Promise<void> {
	while (
		!context.clients.every((state) => state.userReady && state.sharedReady)
	) {
		const issue = healthIssue(context);
		if (issue) throw new Error(`[process ${context.processIndex}] ${issue}`);
		await delay(10);
	}
}

async function prepareClients(
	context: ProcessContext,
	port: number,
	jwtSecret: string,
): Promise<void> {
	await withTimeout(
		(async () => {
			for (let localId = 0; localId < CLIENTS_PER_PROCESS; localId++) {
				context.clients.push(
					makeClientState(context, port, jwtSecret, localId),
				);
			}

			for (
				let offset = 0;
				offset < context.clients.length;
				offset += CONNECT_BATCH_SIZE
			) {
				const batch = context.clients.slice(
					offset,
					offset + CONNECT_BATCH_SIZE,
				);
				await Promise.all(
					batch.map(async (state) => {
						try {
							await state.client.connect();
						} catch (error) {
							throw new Error(
								`client ${state.globalId} failed to connect: ${formatError(error)}`,
							);
						}
					}),
				);
			}

			for (const state of context.clients) {
				state.unsubscribeUsers = state.client.presence.subscribe(() => {
					state.userCallbacks++;
					state.userReady = true;
					context.generation++;
				});
				state.unsubscribeShared = state.client.presence.subscribeShared(() => {
					state.sharedCallbacks++;
					state.sharedReady = true;
					context.generation++;
				});
			}

			await waitForReadiness(context);
		})(),
		CONNECT_TIMEOUT_MS,
		`process ${context.processIndex} connection and subscription readiness`,
	);
}

function parseGlobalId(entry: PresenceEntry): number | null {
	const cursor = entry.data.cursor;
	if (!isRecord(cursor)) return null;
	const id = cursor.x;
	if (
		typeof id !== "number" ||
		!Number.isInteger(id) ||
		id < 0 ||
		id >= TOTAL_CLIENTS
	) {
		return null;
	}
	return id;
}

function hasExpectedData(entry: PresenceEntry, globalId: number, y: number) {
	const data = entry.data;
	const cursor = data.cursor;
	return (
		data.name === EXPECTED_NAMES[globalId] &&
		data.status === "active" &&
		isRecord(cursor) &&
		cursor.x === globalId &&
		cursor.y === y &&
		typeof entry.userId === "string" &&
		entry.userId.length > 0 &&
		Number.isFinite(entry.joinedAt) &&
		entry.joinedAt > 0
	);
}

type EntryScan = {
	seen: Uint8Array;
	samples: string[];
	invalid: number;
	duplicate: number;
	extra: number;
	stale: number;
};

function addSample(scan: EntryScan, message: string) {
	if (scan.samples.length < 5) scan.samples.push(message);
}

function scanEntry(
	entry: PresenceEntry,
	active: Uint8Array,
	expectedY: Int32Array,
	scan: EntryScan,
) {
	const globalId = parseGlobalId(entry);
	if (globalId === null) {
		scan.invalid++;
		addSample(scan, `invalid cursor identity ${String(entry.data.cursor)}`);
		return;
	}

	scan.seen[globalId]++;
	if (scan.seen[globalId] > 1) {
		scan.duplicate++;
		addSample(scan, `duplicate ${globalId}`);
	}
	if (active[globalId] === 0) {
		scan.extra++;
		addSample(scan, `extra ${globalId}`);
	}
	if (!hasExpectedData(entry, globalId, expectedY[globalId])) {
		scan.stale++;
		addSample(scan, `stale ${globalId}`);
	}
}

function scanEntries(
	entries: PresenceEntry[],
	active: Uint8Array,
	expectedY: Int32Array,
): EntryScan {
	const scan: EntryScan = {
		seen: new Uint8Array(TOTAL_CLIENTS),
		samples: [],
		invalid: 0,
		duplicate: 0,
		extra: 0,
		stale: 0,
	};
	for (const entry of entries) {
		scanEntry(entry, active, expectedY, scan);
	}
	return scan;
}

function countMissing(active: Uint8Array, scan: EntryScan): number {
	let missing = 0;
	for (let globalId = 0; globalId < TOTAL_CLIENTS; globalId++) {
		if (active[globalId] === 1 && scan.seen[globalId] === 0) {
			missing++;
			addSample(scan, `missing ${globalId}`);
		}
	}
	return missing;
}

function verifyObserver(
	state: ClientState,
	active: Uint8Array,
	expectedCount: number,
	expectedY: Int32Array,
): string | null {
	const entries = state.client.presence.getAll({ includeSelf: true });
	const scan = scanEntries(entries, active, expectedY);
	const missing = countMissing(active, scan);
	if (
		entries.length === expectedCount &&
		scan.invalid === 0 &&
		scan.duplicate === 0 &&
		scan.extra === 0 &&
		scan.stale === 0 &&
		missing === 0
	) {
		return null;
	}
	return (
		`observer ${state.globalId}: expected ${expectedCount}, got ${entries.length}; ` +
		`missing=${missing}, extra=${scan.extra}, duplicate=${scan.duplicate}, invalid=${scan.invalid}, stale=${scan.stale}` +
		(scan.samples.length > 0 ? ` (${scan.samples.join(", ")})` : "")
	);
}

function verifyUsers(
	context: ProcessContext,
	active: Uint8Array,
	expectedCount: number,
	expectedY: Int32Array,
): string | null {
	const failures: string[] = [];
	for (const state of context.clients) {
		if (state.expectedDisconnect) continue;
		const failure = verifyObserver(state, active, expectedCount, expectedY);
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
			all.length !== TOTAL_CLIENTS ||
			others.length !== TOTAL_CLIENTS - 1 ||
			!all.some((entry) => entry.data.name === ownName) ||
			others.some((entry) => entry.data.name === ownName)
		) {
			return `observer ${state.globalId}: self filter expected ${TOTAL_CLIENTS}/${TOTAL_CLIENTS - 1} include/default entries and own marker only in include-self view; got ${all.length}/${others.length}`;
		}
	}
	return null;
}

function verifyShared(context: ProcessContext): string | null {
	for (const state of context.clients) {
		if (state.expectedDisconnect) continue;
		const shared = state.client.presence.getShared();
		if (
			shared === null ||
			Object.keys(shared).length !== 2 ||
			shared.slide !== SHARED_TICKS - 1 ||
			shared.playing !== false
		) {
			return `observer ${state.globalId}: expected shared slide=${SHARED_TICKS - 1}, playing=false; got ${JSON.stringify(shared)}`;
		}
	}
	return null;
}

type GenerationState = {
	lastGeneration: number;
	lastChanged: number;
	checkedGeneration: number;
};

function observeGeneration(
	context: ProcessContext,
	state: GenerationState,
): boolean {
	if (context.generation === state.lastGeneration) return false;
	state.lastGeneration = context.generation;
	state.lastChanged = performance.now();
	state.checkedGeneration = -1;
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
	return (
		now - state.lastChanged < QUIET_WINDOW_MS ||
		state.checkedGeneration === context.generation
	);
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
		lastChanged: performance.now(),
		checkedGeneration: -1,
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
		const failure = verify();
		if (context.generation !== generationBeforeCheck) {
			observeGeneration(context, generation);
			await delay(10);
			continue;
		}
		generation.checkedGeneration = context.generation;
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

function markMovers(expectedY: Int32Array) {
	for (let processIndex = 0; processIndex < PROCESS_COUNT; processIndex++) {
		for (let localId = 0; localId < MOVERS_PER_PROCESS; localId++) {
			expectedY[processIndex * CLIENTS_PER_PROCESS + localId] =
				CURSOR_TICKS - 1;
		}
	}
}

async function cleanupClients(clients: ClientState[]) {
	for (const state of clients) {
		state.unsubscribeUsers?.();
		state.unsubscribeShared?.();
	}
	for (const state of clients) {
		state.expectedDisconnect = true;
		state.client.disconnect();
	}
	await delay(0);
}

function setActiveEvery(active: Uint8Array, step: number, value: 0 | 1) {
	for (let globalId = 0; globalId < TOTAL_CLIENTS; globalId += step) {
		active[globalId] = value;
	}
}

async function mutateAfterProcessStagger(
	context: ProcessContext,
	clients: ClientState[],
	mutate: (state: ClientState) => void,
) {
	await delay(context.processIndex * PROCESS_MUTATION_STAGGER_MS);
	for (const state of clients) mutate(state);
}

async function runJoinPhase(
	context: ProcessContext,
	active: Uint8Array,
	expectedY: Int32Array,
): Promise<number> {
	const started = performance.now();
	await mutateAfterProcessStagger(context, context.clients, (state) =>
		setFullPresence(state, 0),
	);
	await waitForConvergence(context, "join", () =>
		verifyUsers(context, active, TOTAL_CLIENTS, expectedY),
	);
	await waitForConvergence(context, "join self filter", () =>
		verifyFullJoinSelfFilter(context),
	);
	return performance.now() - started;
}

async function runCursorPhase(
	context: ProcessContext,
	active: Uint8Array,
	expectedY: Int32Array,
): Promise<{ writeMs: number; convergeMs: number }> {
	const movers = context.clients.slice(0, MOVERS_PER_PROCESS);
	const started = performance.now();
	for (let tick = 0; tick < CURSOR_TICKS; tick++) {
		for (const state of movers) {
			state.client.presence.set({
				cursor: { x: state.globalId, y: tick },
			});
		}
		if (tick + 1 < CURSOR_TICKS) await delay(CURSOR_INTERVAL_MS);
	}
	const writeMs = performance.now() - started;
	markMovers(expectedY);
	const convergeMs = await waitForConvergence(context, "cursor flood", () =>
		verifyUsers(context, active, TOTAL_CLIENTS, expectedY),
	);
	return { writeMs, convergeMs };
}

async function writeSharedFields(context: ProcessContext): Promise<number> {
	const started = performance.now();
	if (context.processIndex > 1) return performance.now() - started;
	for (let tick = 0; tick < SHARED_TICKS; tick++) {
		const update =
			context.processIndex === 0
				? { slide: tick }
				: { playing: tick % 2 === 0 };
		context.clients[0].client.presence.setShared(update);
		if (tick + 1 < SHARED_TICKS) await delay(SHARED_INTERVAL_MS);
	}
	return performance.now() - started;
}

async function runSharedPhase(
	context: ProcessContext,
): Promise<{ writeMs: number; convergeMs: number }> {
	const writeMs = await writeSharedFields(context);
	const convergeMs = await waitForConvergence(context, "shared flood", () =>
		verifyShared(context),
	);
	return { writeMs, convergeMs };
}

async function runRemovePhase(
	context: ProcessContext,
	active: Uint8Array,
	expectedY: Int32Array,
): Promise<number> {
	setActiveEvery(active, 2, 0);
	const started = performance.now();
	await mutateAfterProcessStagger(
		context,
		context.clients.filter((state) => state.globalId % 2 === 0),
		(state) => state.client.presence.remove(),
	);
	await waitForConvergence(context, "remove half", () =>
		verifyUsers(context, active, TOTAL_CLIENTS / 2, expectedY),
	);
	return performance.now() - started;
}

async function runRejoinPhase(
	context: ProcessContext,
	active: Uint8Array,
	expectedY: Int32Array,
): Promise<number> {
	setActiveEvery(active, 2, 1);
	const started = performance.now();
	await mutateAfterProcessStagger(
		context,
		context.clients.filter((state) => state.globalId % 2 === 0),
		(state) => setFullPresence(state, expectedY[state.globalId]),
	);
	await waitForConvergence(context, "rejoin half", () =>
		verifyUsers(context, active, TOTAL_CLIENTS, expectedY),
	);
	return performance.now() - started;
}

async function runDisconnectPhase(
	context: ProcessContext,
	active: Uint8Array,
	expectedY: Int32Array,
): Promise<number> {
	setActiveEvery(active, 4, 0);
	const started = performance.now();
	await mutateAfterProcessStagger(
		context,
		context.clients.filter((state) => state.globalId % 4 === 0),
		(state) => {
			state.expectedDisconnect = true;
			state.client.disconnect();
		},
	);
	await waitForConvergence(context, "disconnect quarter", () =>
		verifyUsers(context, active, TOTAL_CLIENTS - TOTAL_CLIENTS / 4, expectedY),
	);
	return performance.now() - started;
}

async function runProcess(
	port: number,
	processIndex: number,
	jwtSecret: string,
	barrier: (phase: BarrierPhase) => Promise<void>,
): Promise<ProcessMetrics> {
	const context: ProcessContext = {
		processIndex,
		clients: [],
		generation: 0,
	};
	const active = new Uint8Array(TOTAL_CLIENTS);
	active.fill(1);
	const expectedY = new Int32Array(TOTAL_CLIENTS);
	const metrics: ProcessMetrics = {
		processIndex,
		connectMs: 0,
		joinMs: 0,
		cursorWriteMs: 0,
		cursorConvergeMs: 0,
		sharedWriteMs: 0,
		sharedConvergeMs: 0,
		removeMs: 0,
		rejoinMs: 0,
		disconnectMs: 0,
		userCallbacks: [],
		sharedCallbacks: [],
	};

	try {
		const started = performance.now();
		await prepareClients(context, port, jwtSecret);
		metrics.connectMs = performance.now() - started;
		await barrier("ready");

		metrics.joinMs = await runJoinPhase(context, active, expectedY);
		await barrier("join");

		const cursor = await runCursorPhase(context, active, expectedY);
		metrics.cursorWriteMs = cursor.writeMs;
		metrics.cursorConvergeMs = cursor.convergeMs;
		await barrier("cursor");

		const shared = await runSharedPhase(context);
		metrics.sharedWriteMs = shared.writeMs;
		metrics.sharedConvergeMs = shared.convergeMs;
		await barrier("shared");

		metrics.removeMs = await runRemovePhase(context, active, expectedY);
		await barrier("remove");

		metrics.rejoinMs = await runRejoinPhase(context, active, expectedY);
		await barrier("rejoin");

		metrics.disconnectMs = await runDisconnectPhase(context, active, expectedY);
		await barrier("disconnect");

		metrics.userCallbacks = context.clients.map((state) => state.userCallbacks);
		metrics.sharedCallbacks = context.clients.map(
			(state) => state.sharedCallbacks,
		);
		return metrics;
	} finally {
		await cleanupClients(context.clients);
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
	const userCallbacks = results.flatMap((result) => result.userCallbacks);
	const sharedCallbacks = results.flatMap((result) => result.sharedCallbacks);
	console.log(
		`Presence stress passed: ${TOTAL_CLIENTS} clients in ${Math.round(elapsedMs)}ms; ` +
			`phase max ms connect=${max("connectMs")}, join=${max("joinMs")}, ` +
			`cursor-write=${max("cursorWriteMs")}, cursor-converge=${max("cursorConvergeMs")}, ` +
			`shared-write=${max("sharedWriteMs")}, shared-converge=${max("sharedConvergeMs")}, ` +
			`remove=${max("removeMs")}, rejoin=${max("rejoinMs")}, disconnect=${max("disconnectMs")}; ` +
			`user callbacks p50/p95/max=${percentile(userCallbacks, 0.5)}/${percentile(userCallbacks, 0.95)}/${Math.max(...userCallbacks)}, ` +
			`shared callbacks p50/p95/max=${percentile(sharedCallbacks, 0.5)}/${percentile(sharedCallbacks, 0.95)}/${Math.max(...sharedCallbacks)}`,
	);
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
