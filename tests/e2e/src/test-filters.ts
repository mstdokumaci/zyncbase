import type { JsonValue, QueryOptions } from "@zyncbase/client";
import { ZyncBaseClient } from "./client";

function envInt(name: string, fallback: number, min = 0): number {
	const raw = process.env[name];
	if (raw === undefined || raw === "") return fallback;
	const value = Number(raw);
	if (!Number.isInteger(value) || value < min) {
		throw new Error(`${name} must be an integer >= ${min}, got ${raw}`);
	}
	return value;
}

interface ItemRecord {
	id: string;
	name: string;
	priority: number;
	active: boolean;
	tags: string[];
}

interface EventRecord {
	id: string;
	title: string;
	score: number;
	ratings: number[];
}

interface ClientState {
	client: ZyncBaseClient;
	filterSet: "A" | "B";
	itemsSnapshot: ItemRecord[];
	eventsSnapshot: EventRecord[];
	itemsRecords: Map<string, ItemRecord>;
	eventsRecords: Map<string, EventRecord>;
	itemsRevision: number;
	eventsRevision: number;
	itemsMapRevision: number;
	eventsMapRevision: number;
	isReadWrite: boolean;
	itemsFired: boolean;
	eventsFired: boolean;
	ready: boolean;
	debugId: number;
	subscribeStartedAt: number;
	firstFiredAt: number;
	scannedItemsRevision: number;
	scannedEventsRevision: number;
	scannedBaselineItemsRevision: number;
	scannedBaselineEventsRevision: number;
	cachedConvergenceFailure: string | null;
}

// generation gate + field compare avoid JSON.stringify per record
let globalGeneration = 0;

const CLIENTS_PER_PROCESS = envInt(
	"ZYNCBASE_FILTER_CLIENTS_PER_PROCESS",
	500,
	2,
);
const READ_WRITE_CLIENTS_PER_PROCESS = envInt(
	"ZYNCBASE_FILTER_READ_WRITE_CLIENTS_PER_PROCESS",
	100,
	1,
);
const CONNECT_CONCURRENCY = envInt(
	"ZYNCBASE_FILTER_CONNECT_CONCURRENCY",
	100,
	1,
);
const SECOND_PROCESS_SEED_OFFSET = 1_000_000;

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
	return (
		a.name === b.name &&
		a.priority === b.priority &&
		a.active === b.active &&
		tagsEqual(a.tags, b.tags)
	);
}

function eventsEqual(a: EventRecord, b: EventRecord): boolean {
	return (
		a.title === b.title &&
		a.score === b.score &&
		ratingsEqual(a.ratings, b.ratings)
	);
}

function matchesItemFilterA(item: ItemRecord): boolean {
	return item.priority >= 5 && item.active === true;
}

function matchesItemFilterB(item: ItemRecord): boolean {
	return item.priority < 3 || item.tags.includes("urgent");
}

function matchesEventFilterA(event: EventRecord): boolean {
	return event.score >= 50 && event.ratings.includes(5);
}

