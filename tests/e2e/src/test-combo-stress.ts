import {
	createClient,
	type QueryOptions,
	type SubscriptionHandle,
	type ZyncBaseClient,
} from "@zyncbase/client";
import { createTestJwt } from "./harness";

// Top-level topology configuration
const ROOM_COUNT = 2;
const PROCESS_COUNT = 4;
const CLIENTS_PER_PROCESS = 2500;
const TOTAL_CLIENTS = PROCESS_COUNT * CLIENTS_PER_PROCESS; // 10,000
const CONNECT_BATCH_SIZE = 50;

// Writer role boundaries within each process (first 400 clients)
const STORE_CREATORS = 100; // localId 0..99
const STORE_UPDATERS = 100; // localId 100..199
const PRESENCE_USER_WRITERS = 100; // localId 200..299
const PRESENCE_SHARED_WRITERS = 100; // localId 300..399
// localId 400..2499 are passive subscribers

// Convergence sampling optimization: check every 5th client
const CONVERGENCE_SAMPLE_STRIDE = 5;

const QUIET_WINDOW_MS = 100;
const CONVERGENCE_TIMEOUT_MS = 40_000;
const CONNECT_TIMEOUT_MS = 15_000;
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
	storeSub: SubscriptionHandle | null;
	storeRecords: Map<string, ItemRecord | EventRecord>;
	storeFired: boolean;

	// Presence tracking
	userReady: boolean;
	sharedReady: boolean;
	userCallbacks: number;
	sharedCallbacks: number;
	presenceSubChanges: (() => void) | null;
	presenceSubShared: (() => void) | null;

	// Health tracking
	errorCount: number;
	errorSamples: string[];
	disconnected: boolean;
	expectedDisconnect: boolean;
};

export type ProcessContext = {
	processIndex: number;
	roomIndex: number;
	table: "items" | "events";
	clients: ClientState[];
	storeGeneration: number;
	presenceGeneration: number;
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

export type ProcessMetrics = {
	processIndex: number;
	connectMs: number;
	storeSubMs: number;
	presenceSubMs: number;
	storeCreateMs: number;
	storeUpdateMs: number;
	presenceUserMs: number;
	presenceSharedMs: number;
	storeConvergeMs: number;
	presenceConvergeMs: number;
	filterACount: number;
	filterBCount: number;
	userPresenceCount: number;
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
	});

	const state: ClientState = {
		client,
		globalId,
		localId,
		role,
		filterSet,
		storeSub: null,
		storeRecords: new Map(),
		storeFired: false,
		userReady: false,
		sharedReady: false,
		userCallbacks: 0,
		sharedCallbacks: 0,
		presenceSubChanges: null,
		presenceSubShared: null,
		errorCount: 0,
		errorSamples: [],
		disconnected: false,
		expectedDisconnect: false,
	};

	client.on("error", (error) => {
		if (state.expectedDisconnect && formatError(error) === "Disconnected") {
			return;
		}
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

function assertHealthy(context: ProcessContext, label: string) {
	const issue = healthIssue(context);
	if (issue) {
		throw new Error(`[process ${context.processIndex}] ${label}: ${issue}`);
	}
}

async function waitForReadiness(context: ProcessContext): Promise<void> {
	while (
		!context.clients.every(
			(state) =>
				state.userReady &&
				state.sharedReady &&
				(
					state.client as unknown as {
						tracker?: { subscriptions?: Map<number, unknown> };
					}
				).tracker?.subscriptions?.size === 1,
		)
	) {
		const issue = healthIssue(context);
		if (issue) throw new Error(`[process ${context.processIndex}] ${issue}`);
		await delay(10);
	}
}

async function connectClientBatch(batch: ClientState[]): Promise<void> {
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

function subscribeClient(context: ProcessContext, state: ClientState): void {
	const filter =
		context.table === "items"
			? state.filterSet === "A"
				? ITEMS_FILTER_A
				: ITEMS_FILTER_B
			: state.filterSet === "A"
				? EVENTS_FILTER_A
				: EVENTS_FILTER_B;

	state.storeSub = state.client.store.subscribe(
		context.table,
		filter,
		(items) => {
			state.storeFired = true;
			state.storeRecords.clear();
			for (const item of items as unknown as (ItemRecord | EventRecord)[]) {
				state.storeRecords.set(item.id, item);
			}
			context.storeGeneration++;
		},
	);

	state.presenceSubChanges = state.client.presence.subscribeChanges(() => {
		state.userCallbacks++;
		state.userReady = true;
		context.presenceGeneration++;
	});

	state.presenceSubShared = state.client.presence.subscribeShared(() => {
		state.sharedCallbacks++;
		state.sharedReady = true;
		context.presenceGeneration++;
	});
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

			// Batch connections to prevent server socket storm
			for (
				let offset = 0;
				offset < context.clients.length;
				offset += CONNECT_BATCH_SIZE
			) {
				const batch = context.clients.slice(
					offset,
					offset + CONNECT_BATCH_SIZE,
				);
				await connectClientBatch(batch);
			}

			for (const state of context.clients) {
				subscribeClient(context, state);
			}

			await waitForReadiness(context);
		})(),
		CONNECT_TIMEOUT_MS,
		`process ${context.processIndex} connection and subscription readiness`,
	);
}

