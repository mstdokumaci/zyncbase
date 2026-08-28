import type {
	JsonValue,
	QueryOptions,
	SubscriptionHandle,
} from "@zyncbase/client";
import { ZyncBaseClient } from "./client";

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
	itemsSub: SubscriptionHandle | null;
	eventsSub: SubscriptionHandle | null;
	itemsRecords: Map<string, ItemRecord>;
	eventsRecords: Map<string, EventRecord>;
	isReadWrite: boolean;
	itemsFired: boolean;
	eventsFired: boolean;
	debugId: number;
	subscribeStartedAt: number;
	firstFiredAt: number;
}

// generation gate + field compare avoid JSON.stringify per record
let globalGeneration = 0;

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

function subscribeClient(state: ClientState) {
	const itemsFilter = state.filterSet === "A" ? ITEMS_FILTER_A : ITEMS_FILTER_B;
	const eventsFilter =
		state.filterSet === "A" ? EVENTS_FILTER_A : EVENTS_FILTER_B;

	state.subscribeStartedAt = Date.now();

	state.itemsSub = state.client.store.subscribe(
		"items",
		itemsFilter,
		(items: JsonValue[]) => {
			if (state.firstFiredAt === 0) state.firstFiredAt = Date.now();
			state.itemsFired = true;
			state.itemsRecords.clear();
			for (const item of items as unknown as ItemRecord[]) {
				state.itemsRecords.set(item.id, item);
			}
			globalGeneration++;
		},
	);

	state.eventsSub = state.client.store.subscribe(
		"events",
		eventsFilter,
		(events: JsonValue[]) => {
			if (state.firstFiredAt === 0) state.firstFiredAt = Date.now();
			state.eventsFired = true;
			state.eventsRecords.clear();
			for (const event of events as unknown as EventRecord[]) {
				state.eventsRecords.set(event.id, event);
			}
			globalGeneration++;
		},
	);
}