function matchesEventFilterB(event: EventRecord): boolean {
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

function createItemData(index: number): Omit<ItemRecord, "id"> {
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

function createEventData(index: number): Omit<EventRecord, "id"> {
	return {
		title: `event-${index}`,
		score: SCORES[index % 10],
		ratings: [...RATINGS_LIST[index % 10]],
	};
}

const RECORDS_PER_WRITER = 4;
const ITEM_TARGET_SEED_XOR = 0x9e3779b9;
const EVENT_TARGET_SEED_XOR = 0x85ebca6b;
const PROCESS_SEED_OFFSETS = [0, SECOND_PROCESS_SEED_OFFSET] as const;

function updatedItemData(seed: number): Omit<ItemRecord, "id"> {
	return {
		name: "updated-item",
		priority: Math.floor(deterministicUnit(seed + 1) * 10) + 1,
		active: deterministicUnit(seed + 2) > 0.5,
		tags:
			deterministicUnit(seed + 3) > 0.5 ? ["urgent", "updated"] : ["updated"],
	};
}

function updatedEventData(seed: number): Omit<EventRecord, "id"> {
	return {
		title: "updated-event",
		score: deterministicUnit(seed + 5) * 100,
		ratings: deterministicUnit(seed + 6) > 0.5 ? [1, 5] : [2, 3],
	};
}

function buildUpdateTargets(count: number, seed: number): number[] {
	const order = Array.from({ length: count }, (_, index) => index);
	for (let i = count - 1; i > 0; i--) {
		const j = Math.floor(deterministicUnit(seed + i) * (i + 1));
		[order[i], order[j]] = [order[j], order[i]];
	}
	return order;
}

function itemValueKey(item: ItemRecord): string {
	const tags = [...item.tags].sort().join("\u0001");
	return `${item.name}\u0000${item.priority}\u0000${item.active ? "1" : "0"}\u0000${tags}`;
}

function eventValueKey(event: EventRecord): string {
	const ratings = [...event.ratings].sort((a, b) => a - b).join("\u0001");
	return `${event.title}\u0000${event.score}\u0000${ratings}`;
}

function countValues<T>(
	records: Iterable<T>,
	keyOf: (record: T) => string,
): Map<string, number> {
	const counts = new Map<string, number>();
	for (const record of records) {
		const key = keyOf(record);
		counts.set(key, (counts.get(key) ?? 0) + 1);
	}
	return counts;
}

type ExpectedFilterRecords = {
	items: Map<string, number>;
	events: Map<string, number>;
	itemCount: number;
	eventCount: number;
};

type ExpectedRecords = Record<"A" | "B", ExpectedFilterRecords>;

function buildExpectedCounts(
	items: ItemRecord[],
	events: EventRecord[],
	matchesItem: (item: ItemRecord) => boolean,
	matchesEvent: (event: EventRecord) => boolean,
): ExpectedFilterRecords {
	const itemRecords = items.filter(matchesItem);
	const eventRecords = events.filter(matchesEvent);
	return {
		items: countValues(itemRecords, itemValueKey),
		events: countValues(eventRecords, eventValueKey),
		itemCount: itemRecords.length,
		eventCount: eventRecords.length,
	};
}

function buildExpectedRecords(readWriteCount: number): ExpectedRecords {
	const expectedItems: ItemRecord[] = [];
	const expectedEvents: EventRecord[] = [];

	for (const seedOffset of PROCESS_SEED_OFFSETS) {
		const items = Array.from(
			{ length: readWriteCount * RECORDS_PER_WRITER },
			(_, index) => ({ id: "", ...createItemData(index) }),
		);
		const events = Array.from(
			{ length: readWriteCount * RECORDS_PER_WRITER },
			(_, index) => ({ id: "", ...createEventData(index) }),
		);
		const itemTargets = buildUpdateTargets(
			items.length,
			seedOffset ^ ITEM_TARGET_SEED_XOR,
		);
		const eventTargets = buildUpdateTargets(
			events.length,
			seedOffset ^ EVENT_TARGET_SEED_XOR,
		);

		for (let writerIndex = 0; writerIndex < readWriteCount; writerIndex++) {
			for (let j = 0; j < RECORDS_PER_WRITER; j++) {
				const seed = seedOffset + writerIndex * 32 + j * 8;
				const itemIndex = itemTargets[writerIndex * RECORDS_PER_WRITER + j];
				const eventIndex = eventTargets[writerIndex * RECORDS_PER_WRITER + j];
				items[itemIndex] = { id: "", ...updatedItemData(seed) };
				events[eventIndex] = { id: "", ...updatedEventData(seed) };
			}
		}

		expectedItems.push(...items);
		expectedEvents.push(...events);
	}

	return {
		A: buildExpectedCounts(
			expectedItems,
			expectedEvents,
			matchesItemFilterA,
			matchesEventFilterA,
		),
		B: buildExpectedCounts(
			expectedItems,
			expectedEvents,
			matchesItemFilterB,
			matchesEventFilterB,
		),
	};
}

type ReadyTracker = {
	target: number;
	count: number;
	waiters: Array<{
		resolve: () => void;
		reject: (error: Error) => void;
	}>;
};

function markFiredReady(tracker: ReadyTracker, state: ClientState): void {
	if (state.ready || !state.itemsFired || !state.eventsFired) return;
	state.ready = true;
	tracker.count++;
	if (tracker.count >= tracker.target) {
		for (const waiter of tracker.waiters.splice(0)) waiter.resolve();
	}
}

async function subscribeClient(
	state: ClientState,
	readiness: ReadyTracker,
): Promise<void> {
	const itemsFilter = state.filterSet === "A" ? ITEMS_FILTER_A : ITEMS_FILTER_B;
	const eventsFilter =
		state.filterSet === "A" ? EVENTS_FILTER_A : EVENTS_FILTER_B;

	state.subscribeStartedAt = Date.now();

	const itemsSub = state.client.store.subscribe(
		"items",
		itemsFilter,
		(items: JsonValue[]) => {
			if (state.firstFiredAt === 0) state.firstFiredAt = Date.now();
			state.itemsSnapshot = items as unknown as ItemRecord[];
			state.itemsFired = true;
			state.itemsRevision++;
			globalGeneration++;
			markFiredReady(readiness, state);
		},
	);

	const eventsSub = state.client.store.subscribe(
		"events",
		eventsFilter,
		(events: JsonValue[]) => {
			if (state.firstFiredAt === 0) state.firstFiredAt = Date.now();
			state.eventsSnapshot = events as unknown as EventRecord[];
			state.eventsFired = true;
			state.eventsRevision++;
			globalGeneration++;
			markFiredReady(readiness, state);
		},
	);
	await Promise.all([itemsSub, eventsSub]);
}

function getItemsRecords(state: ClientState): Map<string, ItemRecord> {
	if (state.itemsMapRevision !== state.itemsRevision) {
		state.itemsRecords.clear();
		for (const item of state.itemsSnapshot) {
			state.itemsRecords.set(item.id, item);
		}
		state.itemsMapRevision = state.itemsRevision;
	}
	return state.itemsRecords;
}

function getEventsRecords(state: ClientState): Map<string, EventRecord> {
	if (state.eventsMapRevision !== state.eventsRevision) {
		state.eventsRecords.clear();
		for (const event of state.eventsSnapshot) {
			state.eventsRecords.set(event.id, event);
		}
		state.eventsMapRevision = state.eventsRevision;
	}
	return state.eventsRecords;
}

function clientIdSet(state: ClientState): {
	itemIds: string[];
	eventIds: string[];
} {
	return {
		itemIds: [...getItemsRecords(state).keys()].sort(),
		eventIds: [...getEventsRecords(state).keys()].sort(),
	};
}

function reportRtts(label: string, samples: number[]) {
	if (samples.length === 0) return;
	const sorted = [...samples].sort((a, b) => a - b);
	const p = (q: number) =>
		sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))];
	const total = samples.reduce((a, b) => a + b, 0);
	console.log(
		`[rtt] ${label}: n=${samples.length} total=${total.toFixed(0)}ms ` +
			`min=${sorted[0].toFixed(1)} p50=${p(0.5).toFixed(1)} p95=${p(0.95).toFixed(1)} max=${sorted[sorted.length - 1].toFixed(1)}ms`,
	);
}