function getSampleClients(clients: ClientState[]): ClientState[] {
	const sampled: ClientState[] = [];
	for (let i = 0; i < clients.length; i += CONVERGENCE_SAMPLE_STRIDE) {
		sampled.push(clients[i]);
	}
	return sampled;
}

export function getExpectedRoomWriters(roomIndex: number): Set<number> {
	const set = new Set<number>();
	const procA = roomIndex * 2;
	const procB = roomIndex * 2 + 1;
	for (let i = 0; i < PRESENCE_USER_WRITERS; i++) {
		set.add(procA * CLIENTS_PER_PROCESS + 200 + i);
		set.add(procB * CLIENTS_PER_PROCESS + 200 + i);
	}
	return set;
}

function verifyClientRecordMatches<T extends ItemRecord | EventRecord>(
	first: ClientState,
	other: ClientState,
	label: "A" | "B",
	recordsEqual: (a: T, b: T) => boolean,
): string | null {
	if (other.storeRecords.size !== first.storeRecords.size) {
		return `filter ${label} size mismatch: client ${first.globalId} has ${first.storeRecords.size}, client ${other.globalId} has ${other.storeRecords.size}`;
	}
	for (const [id, record] of first.storeRecords) {
		const otherRecord = other.storeRecords.get(id);
		if (!otherRecord) {
			return `client ${other.globalId} missing record ${id} vs client ${first.globalId}`;
		}
		if (!recordsEqual(record as T, otherRecord as T)) {
			return `client ${other.globalId} record ${id} value mismatch vs client ${first.globalId}`;
		}
	}
	return null;
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
): string | null {
	if (clients.length === 0) return null;
	for (const c of clients) {
		if (!c.storeFired) {
			return `client ${c.globalId} store subscription never fired`;
		}
	}

	const first = clients[0];
	if (first.storeRecords.size === 0) {
		return `filter ${label} has 0 records`;
	}

	const predErr = verifyRecordsMatchPredicate(
		first.storeRecords,
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
		);
		if (err) return err;
	}

	return null;
}

function verifyStore(
	context: ProcessContext,
	sampledClients: ClientState[],
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
			)
		: verifyFilterGroup<EventRecord>(
				filterAClients,
				"A",
				matchesEventFilterA,
				eventsEqual,
			);
	if (errA) return errA;

	const errB = isItems
		? verifyFilterGroup<ItemRecord>(
				filterBClients,
				"B",
				matchesItemFilterB,
				itemsEqual,
			)
		: verifyFilterGroup<EventRecord>(
				filterBClients,
				"B",
				matchesEventFilterB,
				eventsEqual,
			);
	if (errB) return errB;

	return null;
}

function verifyUserPresenceEntry(
	state: ClientState,
	entry: Record<string, unknown>,
	expectedWriters: Set<number>,
): string | null {
	const data = entry.data as Record<string, unknown> | undefined;
	const cursor = data?.cursor as { x?: number; y?: number } | undefined;
	const id = cursor?.x;
	if (typeof id !== "number" || !expectedWriters.has(id)) {
		return `client ${state.globalId} saw unexpected user presence entry: ${JSON.stringify(data)}`;
	}
	if (
		cursor?.y !== 2 ||
		data?.name !== `client-${id}` ||
		data?.status !== "active"
	) {
		return `client ${state.globalId} saw stale presence entry for user ${id}: ${JSON.stringify(data)}`;
	}
	return null;
}

