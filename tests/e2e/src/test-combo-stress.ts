import {
	createClient,
	type PresenceEntry,
	type QueryOptions,
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

// Top-level topology configuration
const ROOM_COUNT = 2;
const PROCESS_COUNT = 4;
const CLIENTS_PER_PROCESS = envInt(
	"ZYNCBASE_COMBO_CLIENTS_PER_PROCESS",
	2500,
	400,
);
const TOTAL_CLIENTS = PROCESS_COUNT * CLIENTS_PER_PROCESS; // 10,000
const CONNECT_CONCURRENCY = envInt("ZYNCBASE_COMBO_CONNECT_CONCURRENCY", 250);

// Writer role boundaries within each process (first 400 clients)
const STORE_CREATORS = 100; // localId 0..99
const STORE_UPDATERS = 100; // localId 100..199
const PRESENCE_USER_WRITERS = 100; // localId 200..299
const PRESENCE_SHARED_WRITERS = 100; // localId 300..399
// localId 400..2499 are passive subscribers

// Convergence sampling optimization: check every 5th client
const CONVERGENCE_SAMPLE_STRIDE = envInt("ZYNCBASE_COMBO_SAMPLE_STRIDE", 5);

const QUIET_WINDOW_MS = envInt("ZYNCBASE_COMBO_QUIET_WINDOW_MS", 100, 0);
const VERIFY_RETRY_INTERVAL_MS = envInt(
	"ZYNCBASE_COMBO_VERIFY_RETRY_MS",
	250,
	0,
);
const PRESENCE_TICK_DELAY_MS = envInt(
	"ZYNCBASE_COMBO_PRESENCE_TICK_DELAY_MS",
	25,
	0,
);
const PRESENCE_FULL_PAYLOAD =
	process.env.ZYNCBASE_COMBO_PRESENCE_FULL_PAYLOAD !== "0";
const CONVERGENCE_TIMEOUT_MS = 90_000;
const CONNECT_TIMEOUT_MS = 45_000;
const PRESENCE_NAMESPACE_PREFIX = "presence-combo-room";

// Process mappings
// Process 0, 1 -> room 0; Process 2, 3 -> room 1
const PROCESS_ROOM: Record<number, number> = {
	0: 0,
	1: 0,
	2: 1,
	3: 1,
};

// Process 0, 2 -> items; Process 1, 3 -> events
const PROCESS_TABLE: Record<number, "items" | "events"> = {
	0: "items",
	1: "events",
	2: "items",
	3: "events",
};

export interface ItemRecord {
	id: string;
	name: string;
	priority: number;
	active: boolean;
	tags: string[];
}

export interface EventRecord {
	id: string;
	title: string;
	score: number;
	ratings: number[];
}

export type ClientRole =
	| "creator"
	| "updater"
	| "presence-user"
	| "presence-shared"
	| "passive";

export type ClientState = {
	client: ZyncBaseClient;
	globalId: number;
	localId: number;
	role: ClientRole;
	filterSet: "A" | "B";

	// Store tracking
	storeSnapshot: (ItemRecord | EventRecord)[];
	storeRecords: Map<string, ItemRecord | EventRecord>;
	storeMapRevision: number;
	storeFired: boolean;
	storeSubscribed: boolean;

	// Presence tracking
	userReady: boolean;
	sharedReady: boolean;
	ready: boolean;
	userCallbacks: number;
	sharedCallbacks: number;
	/** Last user-presence payload written, re-applied after a reconnect. */
	lastPresenceData: Record<string, unknown> | null;

	// Health tracking
	disconnected: boolean;
	expectedDisconnect: boolean;

	// Verification caches: successes are skipped while the relevant revisions
	// are unchanged; failures are always rescanned (local presence writes do
	// not emit callbacks, so a cached failure could outlive the fix).
	storeRevision: number;
	storeScannedRevision: number;
	storeScannedBaselineRevision: number;
	cachedStoreFailure: string | null;
	presenceRevision: number;
	presenceScannedRevision: number;
	cachedPresenceFailure: string | null;
};

export type ProcessContext = {
	processIndex: number;
	roomIndex: number;
	table: "items" | "events";
	clients: ClientState[];
	storeGeneration: number;
	presenceGeneration: number;
	/** performance.now() of the last store/presence generation change. */
	lastStoreChangeMs: number;
	lastPresenceChangeMs: number;
	/** Aggregated health state so checks stay O(1). */
	errorCount: number;
	errorSamples: string[];
	downClients: Set<ClientState>;
	readyCount: number;
	readyWaiters: Array<{
		resolve: () => void;
		reject: (error: Error) => void;
	}>;
};

export const BARRIER_PHASES = [
	"ready",
	"store-create",
	"store-update",
	"presence-user",
	"presence-shared",
	"converge",
] as const;

export type BarrierPhase = (typeof BARRIER_PHASES)[number];

export type ConvergenceStats = {
	elapsedMs: number;
	verifyMs: number;
	passes: number;
	scannedClients: number;
	cachedClients: number;
};

export type ProcessMetrics = {
	processIndex: number;
	clientCreateMs: number;
	connectMs: number;
	connectOnlyMs: number;
	subscribeMs: number;
	readinessMs: number;
	cleanupMs: number;
	barrierWaitMs: Partial<Record<BarrierPhase, number>>;
	storeCreateMs: number;
	storeUpdateMs: number;
	presenceUserMs: number;
	presenceSharedMs: number;
	storeConvergeMs: number;
	presenceConvergeMs: number;
	storeVerifyMs: number;
	storeVerifyPasses: number;
	storeScannedClients: number;
	storeCachedClients: number;
	presenceVerifyMs: number;
	presenceVerifyPasses: number;
	presenceScannedClients: number;
	presenceCachedClients: number;
	filterACount: number;
	filterBCount: number;
	userPresenceCount: number;
	userCallbacks: number[];
	sharedCallbacks: number[];
	/** Generation counts = callback deliveries during the run. */
	storeCallbacks: number;
	presenceCallbacks: number;
	/** ms from convergence start to the last store/presence change (negative = settled before). */
	lastStoreDeltaMs: number;
	lastPresenceDeltaMs: number;
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

/**
 * Retries an operation whose failure is transient socket churn (slow corporate
 * proxies/EDR, load-induced drops). The SDK reconnects on its own, so the
 * operation succeeds once the socket returns; only the deadline turns churn
 * into a failure.
 */
async function withConnectionRetry<T>(op: () => Promise<T>): Promise<T> {
	const deadline = performance.now() + CONVERGENCE_TIMEOUT_MS;
	for (;;) {
		try {
			return await op();
		} catch (error) {
			const transient =
				isRecord(error) &&
				error.retryable === true &&
				error.category === "network";
			if (!transient || performance.now() > deadline) throw error;
			await new Promise((resolve) => setTimeout(resolve, 50));
		}
	}
}

function deterministicUnit(seed: number): number {
	let value = Math.imul(seed ^ (seed >>> 16), 0x45d9f3b);
	value = Math.imul(value ^ (value >>> 16), 0x45d9f3b);
	return ((value ^ (value >>> 16)) >>> 0) / 2 ** 32;
}

function tagsEqual(a: string[], b: string[]): boolean {
	if (a.length !== b.length) return false;
	for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
	return true;
}

function ratingsEqual(a: number[], b: number[]): boolean {
	if (a.length !== b.length) return false;
	for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
	return true;
}

function itemsEqual(a: ItemRecord, b: ItemRecord): boolean {
	if (!a || !b) return false;
	return (
		a.name === b.name &&
		a.priority === b.priority &&
		a.active === b.active &&
		Array.isArray(a.tags) &&
		Array.isArray(b.tags) &&
		tagsEqual(a.tags, b.tags)
	);
}

function eventsEqual(a: EventRecord, b: EventRecord): boolean {
	if (!a || !b) return false;
	return (
		a.title === b.title &&
		a.score === b.score &&
		Array.isArray(a.ratings) &&
		Array.isArray(b.ratings) &&
		ratingsEqual(a.ratings, b.ratings)
	);
}

export function matchesItemFilterA(item: ItemRecord): boolean {
	return item.priority >= 5 && item.active === true;
}

export function matchesItemFilterB(item: ItemRecord): boolean {
	return item.priority < 3 || item.tags.includes("urgent");
}

export function matchesEventFilterA(event: EventRecord): boolean {
	return event.score >= 50 && event.ratings.includes(5);
}

export function matchesEventFilterB(event: EventRecord): boolean {
	return event.score < 20 || event.ratings.includes(1);
}

const ITEMS_FILTER_A: QueryOptions = {
	where: { priority: { gte: 5 }, active: true },
};

const ITEMS_FILTER_B: QueryOptions = {
	where: { or: [{ priority: { lt: 3 } }, { tags: { contains: "urgent" } }] },
};

const EVENTS_FILTER_A: QueryOptions = {
	where: { score: { gte: 50 }, ratings: { contains: 5 } },
};

const EVENTS_FILTER_B: QueryOptions = {
	where: { or: [{ score: { lt: 20 } }, { ratings: { contains: 1 } }] },
};

export function createItemData(index: number): Omit<ItemRecord, "id"> {
	const mod = index % 10;
	const priority = mod + 1;
	const active = ![0, 1, 6].includes(mod);
	const tags = [0, 7].includes(mod) ? ["urgent"] : [];
	return {
		name: `item-${index}`,
		priority,
		active,
		tags,
	};
}

const SCORES = [10, 15, 30, 10, 50, 60, 70, 15, 80, 90];
const RATINGS_LIST = [
	[2, 3],
	[2, 4],
	[3, 4],
	[1, 2],
	[4, 5],
	[3, 5],
	[2, 3],
	[1, 3],
	[2, 4],
	[5, 6],
];

export function createEventData(index: number): Omit<EventRecord, "id"> {
	return {
		title: `event-${index}`,
		score: SCORES[index % 10],
		ratings: [...RATINGS_LIST[index % 10]],
	};
}

function getClientRole(localId: number): ClientRole {
	if (localId < STORE_CREATORS) return "creator";
	if (localId < STORE_CREATORS + STORE_UPDATERS) return "updater";
	if (localId < STORE_CREATORS + STORE_UPDATERS + PRESENCE_USER_WRITERS)
		return "presence-user";
	if (
		localId <
		STORE_CREATORS +
			STORE_UPDATERS +
			PRESENCE_USER_WRITERS +
			PRESENCE_SHARED_WRITERS
	)
		return "presence-shared";
	return "passive";
}

function failReadiness(context: ProcessContext, message: string): void {
	const error = new Error(`[process ${context.processIndex}] ${message}`);
	for (const waiter of context.readyWaiters.splice(0)) waiter.reject(error);
}

function markClientReady(context: ProcessContext, state: ClientState): void {
	if (state.ready) return;
	if (!state.storeSubscribed || !state.userReady || !state.sharedReady) {
		return;
	}
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
	const role = getClientRole(localId);
	const filterSet: "A" | "B" = localId < CLIENTS_PER_PROCESS / 2 ? "A" : "B";

	const client = createClient({
		url: `ws://127.0.0.1:${port}/v1/ws`,
		auth: {
			token: createTestJwt(jwtSecret, `combo-stress-${globalId}`),
		},
		presenceNamespace: `${PRESENCE_NAMESPACE_PREFIX}-${context.roomIndex}`,
		retryRateLimits: false,
		liveness: { enabled: false },
	});

	const state: ClientState = {
		client,
		globalId,
		localId,
		role,
		filterSet,
		storeSnapshot: [],
		storeRecords: new Map(),
		storeMapRevision: -1,
		storeFired: false,
		storeSubscribed: false,
		userReady: false,
		sharedReady: false,
		ready: false,
		userCallbacks: 0,
		sharedCallbacks: 0,
		lastPresenceData: null,
		disconnected: false,
		expectedDisconnect: false,
		storeRevision: 0,
		storeScannedRevision: -1,
		storeScannedBaselineRevision: -1,
		cachedStoreFailure: null,
		presenceRevision: 0,
		presenceScannedRevision: -1,
		cachedPresenceFailure: null,
	};

	client.on("error", (error) => {
		if (state.expectedDisconnect) return;
		// Transient connection churn is expected on slow machines; it must not
		// fail the run — the convergence timeouts are the failure signal.
		if (error.retryable && error.category === "network") return;
		context.errorCount++;
		const sample = `client ${globalId}: ${formatError(error)}`;
		if (context.errorSamples.length < 3) {
			context.errorSamples.push(sample);
		}
		failReadiness(context, sample);
	});

	client.on("connected", () => {
		state.disconnected = false;
		context.downClients.delete(state);
	});
	client.on("disconnected", (detail) => {
		state.disconnected = true;
		if (!state.expectedDisconnect) {
			context.downClients.add(state);
			if (!state.ready && !detail.retryable) {
				failReadiness(
					context,
					`client ${globalId} disconnected before readiness`,
				);
			}
		}
	});
	client.on("reconnected", () => {
		state.disconnected = false;
		context.downClients.delete(state);
		// The server drops a user's presence on disconnect; re-apply it.
		if (state.lastPresenceData !== null) {
			state.presenceRevision++;
			void state.client.presence.set(state.lastPresenceData);
		}
	});

	return state;
}

function healthIssue(context: ProcessContext): string | null {
	if (context.errorCount > 0) {
		return `${context.errorCount} client error(s): ${context.errorSamples.join("; ")}`;
	}
	for (const state of context.downClients) {
		if (!state.expectedDisconnect && state.client.status === "disconnected") {
			return `client ${state.globalId} disconnected unexpectedly`;
		}
	}
	return null;
}

function assertHealthy(context: ProcessContext, label: string) {
	const issue = healthIssue(context);
	if (issue) {
		throw new Error(`[process ${context.processIndex}] ${label}: ${issue}`);
	}
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

async function subscribeClient(
	context: ProcessContext,
	state: ClientState,
): Promise<void> {
	const filter =
		context.table === "items"
			? state.filterSet === "A"
				? ITEMS_FILTER_A
				: ITEMS_FILTER_B
			: state.filterSet === "A"
				? EVENTS_FILTER_A
				: EVENTS_FILTER_B;

	const storeSub = state.client.store.subscribe(
		context.table,
		filter,
		(items) => {
			state.storeSnapshot = items as unknown as (ItemRecord | EventRecord)[];
			state.storeFired = true;
			state.storeRevision++;
			context.storeGeneration++;
			context.lastStoreChangeMs = performance.now();
			markClientReady(context, state);
		},
	);

	const userSub = state.client.presence.subscribe(() => {
		state.userCallbacks++;
		state.userReady = true;
		state.presenceRevision++;
		context.presenceGeneration++;
		context.lastPresenceChangeMs = performance.now();
		markClientReady(context, state);
	});
	const sharedSub = state.client.presence.subscribeShared(() => {
		state.sharedCallbacks++;
		state.sharedReady = true;
		state.presenceRevision++;
		context.presenceGeneration++;
		context.lastPresenceChangeMs = performance.now();
		markClientReady(context, state);
	});
	await Promise.all([storeSub, userSub, sharedSub]);
	state.storeSubscribed = true;
	markClientReady(context, state);
}

function getStoreRecords(
	state: ClientState,
): Map<string, ItemRecord | EventRecord> {
	if (state.storeMapRevision !== state.storeRevision) {
		state.storeRecords.clear();
		for (const item of state.storeSnapshot) {
			state.storeRecords.set(item.id, item);
		}
		state.storeMapRevision = state.storeRevision;
	}
	return state.storeRecords;
}

type PreparationMetrics = {
	clientCreateMs: number;
	connectOnlyMs: number;
	subscribeMs: number;
	readinessMs: number;
};

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

function getSampleClients(clients: ClientState[]): ClientState[] {
	const sampled: ClientState[] = [];
	for (let i = 0; i < clients.length; i += CONVERGENCE_SAMPLE_STRIDE) {
		sampled.push(clients[i]);
	}
	return sampled;
}

type RoomPresenceExpectation = {
	writerIds: number[];
	writerFlags: Uint8Array;
	writerNameById: string[];
	expectedCount: number;
};

function buildRoomPresenceExpectation(
	roomIndex: number,
): RoomPresenceExpectation {
	const writerIds: number[] = [];
	const procA = roomIndex * 2;
	const procB = roomIndex * 2 + 1;
	for (let i = 0; i < PRESENCE_USER_WRITERS; i++) {
		writerIds.push(procA * CLIENTS_PER_PROCESS + 200 + i);
		writerIds.push(procB * CLIENTS_PER_PROCESS + 200 + i);
	}
	const writerFlags = new Uint8Array(TOTAL_CLIENTS);
	const writerNameById = new Array<string>(TOTAL_CLIENTS).fill("");
	for (const id of writerIds) {
		writerFlags[id] = 1;
		writerNameById[id] = `client-${id}`;
	}
	return {
		writerIds,
		writerFlags,
		writerNameById,
		expectedCount: writerIds.length,
	};
}

const ROOM_PRESENCE_EXPECTATIONS: RoomPresenceExpectation[] = Array.from(
	{ length: ROOM_COUNT },
	(_, roomIndex) => buildRoomPresenceExpectation(roomIndex),
);

type VerifyStats = {
	scannedClients: number;
	cachedClients: number;
};

function verifyClientRecordMatches<T extends ItemRecord | EventRecord>(
	first: ClientState,
	other: ClientState,
	label: "A" | "B",
	recordsEqual: (a: T, b: T) => boolean,
	stats: VerifyStats,
): string | null {
	if (
		other.storeScannedRevision === other.storeRevision &&
		other.storeScannedBaselineRevision === first.storeRevision &&
		other.cachedStoreFailure === null
	) {
		stats.cachedClients++;
		return null;
	}
	stats.scannedClients++;

	const firstRecords = getStoreRecords(first);
	const otherRecords = getStoreRecords(other);
	let failure: string | null = null;
	if (otherRecords.size !== firstRecords.size) {
		failure = `filter ${label} size mismatch: client ${first.globalId} has ${firstRecords.size}, client ${other.globalId} has ${otherRecords.size}`;
	} else {
		for (const [id, record] of firstRecords) {
			const otherRecord = otherRecords.get(id);
			if (!otherRecord) {
				failure = `client ${other.globalId} missing record ${id} vs client ${first.globalId}`;
				break;
			}
			if (!recordsEqual(record as T, otherRecord as T)) {
				failure = `client ${other.globalId} record ${id} value mismatch vs client ${first.globalId}`;
				break;
			}
		}
	}

	other.storeScannedRevision = other.storeRevision;
	other.storeScannedBaselineRevision = first.storeRevision;
	other.cachedStoreFailure = failure;
	return failure;
}

function verifyRecordsMatchPredicate<T extends ItemRecord | EventRecord>(
	records: Map<string, ItemRecord | EventRecord>,
	label: "A" | "B",
	matchesFilter: (record: T) => boolean,
): string | null {
	for (const [id, record] of records) {
		if (!matchesFilter(record as T)) {
			return `record ${id} does not match filter ${label}: ${JSON.stringify(record)}`;
		}
	}
	return null;
}

function verifyFilterGroup<T extends ItemRecord | EventRecord>(
	clients: ClientState[],
	label: "A" | "B",
	matchesFilter: (record: T) => boolean,
	recordsEqual: (a: T, b: T) => boolean,
	stats: VerifyStats,
): string | null {
	if (clients.length === 0) return null;
	for (const c of clients) {
		if (!c.storeFired) {
			return `client ${c.globalId} store subscription never fired`;
		}
	}

	const first = clients[0];
	const firstRecords = getStoreRecords(first);
	if (firstRecords.size === 0) {
		return `filter ${label} has 0 records`;
	}

	const predErr = verifyRecordsMatchPredicate(
		firstRecords,
		label,
		matchesFilter,
	);
	if (predErr) return predErr;

	for (let i = 1; i < clients.length; i++) {
		const err = verifyClientRecordMatches(
			first,
			clients[i],
			label,
			recordsEqual,
			stats,
		);
		if (err) return err;
	}

	return null;
}

function verifyStore(
	context: ProcessContext,
	sampledClients: ClientState[],
	stats: VerifyStats,
): string | null {
	const isItems = context.table === "items";
	const filterAClients = sampledClients.filter((c) => c.filterSet === "A");
	const filterBClients = sampledClients.filter((c) => c.filterSet === "B");

	const errA = isItems
		? verifyFilterGroup<ItemRecord>(
				filterAClients,
				"A",
				matchesItemFilterA,
				itemsEqual,
				stats,
			)
		: verifyFilterGroup<EventRecord>(
				filterAClients,
				"A",
				matchesEventFilterA,
				eventsEqual,
				stats,
			);
	if (errA) return errA;

	const errB = isItems
		? verifyFilterGroup<ItemRecord>(
				filterBClients,
				"B",
				matchesItemFilterB,
				itemsEqual,
				stats,
			)
		: verifyFilterGroup<EventRecord>(
				filterBClients,
				"B",
				matchesEventFilterB,
				eventsEqual,
				stats,
			);
	if (errB) return errB;

	return null;
}

type PresenceEntryScan = {
	missing: number;
	duplicate: number;
	unexpected: number;
	stale: number;
	samples: string[];
};

const presenceSeenScratch = new Uint32Array(TOTAL_CLIENTS);
let presenceScanGeneration = 0;

function addPresenceSample(scan: PresenceEntryScan, message: string): void {
	if (scan.samples.length < 5) scan.samples.push(message);
}

function scanPresenceEntries(
	entries: PresenceEntry[],
	expected: RoomPresenceExpectation,
	scan: PresenceEntryScan,
): void {
	const seen = presenceSeenScratch;
	// Wrapping back to 0 is harmless: a stale stamp only has to differ from
	// the current generation, and wrap-around needs 2^32 scans to collide.
	presenceScanGeneration = (presenceScanGeneration + 1) >>> 0;
	const generation = presenceScanGeneration;

	for (const entry of entries) {
		const data = entry.data;
		const cursorRaw = data.cursor;
		const cursor = isRecord(cursorRaw)
			? (cursorRaw as { x?: unknown; y?: unknown })
			: undefined;
		const id = cursor?.x;
		if (
			typeof id !== "number" ||
			!Number.isInteger(id) ||
			id < 0 ||
			id >= TOTAL_CLIENTS ||
			expected.writerFlags[id] !== 1
		) {
			scan.unexpected++;
			addPresenceSample(scan, `unexpected ${JSON.stringify(data)}`);
			continue;
		}
		if (seen[id] === generation) {
			scan.duplicate++;
			addPresenceSample(scan, `duplicate ${id}`);
		} else {
			seen[id] = generation;
		}
		if (
			cursor?.y !== 2 ||
			data.name !== expected.writerNameById[id] ||
			data.status !== "active"
		) {
			scan.stale++;
			addPresenceSample(scan, `stale ${id}: ${JSON.stringify(data)}`);
		}
	}

	for (const id of expected.writerIds) {
		if (seen[id] !== generation) {
			scan.missing++;
			addPresenceSample(scan, `missing ${id}`);
		}
	}
}

function verifyClientPresence(
	state: ClientState,
	expected: RoomPresenceExpectation,
	expectedSlide: number,
	expectedPlaying: boolean,
	stats: VerifyStats,
): string | null {
	if (
		state.presenceScannedRevision === state.presenceRevision &&
		state.cachedPresenceFailure === null
	) {
		stats.cachedClients++;
		return null;
	}
	stats.scannedClients++;

	const entries = state.client.presence.getAll({ includeSelf: true });
	const scan: PresenceEntryScan = {
		missing: 0,
		duplicate: 0,
		unexpected: 0,
		stale: 0,
		samples: [],
	};
	scanPresenceEntries(entries, expected, scan);

	let failure: string | null = null;
	if (
		scan.missing !== 0 ||
		scan.duplicate !== 0 ||
		scan.unexpected !== 0 ||
		scan.stale !== 0
	) {
		failure =
			`client ${state.globalId}: expected ${expected.expectedCount}, got ${entries.length}; ` +
			`missing=${scan.missing}, duplicate=${scan.duplicate}, unexpected=${scan.unexpected}, stale=${scan.stale}` +
			(scan.samples.length > 0 ? ` (${scan.samples.join(", ")})` : "");
	} else {
		const shared = state.client.presence.getShared();
		if (!shared) {
			failure = `client ${state.globalId} shared presence is null`;
		} else if (
			shared.slide !== expectedSlide ||
			shared.playing !== expectedPlaying
		) {
			failure = `client ${state.globalId} shared state mismatch: expected slide=${expectedSlide}, playing=${expectedPlaying}; got slide=${shared.slide}, playing=${shared.playing}`;
		}
	}

	state.presenceScannedRevision = state.presenceRevision;
	state.cachedPresenceFailure = failure;
	return failure;
}

function verifyPresence(
	context: ProcessContext,
	sampledClients: ClientState[],
	stats: VerifyStats,
): string | null {
	const expected = ROOM_PRESENCE_EXPECTATIONS[context.roomIndex];
	const expectedSlide = context.roomIndex * 100 + 2;
	const expectedPlaying = false;

	const failures: string[] = [];
	for (const state of sampledClients) {
		const err = verifyClientPresence(
			state,
			expected,
			expectedSlide,
			expectedPlaying,
			stats,
		);
		if (err) failures.push(err);
		if (failures.length === 5) break;
	}

	return failures.length === 0 ? null : failures.join(" | ");
}

type GenerationTracker = {
	lastGen: number;
	lastChanged: number;
	lastVerified: number;
};

function shouldWaitForQuiet(
	currentGen: number,
	state: GenerationTracker,
	now: number,
): boolean {
	if (currentGen !== state.lastGen) {
		state.lastGen = currentGen;
		state.lastChanged = now;
		state.lastVerified = 0;
		return true;
	}
	if (now - state.lastChanged < QUIET_WINDOW_MS) return true;
	return now - state.lastVerified < VERIFY_RETRY_INTERVAL_MS;
}

async function waitForStoreConvergence(
	context: ProcessContext,
	sampledClients: ClientState[],
): Promise<ConvergenceStats> {
	const started = performance.now();
	const deadline = started + CONVERGENCE_TIMEOUT_MS;
	const genTracker: GenerationTracker = {
		lastGen: context.storeGeneration,
		lastChanged: performance.now(),
		lastVerified: 0,
	};
	const stats: ConvergenceStats = {
		elapsedMs: 0,
		verifyMs: 0,
		passes: 0,
		scannedClients: 0,
		cachedClients: 0,
	};
	let lastFailure = "no quiet window";

	while (performance.now() < deadline) {
		assertHealthy(context, "store-converge");
		const now = performance.now();
		if (shouldWaitForQuiet(context.storeGeneration, genTracker, now)) {
			await delay(10);
			continue;
		}

		const genBefore = context.storeGeneration;
		genTracker.lastVerified = performance.now();
		const verifyStats: VerifyStats = { scannedClients: 0, cachedClients: 0 };
		const verifyStart = performance.now();
		const failure = verifyStore(context, sampledClients, verifyStats);
		stats.verifyMs += performance.now() - verifyStart;
		stats.passes++;
		stats.scannedClients += verifyStats.scannedClients;
		stats.cachedClients += verifyStats.cachedClients;
		if (context.storeGeneration !== genBefore) {
			genTracker.lastGen = context.storeGeneration;
			genTracker.lastChanged = performance.now();
			await delay(10);
			continue;
		}

		if (failure === null) {
			stats.elapsedMs = performance.now() - started;
			return stats;
		}
		lastFailure = failure;

		await delay(10);
	}

	throw new Error(
		`[process ${context.processIndex}] store did not converge in ${CONVERGENCE_TIMEOUT_MS}ms: ${lastFailure}`,
	);
}

async function waitForPresenceConvergence(
	context: ProcessContext,
	sampledClients: ClientState[],
): Promise<ConvergenceStats> {
	const started = performance.now();
	const deadline = started + CONVERGENCE_TIMEOUT_MS;
	const genTracker: GenerationTracker = {
		lastGen: context.presenceGeneration,
		lastChanged: performance.now(),
		lastVerified: 0,
	};
	const stats: ConvergenceStats = {
		elapsedMs: 0,
		verifyMs: 0,
		passes: 0,
		scannedClients: 0,
		cachedClients: 0,
	};
	let lastFailure = "no quiet window";

	while (performance.now() < deadline) {
		assertHealthy(context, "presence-converge");
		const now = performance.now();
		if (shouldWaitForQuiet(context.presenceGeneration, genTracker, now)) {
			await delay(10);
			continue;
		}

		const genBefore = context.presenceGeneration;
		genTracker.lastVerified = performance.now();
		const verifyStats: VerifyStats = { scannedClients: 0, cachedClients: 0 };
		const verifyStart = performance.now();
		const failure = verifyPresence(context, sampledClients, verifyStats);
		stats.verifyMs += performance.now() - verifyStart;
		stats.passes++;
		stats.scannedClients += verifyStats.scannedClients;
		stats.cachedClients += verifyStats.cachedClients;
		if (context.presenceGeneration !== genBefore) {
			genTracker.lastGen = context.presenceGeneration;
			genTracker.lastChanged = performance.now();
			await delay(10);
			continue;
		}

		if (failure === null) {
			stats.elapsedMs = performance.now() - started;
			return stats;
		}
		lastFailure = failure;

		await delay(10);
	}

	throw new Error(
		`[process ${context.processIndex}] presence did not converge in ${CONVERGENCE_TIMEOUT_MS}ms: ${lastFailure}`,
	);
}

async function cleanupClients(clients: ClientState[]) {
	for (const state of clients) {
		// No explicit unsubscribes: the socket close tears down server-side
		// subscriptions, and unsubscribe sends dominate teardown cost.
		state.expectedDisconnect = true;
		state.client.disconnect();
	}
	await delay(0);
}

async function executeStoreCreates(
	context: ProcessContext,
	createdDocIds: string[],
): Promise<void> {
	const creators = context.clients.slice(0, STORE_CREATORS);
	await Promise.all(
		creators.map(async (state, idx) => {
			const recordIndex = context.processIndex * 100 + idx;
			const isItems = context.table === "items";
			const data = isItems
				? createItemData(recordIndex)
				: createEventData(recordIndex);
			const id = state.client.utils.id();
			await withConnectionRetry(() =>
				state.client.store.set([context.table, id], data),
			);
			createdDocIds[idx] = id;
		}),
	);
}

async function executeStoreUpdates(
	context: ProcessContext,
	createdDocIds: string[],
): Promise<void> {
	const updaters = context.clients.slice(
		STORE_CREATORS,
		STORE_CREATORS + STORE_UPDATERS,
	);
	await Promise.all(
		updaters.map(async (state, idx) => {
			const docId = createdDocIds[idx];
			const seed = context.processIndex * 10_000 + idx * 32;
			if (context.table === "items") {
				await withConnectionRetry(() =>
					state.client.store.set(["items", docId], {
						name: `updated-item-${context.processIndex * 100 + idx}`,
						priority: Math.floor(deterministicUnit(seed + 1) * 10) + 1,
						active: deterministicUnit(seed + 2) > 0.5,
						tags:
							deterministicUnit(seed + 3) > 0.5
								? ["urgent", "updated"]
								: ["updated"],
					}),
				);
			} else {
				await withConnectionRetry(() =>
					state.client.store.set(["events", docId], {
						title: `updated-event-${context.processIndex * 100 + idx}`,
						score: Math.floor(deterministicUnit(seed + 4) * 100),
						ratings: deterministicUnit(seed + 5) > 0.5 ? [1, 5] : [2, 3],
					}),
				);
			}
		}),
	);
}

async function executePresenceUserWrites(
	context: ProcessContext,
): Promise<void> {
	const userWriters = context.clients.slice(
		STORE_CREATORS + STORE_UPDATERS,
		STORE_CREATORS + STORE_UPDATERS + PRESENCE_USER_WRITERS,
	);
	for (let tick = 0; tick < 3; tick++) {
		for (const state of userWriters) {
			const fullData = {
				name: `client-${state.globalId}`,
				status: "active",
				cursor: { x: state.globalId, y: tick },
			};
			state.lastPresenceData = fullData;
			state.presenceRevision++;
			state.client.presence.set(
				PRESENCE_FULL_PAYLOAD || tick === 0
					? fullData
					: { cursor: fullData.cursor },
			);
		}
		if (tick < 2) await delay(PRESENCE_TICK_DELAY_MS);
	}
}

async function executePresenceSharedWrites(
	context: ProcessContext,
): Promise<void> {
	const sharedWriters = context.clients.slice(
		STORE_CREATORS + STORE_UPDATERS + PRESENCE_USER_WRITERS,
		STORE_CREATORS +
			STORE_UPDATERS +
			PRESENCE_USER_WRITERS +
			PRESENCE_SHARED_WRITERS,
	);
	for (let tick = 0; tick < 3; tick++) {
		for (const state of sharedWriters) {
			state.presenceRevision++;
			state.client.presence.setShared({
				slide: context.roomIndex * 100 + tick,
				playing: tick % 2 === 1,
			});
		}
		if (tick < 2) await delay(PRESENCE_TICK_DELAY_MS);
	}
}

async function runProcess(
	port: number,
	processIndex: number,
	jwtSecret: string,
	barrier: (phase: BarrierPhase) => Promise<void>,
): Promise<ProcessMetrics> {
	const roomIndex = PROCESS_ROOM[processIndex];
	const table = PROCESS_TABLE[processIndex];
	const context: ProcessContext = {
		processIndex,
		roomIndex,
		table,
		clients: [],
		storeGeneration: 0,
		presenceGeneration: 0,
		lastStoreChangeMs: performance.now(),
		lastPresenceChangeMs: performance.now(),
		errorCount: 0,
		errorSamples: [],
		downClients: new Set(),
		readyCount: 0,
		readyWaiters: [],
	};

	const metrics: ProcessMetrics = {
		processIndex,
		clientCreateMs: 0,
		connectMs: 0,
		connectOnlyMs: 0,
		subscribeMs: 0,
		readinessMs: 0,
		cleanupMs: 0,
		barrierWaitMs: {},
		storeCreateMs: 0,
		storeUpdateMs: 0,
		presenceUserMs: 0,
		presenceSharedMs: 0,
		storeConvergeMs: 0,
		presenceConvergeMs: 0,
		storeVerifyMs: 0,
		storeVerifyPasses: 0,
		storeScannedClients: 0,
		storeCachedClients: 0,
		presenceVerifyMs: 0,
		presenceVerifyPasses: 0,
		presenceScannedClients: 0,
		presenceCachedClients: 0,
		filterACount: 0,
		filterBCount: 0,
		userPresenceCount: 0,
		userCallbacks: [],
		sharedCallbacks: [],
		storeCallbacks: 0,
		presenceCallbacks: 0,
		lastStoreDeltaMs: 0,
		lastPresenceDeltaMs: 0,
	};

	const waitAtBarrier = async (phase: BarrierPhase): Promise<void> => {
		const start = performance.now();
		await barrier(phase);
		metrics.barrierWaitMs[phase] = performance.now() - start;
	};

	const createdDocIds: string[] = [];

	try {
		// Phase 1: Connect and subscribe
		const startConnect = performance.now();
		const preparation = await prepareClients(context, port, jwtSecret);
		metrics.connectMs = performance.now() - startConnect;
		metrics.clientCreateMs = preparation.clientCreateMs;
		metrics.connectOnlyMs = preparation.connectOnlyMs;
		metrics.subscribeMs = preparation.subscribeMs;
		metrics.readinessMs = preparation.readinessMs;
		await waitAtBarrier("ready");

		// Phase 2: First 100 clients create 1 document each
		const startCreate = performance.now();
		await executeStoreCreates(context, createdDocIds);
		metrics.storeCreateMs = performance.now() - startCreate;
		await waitAtBarrier("store-create");

		// Phase 3: Second 100 clients update 1 document each
		const startUpdate = performance.now();
		await executeStoreUpdates(context, createdDocIds);
		metrics.storeUpdateMs = performance.now() - startUpdate;
		await waitAtBarrier("store-update");

		// Phase 4: Third 100 clients write 3 user presence updates
		const startPresenceUser = performance.now();
		await executePresenceUserWrites(context);
		metrics.presenceUserMs = performance.now() - startPresenceUser;
		await waitAtBarrier("presence-user");

		// Phase 5: Fourth 100 clients write 3 shared presence updates
		const startPresenceShared = performance.now();
		await executePresenceSharedWrites(context);
		metrics.presenceSharedMs = performance.now() - startPresenceShared;
		await waitAtBarrier("presence-shared");

		// Phase 6: Convergence check with stride 5
		const sampled = getSampleClients(context.clients);
		const convergeStart = performance.now();
		const [storeConverge, presenceConverge] = await Promise.all([
			waitForStoreConvergence(context, sampled),
			waitForPresenceConvergence(context, sampled),
		]);
		metrics.storeConvergeMs = storeConverge.elapsedMs;
		metrics.presenceConvergeMs = presenceConverge.elapsedMs;
		metrics.storeVerifyMs = storeConverge.verifyMs;
		metrics.storeVerifyPasses = storeConverge.passes;
		metrics.storeScannedClients = storeConverge.scannedClients;
		metrics.storeCachedClients = storeConverge.cachedClients;
		metrics.presenceVerifyMs = presenceConverge.verifyMs;
		metrics.presenceVerifyPasses = presenceConverge.passes;
		metrics.presenceScannedClients = presenceConverge.scannedClients;
		metrics.presenceCachedClients = presenceConverge.cachedClients;
		metrics.storeCallbacks = context.storeGeneration;
		metrics.presenceCallbacks = context.presenceGeneration;
		metrics.lastStoreDeltaMs = Math.round(
			context.lastStoreChangeMs - convergeStart,
		);
		metrics.lastPresenceDeltaMs = Math.round(
			context.lastPresenceChangeMs - convergeStart,
		);

		const sampleA = sampled.find((c) => c.filterSet === "A");
		const sampleB = sampled.find((c) => c.filterSet === "B");
		metrics.filterACount = sampleA ? getStoreRecords(sampleA).size : 0;
		metrics.filterBCount = sampleB ? getStoreRecords(sampleB).size : 0;
		metrics.userPresenceCount =
			sampled[0]?.client.presence.getAll({ includeSelf: true }).length ?? 0;

		await waitAtBarrier("converge");

		metrics.userCallbacks = context.clients.map((s) => s.userCallbacks);
		metrics.sharedCallbacks = context.clients.map((s) => s.sharedCallbacks);
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
					`Combo stress worker ${processIndex} reached ${phase}, expected ${expected}`,
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
					`Combo stress worker ${processIndex} sent an invalid IPC message`,
				),
			);
			return;
		}
		if (message.type === "barrier") {
			if (isBarrierPhase(message.phase)) handleBarrier(message.phase);
			else
				fail(new Error(`Combo stress worker ${processIndex} sent a bad phase`));
			return;
		}
		if (message.type === "result") {
			resultReceived = true;
			result.resolve((message as unknown as WorkerResultMessage).result);
			return;
		}
		fail(
			new Error(`Combo stress worker ${processIndex} sent an unknown message`),
		);
	};

	const workerCommand = [process.execPath];
	const profileDir = process.env.ZYNCBASE_COMBO_PROFILE_DIR;
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
					`Combo stress worker ${processIndex} exited with code ${exitCode}${resultReceived ? "" : " before reporting results"}`,
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
		Math.round(Math.max(...results.map((r) => r[key] as number)));
	const round = (value: number) => Math.round(value);
	const userCallbacks = results.flatMap((r) => r.userCallbacks);
	const sharedCallbacks = results.flatMap((r) => r.sharedCallbacks);
	console.log(
		`Combo stress passed: ${TOTAL_CLIENTS} clients across 4 processes (${ROOM_COUNT} rooms, 2 tables) in ${Math.round(elapsedMs)}ms; ` +
			`phase max ms connect=${max("connectMs")}, ` +
			`store-create=${max("storeCreateMs")}, store-update=${max("storeUpdateMs")}, ` +
			`presence-user=${max("presenceUserMs")}, presence-shared=${max("presenceSharedMs")}, ` +
			`store-converge=${max("storeConvergeMs")}, presence-converge=${max("presenceConvergeMs")}`,
	);
	console.log(
		`Combo stress setup max ms client-create=${max("clientCreateMs")}, ` +
			`connect-only=${max("connectOnlyMs")}, subscribe=${max("subscribeMs")}, ` +
			`readiness=${max("readinessMs")}, cleanup=${max("cleanupMs")}`,
	);
	console.log(
		`Combo stress verify max ms store=${max("storeVerifyMs")} ` +
			`(passes=${max("storeVerifyPasses")}, scanned=${max("storeScannedClients")}, cached=${max("storeCachedClients")}), ` +
			`presence=${max("presenceVerifyMs")} ` +
			`(passes=${max("presenceVerifyPasses")}, scanned=${max("presenceScannedClients")}, cached=${max("presenceCachedClients")})`,
	);
	console.log(
		`Combo stress delivered: store-callbacks=${max("storeCallbacks")}, presence-callbacks=${max("presenceCallbacks")}, ` +
			`last-change-into-converge ms store=${max("lastStoreDeltaMs")}, presence=${max("lastPresenceDeltaMs")}`,
	);
	console.log(
		`Combo stress callbacks: user p50/p95/max=${percentile(userCallbacks, 0.5)}/${percentile(userCallbacks, 0.95)}/${Math.max(...userCallbacks)}, ` +
			`shared p50/p95/max=${percentile(sharedCallbacks, 0.5)}/${percentile(sharedCallbacks, 0.95)}/${Math.max(...sharedCallbacks)}`,
	);
	for (const result of results) {
		console.log(
			`  proc ${result.processIndex}: create=${round(result.clientCreateMs)} ` +
				`connect=${round(result.connectMs)} (only=${round(result.connectOnlyMs)}, ` +
				`subscribe=${round(result.subscribeMs)}, ready=${round(result.readinessMs)}) ` +
				`store=${round(result.storeCreateMs)}/${round(result.storeUpdateMs)} ` +
				`presence=${round(result.presenceUserMs)}/${round(result.presenceSharedMs)} ` +
				`converge=${round(result.storeConvergeMs)}/${round(result.presenceConvergeMs)} ` +
				`verify=${round(result.storeVerifyMs)}/${round(result.presenceVerifyMs)} ` +
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

function assertCrossProcessConsistency(allMetrics: ProcessMetrics[]) {
	// Process 0 and Process 2 both use "items"
	if (allMetrics[0].filterACount !== allMetrics[2].filterACount) {
		throw new Error(
			`Cross-process items filter A mismatch: proc 0 has ${allMetrics[0].filterACount}, proc 2 has ${allMetrics[2].filterACount}`,
		);
	}
	if (allMetrics[0].filterBCount !== allMetrics[2].filterBCount) {
		throw new Error(
			`Cross-process items filter B mismatch: proc 0 has ${allMetrics[0].filterBCount}, proc 2 has ${allMetrics[2].filterBCount}`,
		);
	}

	// Process 1 and Process 3 both use "events"
	if (allMetrics[1].filterACount !== allMetrics[3].filterACount) {
		throw new Error(
			`Cross-process events filter A mismatch: proc 1 has ${allMetrics[1].filterACount}, proc 3 has ${allMetrics[3].filterACount}`,
		);
	}
	if (allMetrics[1].filterBCount !== allMetrics[3].filterBCount) {
		throw new Error(
			`Cross-process events filter B mismatch: proc 1 has ${allMetrics[1].filterBCount}, proc 3 has ${allMetrics[3].filterBCount}`,
		);
	}

	// All processes should see exactly 200 presence entries
	for (const m of allMetrics) {
		if (m.userPresenceCount !== 200) {
			throw new Error(
				`Process ${m.processIndex} expected 200 presence entries, saw ${m.userPresenceCount}`,
			);
		}
	}
}

export async function run(port: number, jwtSecret: string) {
	if (process.env.ZYNCBASE_COMBO_DEBUG === "1") {
		console.log(
			`[combo] sdk module: ${import.meta.resolve("@zyncbase/client")}`,
		);
	}
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
		const failedWorker = exitCodes.findIndex((code) => code !== 0);
		if (failedWorker !== -1) {
			throw new Error(
				`Combo stress worker ${failedWorker + 1} exited with code ${exitCodes[failedWorker]}`,
			);
		}

		const allMetrics = [local.value, ...remote.value];
		reportMetrics(allMetrics, performance.now() - started);
		assertCrossProcessConsistency(allMetrics);
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
			"usage: test-combo-stress.ts --worker <port> <process-index> <jwt-secret>",
		);
	}
	if (!process.send) {
		throw new Error("Combo stress worker requires an IPC channel");
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