function statesMatch(a: ClientState, b: ClientState): boolean {
	const aItems = getItemsRecords(a);
	const bItems = getItemsRecords(b);
	const aEvents = getEventsRecords(a);
	const bEvents = getEventsRecords(b);
	if (aItems.size !== bItems.size) return false;
	if (aEvents.size !== bEvents.size) return false;
	for (const [id, item] of aItems) {
		const other = bItems.get(id);
		if (!other || !itemsEqual(item, other)) return false;
	}
	for (const [id, event] of aEvents) {
		const other = bEvents.get(id);
		if (!other || !eventsEqual(event, other)) return false;
	}
	return true;
}

function verifyItemMatch(
	first: ClientState,
	client: ClientState,
	firstItemIds: string[],
	errors: string[],
) {
	const firstItems = getItemsRecords(first);
	const clientItems = getItemsRecords(client);
	const missing = firstItemIds.filter((id) => !clientItems.has(id));
	const extra = [...clientItems.keys()].filter((id) => !firstItems.has(id));

	if (missing.length > 0) {
		errors.push(
			`Client ${client.debugId} missing items vs client ${first.debugId}: ${missing.join(",")}`,
		);
	}
	if (extra.length > 0) {
		errors.push(
			`Client ${client.debugId} extra items vs client ${first.debugId}: ${extra.join(",")}`,
		);
	}

	for (const id of firstItemIds) {
		const itemA = firstItems.get(id);
		const itemB = clientItems.get(id);
		if (itemA && itemB && !itemsEqual(itemA, itemB)) {
			errors.push(
				`Client ${client.debugId} item ${id} value mismatch vs client ${first.debugId}`,
			);
		}
	}
}