function clientIdSet(state: ClientState): {
	itemIds: string[];
	eventIds: string[];
} {
	return {
		itemIds: [...state.itemsRecords.keys()].sort(),
		eventIds: [...state.eventsRecords.keys()].sort(),
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
	if (a.itemsRecords.size !== b.itemsRecords.size) return false;
	if (a.eventsRecords.size !== b.eventsRecords.size) return false;
	for (const [id, item] of a.itemsRecords) {
		const other = b.itemsRecords.get(id);
		if (!other || !itemsEqual(item, other)) return false;
	}
	for (const [id, event] of a.eventsRecords) {
		const other = b.eventsRecords.get(id);
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
	const missing = firstItemIds.filter((id) => !client.itemsRecords.has(id));
	const extra = [...client.itemsRecords.keys()].filter(
		(id) => !first.itemsRecords.has(id),
	);

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
		const itemA = first.itemsRecords.get(id);
		const itemB = client.itemsRecords.get(id);
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
	const missing = firstEventIds.filter((id) => !client.eventsRecords.has(id));
	const extra = [...client.eventsRecords.keys()].filter(
		(id) => !first.eventsRecords.has(id),
	);

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
		const eventA = first.eventsRecords.get(id);
		const eventB = client.eventsRecords.get(id);
		if (eventA && eventB && !eventsEqual(eventA, eventB)) {
			errors.push(
				`Client ${client.debugId} event ${id} value mismatch vs client ${first.debugId}`,
			);
		}
	}
}

function verifyStateMatch(
	first: ClientState,
	client: ClientState,
	errors: string[],
) {
	if (statesMatch(first, client)) return;

	const firstIds = clientIdSet(first);
	verifyItemMatch(first, client, firstIds.itemIds, errors);
	verifyEventMatch(first, client, firstIds.eventIds, errors);
}

function verifyRecordsMatchFilter(
	client: ClientState,
	filterLabel: "A" | "B",
	matchesItem: (item: ItemRecord) => boolean,
	matchesEvent: (event: EventRecord) => boolean,
	errors: string[],
) {
	for (const [id, item] of client.itemsRecords) {
		if (!matchesItem(item)) {
			errors.push(
				`Client ${client.debugId}: item ${id} does not match filter ${filterLabel}: priority=${item.priority} active=${item.active}`,
			);
		}
	}
	for (const [id, event] of client.eventsRecords) {
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
): string[] {
	const errors: string[] = [];
	const filterClients = clients.filter((c) => c.filterSet === filterLabel);

	if (filterClients.length === 0) return [];
	const first = filterClients[0];
	for (let i = 1; i < filterClients.length; i++) {
		verifyStateMatch(first, filterClients[i], errors);
	}

	const matchesItem =
		filterLabel === "A" ? matchesItemFilterA : matchesItemFilterB;
	const matchesEvent =
		filterLabel === "A" ? matchesEventFilterA : matchesEventFilterB;
	for (const c of filterClients) {
		verifyRecordsMatchFilter(c, filterLabel, matchesItem, matchesEvent, errors);
	}

	return errors;
}

function convergenceErrors(clients: ClientState[]): string[] {
	return [
		...verifySelfConsistentStates(clients, "A"),
		...verifySelfConsistentStates(clients, "B"),
	];
}

async function waitForFired(
	clients: ClientState[],
	deadline: number,
): Promise<number> {
	let polls = 0;
	while (!clients.every((c) => c.itemsFired && c.eventsFired)) {
		if (Date.now() > deadline) {
			const notFired = clients
				.filter((c) => !c.itemsFired || !c.eventsFired)
				.map((c) => c.debugId);
			throw new Error(
				`Timeout: ${notFired.length} clients never fired: ${notFired.join(",")}`,
			);
		}
		await new Promise((resolve) => setTimeout(resolve, 25));
		polls++;
	}
	return polls;
}

async function waitForAllFiredAndConverged(
	clients: ClientState[],
	timeoutMs = 15000,
): Promise<void> {
	const deadline = Date.now() + timeoutMs;
	const polls = await waitForFired(clients, deadline);

	let verifyPasses = 0;
	// skip heavy verify when no deltas arrived since last check
	let lastGen = -1;
	while (true) {
		if (globalGeneration === lastGen) {
			if (Date.now() > deadline)
				throw new Error(
					`Timeout: not converged — ${convergenceErrors(clients).slice(0, 6).join("; ")}`,
				);
			await new Promise((resolve) => setTimeout(resolve, 50));
			continue;
		}
		const gen = globalGeneration;
		await new Promise((resolve) => setTimeout(resolve, 50));
		if (globalGeneration !== gen) continue;
		lastGen = gen;
		const errors = convergenceErrors(clients);
		verifyPasses++;
		if (errors.length === 0) {
			console.log(
				`[converge] fired after ${polls} polls, verified on pass ${verifyPasses} (gen=${globalGeneration})`,
			);
			return;
		}
		if (Date.now() > deadline)
			throw new Error(
				`Timeout: not converged — ${errors.slice(0, 6).join("; ")}`,
			);
		await new Promise((resolve) => setTimeout(resolve, 100));
	}
}

function closeAllClients(clients: ClientState[]) {
	const t0 = Date.now();
	let unsubMs = 0;
	let closeMs = 0;
	for (const state of clients) {
		const u0 = Date.now();
		state.itemsSub?.unsubscribe();
		state.eventsSub?.unsubscribe();
		unsubMs += Date.now() - u0;
		const c0 = Date.now();
		state.client.close();
		closeMs += Date.now() - c0;
	}
	// unsubscribe/close are fire-and-forget; the timings below are local
	// synchronous call times, not remote completion.
	console.log(
		`[close] ${clients.length} clients: total=${Date.now() - t0}ms ` +
			`unsubscribe(sync)=${unsubMs}ms (avg ${(unsubMs / clients.length).toFixed(1)}) ` +
			`close(sync)=${closeMs}ms (avg ${(closeMs / clients.length).toFixed(1)})`,
	);
}

async function createClients(
	totalClients: number,
	readWriteCount: number,
	port: number,
): Promise<ClientState[]> {
	const clients: ClientState[] = [];
	const step = Math.floor(totalClients / readWriteCount);
	const BATCH_SIZE = 50;

	for (
		let batchStart = 0;
		batchStart < totalClients;
		batchStart += BATCH_SIZE
	) {
		const batchEnd = Math.min(batchStart + BATCH_SIZE, totalClients);
		const batch = await Promise.all(
			Array.from({ length: batchEnd - batchStart }, async (_, offset) => {
				const i = batchStart + offset;
				const client = new ZyncBaseClient({
					url: `ws://127.0.0.1:${port}`,
					debug: false,
				});
				await client.connect();
				return {
					client,
					filterSet: i < totalClients / 2 ? ("A" as const) : ("B" as const),
					itemsSub: null,
					eventsSub: null,
					itemsRecords: new Map(),
					eventsRecords: new Map(),
					isReadWrite: i % step === 0,
					itemsFired: false,
					eventsFired: false,
					debugId: i,
					subscribeStartedAt: 0,
					firstFiredAt: 0,
				} satisfies ClientState;
			}),
		);
		clients.push(...batch);
	}
	return clients;
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
		for (let j = 0; j < 4; j++) {
			const index = i * 4 + j;
			const t = Date.now();
			createPromises.push(
				rwClient.store.create("items", createItemData(index)).then((id) => {
					rtts.push(Date.now() - t);
					createdItemIds.push(id);
				}),
			);
			const te = Date.now();
			createPromises.push(
				rwClient.store.create("events", createEventData(index)).then((id) => {
					rtts.push(Date.now() - te);
					createdEventIds.push(id);
				}),
			);
		}
	}

	await Promise.all(createPromises);
	return { createdItemIds, createdEventIds, rtts };
}

async function updateWriterRecords(
	client: ZyncBaseClient,
	createdItemIds: string[],
	createdEventIds: string[],
	rtts: number[],
): Promise<void> {
	if (createdItemIds.length === 0 || createdEventIds.length === 0) {
		throw new Error(
			"Cannot update records: createdItemIds or createdEventIds is empty",
		);
	}
	const promises: Promise<void>[] = [];
	for (let j = 0; j < 4; j++) {
		const randomItemId =
			createdItemIds[Math.floor(Math.random() * createdItemIds.length)];
		const t = Date.now();
		promises.push(
			client.store
				.set(["items", randomItemId], {
					name: "updated-item",
					priority: Math.floor(Math.random() * 10) + 1,
					active: Math.random() > 0.5,
					tags: Math.random() > 0.5 ? ["urgent", "updated"] : ["updated"],
				})
				.then(() => {
					rtts.push(Date.now() - t);
				}),
		);

		const randomEventId =
			createdEventIds[Math.floor(Math.random() * createdEventIds.length)];
		const te = Date.now();
		promises.push(
			client.store
				.set(["events", randomEventId], {
					title: "updated-event",
					score: Math.random() * 100,
					ratings: Math.random() > 0.5 ? [1, 5] : [2, 3],
				})
				.then(() => {
					rtts.push(Date.now() - te);
				}),
		);
	}
	await Promise.all(promises);
}

async function updateRandomRecords(
	readWriteClients: ClientState[],
	createdItemIds: string[],
	createdEventIds: string[],
): Promise<number[]> {
	const updatePromises: Promise<void>[] = [];
	const rtts: number[] = [];

	for (let i = 0; i < readWriteClients.length; i++) {
		const rwClient = readWriteClients[i].client;
		updatePromises.push(
			updateWriterRecords(rwClient, createdItemIds, createdEventIds, rtts),
		);
	}

	await Promise.all(updatePromises);
	return rtts;
}

export async function run(port: number = 3000) {
	const TOTAL_CLIENTS = 1000;
	const READ_WRITE_COUNT = 100;
	const t0 = Date.now();
	const phase = (label: string) =>
		console.log(`[t+${Date.now() - t0}ms] ${label}`);

	globalGeneration = 0;
	console.log(`Creating ${TOTAL_CLIENTS} clients...`);
	const clients = await createClients(TOTAL_CLIENTS, READ_WRITE_COUNT, port);
	phase("All clients connected.");

	const readWriteClients = clients.filter((c) => c.isReadWrite);

	const subT0 = Date.now();
	for (const state of clients) {
		subscribeClient(state);
	}
	const subMs = Date.now() - subT0;
	phase(`Subscribed ${clients.length} clients (${subMs}ms).`);

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
	await updateRandomRecords(
		readWriteClients,
		createdItemIds,
		createdEventIds,
	).then((rtts) => {
		reportRtts("update", rtts);
	});
	phase("All updates complete.");

	console.log("Waiting for all clients to converge...");
	await waitForAllFiredAndConverged(clients);
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
		sampleA.itemsRecords.size === 0 &&
		sampleA.eventsRecords.size === 0
	) {
		throw new Error("Filter A converged on empty state — no records received");
	}
	if (
		sampleB &&
		sampleB.itemsRecords.size === 0 &&
		sampleB.eventsRecords.size === 0
	) {
		throw new Error("Filter B converged on empty state — no records received");
	}
	console.log("Final filter assertions passed.");

	closeAllClients(clients);
	console.log(`E2E Filters test passed — ${TOTAL_CLIENTS} clients.`);
}