function verifyClientPresence(
	state: ClientState,
	expectedCount: number,
	expectedWriters: Set<number>,
	expectedSlide: number,
	expectedPlaying: boolean,
): string | null {
	const entries = state.client.presence.getAll({ includeSelf: true });
	if (entries.length !== expectedCount) {
		return `client ${state.globalId} expected ${expectedCount} presence entries, got ${entries.length}`;
	}

	for (const entry of entries) {
		const err = verifyUserPresenceEntry(
			state,
			entry as unknown as Record<string, unknown>,
			expectedWriters,
		);
		if (err) return err;
	}

	const shared = state.client.presence.getShared();
	if (!shared) {
		return `client ${state.globalId} shared presence is null`;
	}
	if (shared.slide !== expectedSlide || shared.playing !== expectedPlaying) {
		return `client ${state.globalId} shared state mismatch: expected slide=${expectedSlide}, playing=${expectedPlaying}; got slide=${shared.slide}, playing=${shared.playing}`;
	}
	return null;
}

function verifyPresence(
	context: ProcessContext,
	sampledClients: ClientState[],
): string | null {
	const expectedWriters = getExpectedRoomWriters(context.roomIndex);
	const expectedCount = expectedWriters.size;
	const expectedSlide = context.roomIndex * 100 + 2;
	const expectedPlaying = false;

	for (const state of sampledClients) {
		const err = verifyClientPresence(
			state,
			expectedCount,
			expectedWriters,
			expectedSlide,
			expectedPlaying,
		);
		if (err) return err;
	}

	return null;
}

type GenerationTracker = {
	lastGen: number;
	lastChanged: number;
	checkedGen: number;
};

function shouldWaitForQuiet(
	currentGen: number,
	state: GenerationTracker,
	now: number,
): boolean {
	if (currentGen !== state.lastGen) {
		state.lastGen = currentGen;
		state.lastChanged = now;
		state.checkedGen = -1;
		return true;
	}
	return (
		now - state.lastChanged < QUIET_WINDOW_MS || state.checkedGen === currentGen
	);
}