function verifyEventMatch(
	first: ClientState,
	client: ClientState,
	firstEventIds: string[],
	errors: string[],
) {
	const firstEvents = getEventsRecords(first);
	const clientEvents = getEventsRecords(client);
	const missing = firstEventIds.filter((id) => !clientEvents.has(id));
	const extra = [...clientEvents.keys()].filter((id) => !firstEvents.has(id));

	if (missing.length > 0) {
		errors.push(
			`Client ${client.debugId} missing events vs client ${first.debugId}: ${missing.join(",")}`,
		);
	}
	if (extra.length > 0) {
		errors.push(
			`Client ${client.debugId} extra events vs client ${first.debugId}: ${extra.join(",")}`,
		);
	}

	for (const id of firstEventIds) {
		const eventA = firstEvents.get(id);
		const eventB = clientEvents.get(id);
		if (eventA && eventB && !eventsEqual(eventA, eventB)) {
			errors.push(
				`Client ${client.debugId} event ${id} value mismatch vs client ${first.debugId}`,
			);
		}
	}
}

function verifyExpectedRecords(
	client: ClientState,
	filterLabel: "A" | "B",
	expected: ExpectedFilterRecords,
	errors: string[],
) {
	const items = getItemsRecords(client);
	const events = getEventsRecords(client);
	if (
		items.size === expected.itemCount &&
		events.size === expected.eventCount &&
		recordsMatchExpected(items, expected.items, itemValueKey) &&
		recordsMatchExpected(events, expected.events, eventValueKey)
	) {
		return;
	}

	errors.push(
		`Client ${client.debugId}: filter ${filterLabel} does not match expected records ` +
			`(items ${items.size}/${expected.itemCount}, events ${events.size}/${expected.eventCount}); ` +
			`itemSample=${mismatchSample(items, expected.items, itemValueKey)}; ` +
			`eventSample=${mismatchSample(events, expected.events, eventValueKey)}`,
	);
}

function mismatchSample<T>(
	records: Map<string, T>,
	expected: Map<string, number>,
	keyOf: (record: T) => string,
): string {
	const actual = countValues(records.values(), keyOf);
	for (const [key, count] of actual) {
		if ((expected.get(key) ?? 0) !== count) {
			return `${key.replaceAll("\u0000", "|").replaceAll("\u0001", ",")}=${count} expected ${expected.get(key) ?? 0}`;
		}
	}
	for (const [key, count] of expected) {
		if ((actual.get(key) ?? 0) !== count) {
			return `missing ${key.replaceAll("\u0000", "|").replaceAll("\u0001", ",")} expected ${count}`;
		}
	}
	return "none";
}

function recordsMatchExpected<T>(
	records: Map<string, T>,
	expected: Map<string, number>,
	keyOf: (record: T) => string,
): boolean {
	const actual = new Map<string, number>();
	for (const record of records.values()) {
		const key = keyOf(record);
		const count = (actual.get(key) ?? 0) + 1;
		if (count > (expected.get(key) ?? 0)) return false;
		actual.set(key, count);
	}
	if (actual.size !== expected.size) return false;
	for (const [key, count] of actual) {
		if (count !== expected.get(key)) return false;
	}
	return true;
}

function verifyExpectedCounts(
	client: ClientState,
	filterLabel: "A" | "B",
	expected: ExpectedFilterRecords,
	errors: string[],
) {
	const items = getItemsRecords(client);
	const events = getEventsRecords(client);
	if (
		items.size !== expected.itemCount ||
		events.size !== expected.eventCount
	) {
		errors.push(
			`Client ${client.debugId}: filter ${filterLabel} has ${items.size} items and ${events.size} events, ` +
				`expected ${expected.itemCount} and ${expected.eventCount}`,
		);
	}
}

function verifyStateMatch(
	first: ClientState,
	client: ClientState,
	errors: string[],
) {
	if (
		client.scannedItemsRevision === client.itemsRevision &&
		client.scannedEventsRevision === client.eventsRevision &&
		client.scannedBaselineItemsRevision === first.itemsRevision &&
		client.scannedBaselineEventsRevision === first.eventsRevision &&
		client.cachedConvergenceFailure === null
	) {
		return;
	}

	const errorStart = errors.length;
	if (!statesMatch(first, client)) {
		const firstIds = clientIdSet(first);
		verifyItemMatch(first, client, firstIds.itemIds, errors);
		verifyEventMatch(first, client, firstIds.eventIds, errors);
	}

	client.scannedItemsRevision = client.itemsRevision;
	client.scannedEventsRevision = client.eventsRevision;
	client.scannedBaselineItemsRevision = first.itemsRevision;
	client.scannedBaselineEventsRevision = first.eventsRevision;
	client.cachedConvergenceFailure =
		errors.length > errorStart ? errors.slice(errorStart).join(" | ") : null;
}

function verifyRecordsMatchFilter(
	client: ClientState,
	filterLabel: "A" | "B",
	matchesItem: (item: ItemRecord) => boolean,
	matchesEvent: (event: EventRecord) => boolean,
	errors: string[],
) {
	for (const [id, item] of getItemsRecords(client)) {
		if (!matchesItem(item)) {
			errors.push(
				`Client ${client.debugId}: item ${id} does not match filter ${filterLabel}: priority=${item.priority} active=${item.active}`,
			);
		}
	}
	for (const [id, event] of getEventsRecords(client)) {
		if (!matchesEvent(event)) {
			errors.push(
				`Client ${client.debugId}: event ${id} does not match filter ${filterLabel}: score=${event.score} ratings=[${event.ratings}]`,
			);
		}
	}
}

function verifySelfConsistentStates(
	clients: ClientState[],
	filterLabel: "A" | "B",
	expected: ExpectedFilterRecords,
): string[] {
	const errors: string[] = [];
	const filterClients = clients.filter((c) => c.filterSet === filterLabel);

	if (filterClients.length === 0) return [];
	const first = filterClients[0];
	verifyExpectedRecords(first, filterLabel, expected, errors);
	for (let i = 1; i < filterClients.length; i++) {
		verifyExpectedCounts(filterClients[i], filterLabel, expected, errors);
		verifyStateMatch(first, filterClients[i], errors);
	}

	const matchesItem =
		filterLabel === "A" ? matchesItemFilterA : matchesItemFilterB;
	const matchesEvent =
		filterLabel === "A" ? matchesEventFilterA : matchesEventFilterB;
	verifyRecordsMatchFilter(
		first,
		filterLabel,
		matchesItem,
		matchesEvent,
		errors,
	);

	return errors;
}

function convergenceErrors(
	clients: ClientState[],
	expected: ExpectedRecords,
): string[] {
	return [
		...verifySelfConsistentStates(clients, "A", expected.A),
		...verifySelfConsistentStates(clients, "B", expected.B),
	];
}

async function waitForFired(
	readiness: ReadyTracker,
	clients: ClientState[],
	deadline: number,
): Promise<number> {
	if (readiness.count >= readiness.target) return 0;
	await new Promise<void>((resolve, reject) => {
		const timer = setTimeout(
			() => {
				const notFired = clients
					.filter((c) => !c.itemsFired || !c.eventsFired)
					.map((c) => c.debugId);
				reject(
					new Error(
						`Timeout: ${notFired.length} clients never fired: ${notFired.join(",")}`,
					),
				);
			},
			Math.max(0, deadline - Date.now()),
		);
		readiness.waiters.push({
			resolve: () => {
				clearTimeout(timer);
				resolve();
			},
			reject: (error) => {
				clearTimeout(timer);
				reject(error);
			},
		});
	});
	return 0;
}