async function waitForStoreConvergence(
	context: ProcessContext,
	sampledClients: ClientState[],
): Promise<number> {
	const started = performance.now();
	const deadline = started + CONVERGENCE_TIMEOUT_MS;
	const genTracker: GenerationTracker = {
		lastGen: context.storeGeneration,
		lastChanged: performance.now(),
		checkedGen: -1,
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
		const failure = verifyStore(context, sampledClients);
		if (context.storeGeneration !== genBefore) {
			genTracker.lastGen = context.storeGeneration;
			genTracker.lastChanged = performance.now();
			genTracker.checkedGen = -1;
			await delay(10);
			continue;
		}

		genTracker.checkedGen = context.storeGeneration;
		if (failure === null) return performance.now() - started;
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
): Promise<number> {
	const started = performance.now();
	const deadline = started + CONVERGENCE_TIMEOUT_MS;
	const genTracker: GenerationTracker = {
		lastGen: context.presenceGeneration,
		lastChanged: performance.now(),
		checkedGen: -1,
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
		const failure = verifyPresence(context, sampledClients);
		if (context.presenceGeneration !== genBefore) {
			genTracker.lastGen = context.presenceGeneration;
			genTracker.lastChanged = performance.now();
			genTracker.checkedGen = -1;
			await delay(10);
			continue;
		}

		genTracker.checkedGen = context.presenceGeneration;
		if (failure === null) return performance.now() - started;
		lastFailure = failure;

		await delay(10);
	}

	throw new Error(
		`[process ${context.processIndex}] presence did not converge in ${CONVERGENCE_TIMEOUT_MS}ms: ${lastFailure}`,
	);
}

async function cleanupClients(clients: ClientState[]) {
	for (const state of clients) {
		state.expectedDisconnect = true;
		state.storeSub?.unsubscribe();
		state.presenceSubChanges?.();
		state.presenceSubShared?.();
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
			const id = await state.client.store.create(context.table, data);
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
				await state.client.store.set(["items", docId], {
					name: `updated-item-${context.processIndex * 100 + idx}`,
					priority: Math.floor(deterministicUnit(seed + 1) * 10) + 1,
					active: deterministicUnit(seed + 2) > 0.5,
					tags:
						deterministicUnit(seed + 3) > 0.5
							? ["urgent", "updated"]
							: ["updated"],
				});
			} else {
				await state.client.store.set(["events", docId], {
					title: `updated-event-${context.processIndex * 100 + idx}`,
					score: Math.floor(deterministicUnit(seed + 4) * 100),
					ratings: deterministicUnit(seed + 5) > 0.5 ? [1, 5] : [2, 3],
				});
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
			state.client.presence.set({
				name: `client-${state.globalId}`,
				status: "active",
				cursor: { x: state.globalId, y: tick },
			});
		}
		if (tick < 2) await delay(25);
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
			state.client.presence.setShared({
				slide: context.roomIndex * 100 + tick,
				playing: tick % 2 === 1,
			});
		}
		if (tick < 2) await delay(25);
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
	};

	const metrics: ProcessMetrics = {
		processIndex,
		connectMs: 0,
		storeSubMs: 0,
		presenceSubMs: 0,
		storeCreateMs: 0,
		storeUpdateMs: 0,
		presenceUserMs: 0,
		presenceSharedMs: 0,
		storeConvergeMs: 0,
		presenceConvergeMs: 0,
		filterACount: 0,
		filterBCount: 0,
		userPresenceCount: 0,
		userCallbacks: [],
		sharedCallbacks: [],
	};

	const createdDocIds: string[] = [];

	try {
		// Phase 1: Connect and subscribe
		const startConnect = performance.now();
		await prepareClients(context, port, jwtSecret);
		metrics.connectMs = performance.now() - startConnect;
		await barrier("ready");

		// Phase 2: First 100 clients create 1 document each
		const startCreate = performance.now();
		await executeStoreCreates(context, createdDocIds);
		metrics.storeCreateMs = performance.now() - startCreate;
		await barrier("store-create");

		// Phase 3: Second 100 clients update 1 document each
		const startUpdate = performance.now();
		await executeStoreUpdates(context, createdDocIds);
		metrics.storeUpdateMs = performance.now() - startUpdate;
		await barrier("store-update");

		// Phase 4: Third 100 clients write 3 user presence updates
		const startPresenceUser = performance.now();
		await executePresenceUserWrites(context);
		metrics.presenceUserMs = performance.now() - startPresenceUser;
		await barrier("presence-user");

		// Phase 5: Fourth 100 clients write 3 shared presence updates
		const startPresenceShared = performance.now();
		await executePresenceSharedWrites(context);
		metrics.presenceSharedMs = performance.now() - startPresenceShared;
		await barrier("presence-shared");

		// Phase 6: Convergence check with stride 5
		const sampled = getSampleClients(context.clients);
		const [storeConvergeMs, presenceConvergeMs] = await Promise.all([
			waitForStoreConvergence(context, sampled),
			waitForPresenceConvergence(context, sampled),
		]);
		metrics.storeConvergeMs = storeConvergeMs;
		metrics.presenceConvergeMs = presenceConvergeMs;

		const sampleA = sampled.find((c) => c.filterSet === "A");
		const sampleB = sampled.find((c) => c.filterSet === "B");
		metrics.filterACount = sampleA?.storeRecords.size ?? 0;
		metrics.filterBCount = sampleB?.storeRecords.size ?? 0;
		metrics.userPresenceCount =
			sampled[0]?.client.presence.getAll({ includeSelf: true }).length ?? 0;

		await barrier("converge");

		metrics.userCallbacks = context.clients.map((s) => s.userCallbacks);
		metrics.sharedCallbacks = context.clients.map((s) => s.sharedCallbacks);
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

	const workerCommand = [
		process.execPath,
		import.meta.path,
		"--worker",
		String(port),
		String(processIndex),
		jwtSecret,
	];

	const worker = Bun.spawn(workerCommand, {
		stdio: ["ignore", "ignore", "inherit"],
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

function reportMetrics(results: ProcessMetrics[], elapsedMs: number) {
	const max = (key: keyof ProcessMetrics) =>
		Math.round(Math.max(...results.map((r) => r[key] as number)));
	console.log(
		`Combo stress passed: ${TOTAL_CLIENTS} clients across 4 processes (${ROOM_COUNT} rooms, 2 tables) in ${Math.round(elapsedMs)}ms; ` +
			`phase max ms connect=${max("connectMs")}, ` +
			`store-create=${max("storeCreateMs")}, store-update=${max("storeUpdateMs")}, ` +
			`presence-user=${max("presenceUserMs")}, presence-shared=${max("presenceSharedMs")}, ` +
			`store-converge=${max("storeConvergeMs")}, presence-converge=${max("presenceConvergeMs")}`,
	);
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