async function waitForAllFiredAndConverged(
	readiness: ReadyTracker,
	clients: ClientState[],
	expected: ExpectedRecords,
	timeoutMs = 15000,
): Promise<void> {
	const deadline = Date.now() + timeoutMs;
	const polls = await waitForFired(readiness, clients, deadline);

	let verifyPasses = 0;
	// skip heavy verify when no deltas arrived since last check
	let lastGen = -1;
	while (true) {
		if (Date.now() > deadline)
			throw new Error(
				`Timeout: not converged — ${convergenceErrors(clients, expected).slice(0, 6).join("; ")}`,
			);
		if (globalGeneration === lastGen) {
			await new Promise((resolve) => setTimeout(resolve, 50));
			continue;
		}
		const gen = globalGeneration;
		await new Promise((resolve) => setTimeout(resolve, 50));
		if (globalGeneration !== gen) continue;
		lastGen = gen;
		const errors = convergenceErrors(clients, expected);
		verifyPasses++;
		if (errors.length === 0) {
			console.log(
				`[converge] fired after ${polls} polls, verified on pass ${verifyPasses} (gen=${globalGeneration})`,
			);
			return;
		}
		await new Promise((resolve) =>
			setTimeout(resolve, Math.min(100, Math.max(0, deadline - Date.now()))),
		);
	}
}

function closeAllClients(clients: ClientState[]) {
	const t0 = Date.now();
	for (const state of clients) state.client.close();
	console.log(`[close] ${clients.length} clients: total=${Date.now() - t0}ms`);
}

async function runWithConcurrency<T>(
	count: number,
	limit: number,
	operation: (index: number) => Promise<T>,
): Promise<T[]> {
	const results = new Array<T>(count);
	let next = 0;
	let failure: Error | null = null;
	const worker = async (): Promise<void> => {
		while (failure === null) {
			const index = next++;
			if (index >= count) return;
			try {
				results[index] = await operation(index);
			} catch (error) {
				failure = error instanceof Error ? error : new Error(String(error));
			}
		}
	};
	await Promise.all(Array.from({ length: Math.min(limit, count) }, worker));
	if (failure) throw failure;
	return results;
}

async function createClients(
	totalClients: number,
	readWriteCount: number,
	port: number,
): Promise<ClientState[]> {
	const step = Math.max(1, Math.floor(totalClients / readWriteCount));
	return runWithConcurrency(
		totalClients,
		CONNECT_CONCURRENCY,
		async (i): Promise<ClientState> => {
			const client = new ZyncBaseClient({
				url: `ws://127.0.0.1:${port}`,
				debug: false,
			});
			await client.connect();
			return {
				client,
				filterSet: i < totalClients / 2 ? ("A" as const) : ("B" as const),
				itemsSnapshot: [],
				eventsSnapshot: [],
				itemsRecords: new Map(),
				eventsRecords: new Map(),
				itemsRevision: 0,
				eventsRevision: 0,
				itemsMapRevision: -1,
				eventsMapRevision: -1,
				isReadWrite: i % step === 0,
				itemsFired: false,
				eventsFired: false,
				ready: false,
				debugId: i,
				subscribeStartedAt: 0,
				firstFiredAt: 0,
				scannedItemsRevision: -1,
				scannedEventsRevision: -1,
				scannedBaselineItemsRevision: -1,
				scannedBaselineEventsRevision: -1,
				cachedConvergenceFailure: null,
			};
		},
	);
}

async function createInitialData(readWriteClients: ClientState[]): Promise<{
	createdItemIds: string[];
	createdEventIds: string[];
	rtts: number[];
}> {
	const createdItemIds: string[] = [];
	const createdEventIds: string[] = [];
	const createPromises: Promise<void>[] = [];
	const rtts: number[] = [];

	for (let i = 0; i < readWriteClients.length; i++) {
		const rwClient = readWriteClients[i].client;
		for (let j = 0; j < RECORDS_PER_WRITER; j++) {
			const index = i * RECORDS_PER_WRITER + j;
			const t = Date.now();
			createPromises.push(
				rwClient.store.create("items", createItemData(index)).then((id) => {
					rtts.push(Date.now() - t);
					createdItemIds[index] = id;
				}),
			);
			const te = Date.now();
			createPromises.push(
				rwClient.store.create("events", createEventData(index)).then((id) => {
					rtts.push(Date.now() - te);
					createdEventIds[index] = id;
				}),
			);
		}
	}

	await Promise.all(createPromises);
	return { createdItemIds, createdEventIds, rtts };
}

async function updateWriterRecords(
	client: ZyncBaseClient,
	writerIndex: number,
	createdItemIds: string[],
	createdEventIds: string[],
	itemTargets: number[],
	eventTargets: number[],
	rtts: number[],
	seedOffset: number,
): Promise<void> {
	if (createdItemIds.length === 0 || createdEventIds.length === 0) {
		throw new Error(
			"Cannot update records: createdItemIds or createdEventIds is empty",
		);
	}
	const promises: Promise<void>[] = [];
	for (let j = 0; j < RECORDS_PER_WRITER; j++) {
		const seed = seedOffset + writerIndex * 32 + j * 8;
		const itemId =
			createdItemIds[itemTargets[writerIndex * RECORDS_PER_WRITER + j]];
		const t = Date.now();
		promises.push(
			client.store.set(["items", itemId], updatedItemData(seed)).then(() => {
				rtts.push(Date.now() - t);
			}),
		);

		const eventId =
			createdEventIds[eventTargets[writerIndex * RECORDS_PER_WRITER + j]];
		const te = Date.now();
		promises.push(
			client.store.set(["events", eventId], updatedEventData(seed)).then(() => {
				rtts.push(Date.now() - te);
			}),
		);
	}
	await Promise.all(promises);
}

function deterministicUnit(seed: number): number {
	let value = Math.imul(seed ^ (seed >>> 16), 0x45d9f3b);
	value = Math.imul(value ^ (value >>> 16), 0x45d9f3b);
	return ((value ^ (value >>> 16)) >>> 0) / 2 ** 32;
}

async function updateRandomRecords(
	readWriteClients: ClientState[],
	createdItemIds: string[],
	createdEventIds: string[],
	itemTargets: number[],
	eventTargets: number[],
	seedOffset: number,
): Promise<number[]> {
	const updatePromises: Promise<void>[] = [];
	const rtts: number[] = [];

	for (let i = 0; i < readWriteClients.length; i++) {
		const rwClient = readWriteClients[i].client;
		updatePromises.push(
			updateWriterRecords(
				rwClient,
				i,
				createdItemIds,
				createdEventIds,
				itemTargets,
				eventTargets,
				rtts,
				seedOffset,
			),
		);
	}

	await Promise.all(updatePromises);
	return rtts;
}

async function runHalf(
	port: number,
	seedOffset: number,
	readyForWrites: () => Promise<void>,
) {
	const t0 = Date.now();
	const phase = (label: string) =>
		console.log(`[t+${Date.now() - t0}ms] ${label}`);

	globalGeneration = 0;
	console.log(`Creating ${CLIENTS_PER_PROCESS} clients...`);
	const clients = await createClients(
		CLIENTS_PER_PROCESS,
		READ_WRITE_CLIENTS_PER_PROCESS,
		port,
	);
	phase("All clients connected.");

	const readWriteClients = clients.filter((c) => c.isReadWrite);
	const readiness: ReadyTracker = {
		target: clients.length,
		count: 0,
		waiters: [],
	};

	const subT0 = Date.now();
	await Promise.all(clients.map((state) => subscribeClient(state, readiness)));
	const subMs = Date.now() - subT0;
	// subscribe() resolves at the server ack, so all registrations are live.
	phase(`Subscribed ${clients.length} clients (${subMs}ms).`);
	await readyForWrites();

	console.log("Creating initial data...");
	const {
		createdItemIds,
		createdEventIds,
		rtts: createRtts,
	} = await createInitialData(readWriteClients);
	phase(
		`Created ${createdItemIds.length} items and ${createdEventIds.length} events.`,
	);
	reportRtts("create", createRtts);

	console.log("Read-write clients updating random records...");
	const itemTargets = buildUpdateTargets(
		createdItemIds.length,
		seedOffset ^ ITEM_TARGET_SEED_XOR,
	);
	const eventTargets = buildUpdateTargets(
		createdEventIds.length,
		seedOffset ^ EVENT_TARGET_SEED_XOR,
	);
	await updateRandomRecords(
		readWriteClients,
		createdItemIds,
		createdEventIds,
		itemTargets,
		eventTargets,
		seedOffset,
	).then((rtts) => {
		reportRtts("update", rtts);
	});
	phase("All updates complete.");

	const expectedRecords = buildExpectedRecords(readWriteClients.length);
	console.log("Waiting for all clients to converge...");
	await waitForAllFiredAndConverged(readiness, clients, expectedRecords);
	phase("All clients converged — filter state is consistent.");
	reportRtts(
		"subscribe→first-delta",
		clients
			.map((c) => c.firstFiredAt - c.subscribeStartedAt)
			.filter((x) => x > 0),
	);
	const sampleA = clients.find((c) => c.filterSet === "A");
	const sampleB = clients.find((c) => c.filterSet === "B");
	if (
		sampleA &&
		getItemsRecords(sampleA).size === 0 &&
		getEventsRecords(sampleA).size === 0
	) {
		throw new Error("Filter A converged on empty state — no records received");
	}
	if (
		sampleB &&
		getItemsRecords(sampleB).size === 0 &&
		getEventsRecords(sampleB).size === 0
	) {
		throw new Error("Filter B converged on empty state — no records received");
	}
	console.log("Final filter assertions passed.");

	closeAllClients(clients);
	console.log(`E2E Filters test passed — ${CLIENTS_PER_PROCESS} clients.`);
}

export async function run(port: number = 3000) {
	const workerCommand = [process.execPath];
	const profileDir = process.env.ZYNCBASE_FILTER_PROFILE_DIR;
	if (profileDir) {
		workerCommand.push(
			"--cpu-prof",
			"--cpu-prof-md",
			"--cpu-prof-dir",
			profileDir,
			"--cpu-prof-name",
			"client-2.cpuprofile",
		);
	}
	workerCommand.push(import.meta.path, "--worker", String(port));

	const started = performance.now();
	const workerReady = Promise.withResolvers<void>();
	const worker = Bun.spawn(workerCommand, {
		stdio: ["ignore", profileDir ? "inherit" : "ignore", "inherit"],
		ipc(message) {
			if (message === "ready") workerReady.resolve();
		},
	});
	const workerFinished = worker.exited.then((exitCode) => {
		if (exitCode !== 0) {
			throw new Error(`Filter client process 2 failed (${exitCode})`);
		}
	});
	const [localResult, workerResult] = await Promise.allSettled([
		runHalf(port, 0, async () => {
			await Promise.race([workerReady.promise, workerFinished]);
			worker.send("start");
		}).catch((error) => {
			worker.kill();
			throw error;
		}),
		workerFinished,
	]);

	if (localResult.status === "rejected") throw localResult.reason;
	if (workerResult.status === "rejected") throw workerResult.reason;
	console.log(
		`Both filter client processes completed in ${Math.round(performance.now() - started)}ms.`,
	);
}

if (import.meta.main) {
	const [mode, portArg] = Bun.argv.slice(2);
	const port = Number(portArg);
	if (
		mode !== "--worker" ||
		!Number.isInteger(port) ||
		port < 1 ||
		port > 65_535
	) {
		throw new Error("usage: test-filters.ts --worker <port>");
	}
	if (!process.send) throw new Error("Filter worker requires an IPC channel");
	await runHalf(
		port,
		SECOND_PROCESS_SEED_OFFSET,
		() =>
			new Promise((resolve, reject) => {
				process.once("message", (message) => {
					if (message === "start") resolve();
					else
						reject(new Error(`Unexpected filter worker message: ${message}`));
				});
				process.send?.("ready");
			}),
	);
}
