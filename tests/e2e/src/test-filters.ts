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
	fired: boolean;
	debugId: number;
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
	const configs: Array<Omit<ItemRecord, "id">> = [
		{ name: "item-0", priority: 1, active: false, tags: ["urgent"] },
		{ name: "item-1", priority: 2, active: false, tags: [] },
		{ name: "item-2", priority: 3, active: true, tags: [] },
		{ name: "item-3", priority: 4, active: true, tags: [] },
		{ name: "item-4", priority: 5, active: true, tags: [] },
		{ name: "item-5", priority: 6, active: true, tags: [] },
		{ name: "item-6", priority: 7, active: false, tags: [] },
		{ name: "item-7", priority: 8, active: true, tags: ["urgent"] },
		{ name: "item-8", priority: 9, active: true, tags: [] },
		{ name: "item-9", priority: 10, active: true, tags: [] },
	];
	return configs[index];
}

function createEventData(index: number): Omit<EventRecord, "id"> {
	const configs: Array<Omit<EventRecord, "id">> = [
		{ title: "event-0", score: 10, ratings: [2, 3] },
		{ title: "event-1", score: 15, ratings: [2, 4] },
		{ title: "event-2", score: 30, ratings: [3, 4] },
		{ title: "event-3", score: 10, ratings: [1, 2] },
		{ title: "event-4", score: 50, ratings: [4, 5] },
		{ title: "event-5", score: 60, ratings: [3, 5] },
		{ title: "event-6", score: 70, ratings: [2, 3] },
		{ title: "event-7", score: 15, ratings: [1, 3] },
		{ title: "event-8", score: 80, ratings: [2, 4] },
		{ title: "event-9", score: 90, ratings: [5, 6] },
	];
	return configs[index];
}

function subscribeClient(state: ClientState) {
	const itemsFilter = state.filterSet === "A" ? ITEMS_FILTER_A : ITEMS_FILTER_B;
	const eventsFilter =
		state.filterSet === "A" ? EVENTS_FILTER_A : EVENTS_FILTER_B;

	state.itemsSub = state.client.store.subscribe(
		"items",
		itemsFilter,
		(items: JsonValue[]) => {
			state.fired = true;
			state.itemsRecords.clear();
			for (const item of items as unknown as ItemRecord[]) {
				state.itemsRecords.set(item.id, item);
			}
		},
	);

	state.eventsSub = state.client.store.subscribe(
		"events",
		eventsFilter,
		(events: JsonValue[]) => {
			state.fired = true;
			state.eventsRecords.clear();
			for (const event of events as unknown as EventRecord[]) {
				state.eventsRecords.set(event.id, event);
			}
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

function statesMatch(a: ClientState, b: ClientState): boolean {
	if (a.itemsRecords.size !== b.itemsRecords.size) return false;
	if (a.eventsRecords.size !== b.eventsRecords.size) return false;
	for (const id of a.itemsRecords.keys()) {
		if (!b.itemsRecords.has(id)) return false;
	}
	for (const id of a.eventsRecords.keys()) {
		if (!b.eventsRecords.has(id)) return false;
	}
	return true;
}

function verifyStateMatch(
	first: ClientState,
	client: ClientState,
	errors: string[],
) {
	if (statesMatch(first, client)) return;

	const firstIds = clientIdSet(first);
	const otherIds = clientIdSet(client);

	const missing = firstIds.itemIds.filter((id) => !client.itemsRecords.has(id));
	const extra = otherIds.itemIds.filter((id) => !first.itemsRecords.has(id));
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

	const missingEvents = firstIds.eventIds.filter(
		(id) => !client.eventsRecords.has(id),
	);
	const extraEvents = otherIds.eventIds.filter(
		(id) => !first.eventsRecords.has(id),
	);
	if (missingEvents.length > 0) {
		errors.push(
			`Client ${client.debugId} missing events vs client ${first.debugId}: ${missingEvents.join(",")}`,
		);
	}
	if (extraEvents.length > 0) {
		errors.push(
			`Client ${client.debugId} extra events vs client ${first.debugId}: ${extraEvents.join(",")}`,
		);
	}
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

async function waitForAllFiredAndConverged(
	clients: ClientState[],
	timeoutMs = 15000,
): Promise<void> {
	const deadline = Date.now() + timeoutMs;

	while (true) {
		if (clients.every((c) => c.fired)) {
			break;
		}
		if (Date.now() > deadline) {
			const notFired = clients.filter((c) => !c.fired).map((c) => c.debugId);
			throw new Error(
				`Timeout: ${notFired.length} clients never fired: ${notFired.join(",")}`,
			);
		}
		await new Promise((resolve) => setTimeout(resolve, 100));
	}

	while (true) {
		const errors = [
			...verifySelfConsistentStates(clients, "A"),
			...verifySelfConsistentStates(clients, "B"),
		];
		if (errors.length === 0) {
			return;
		}
		if (Date.now() > deadline) {
			throw new Error(
				`Timeout: not converged — ${errors.slice(0, 6).join("; ")}`,
			);
		}
		await new Promise((resolve) => setTimeout(resolve, 100));
	}
}

function closeAllClients(clients: ClientState[]) {
	for (const state of clients) {
		state.itemsSub?.unsubscribe();
		state.eventsSub?.unsubscribe();
		state.client.close();
	}
}

async function createClients(
	totalClients: number,
	readWriteCount: number,
	port: number,
): Promise<ClientState[]> {
	const clients: ClientState[] = [];
	const step = Math.floor(totalClients / readWriteCount);
	for (let i = 0; i < totalClients; i++) {
		const client = new ZyncBaseClient({
			url: `ws://127.0.0.1:${port}`,
			debug: false,
		});
		await client.connect();
		clients.push({
			client,
			filterSet: i < totalClients / 2 ? "A" : "B",
			itemsSub: null,
			eventsSub: null,
			itemsRecords: new Map(),
			eventsRecords: new Map(),
			isReadWrite: i % step === 0,
			fired: false,
			debugId: i, // Add debugId property
		});
	}
	return clients;
}

async function createInitialData(
	readWriteClients: ClientState[],
	count: number,
): Promise<{ createdItemIds: string[]; createdEventIds: string[] }> {
	const createdItemIds: string[] = [];
	const createdEventIds: string[] = [];
	const createPromises: Promise<void>[] = [];

	for (let i = 0; i < count; i++) {
		const rwClient = readWriteClients[i].client;
		createPromises.push(
			rwClient.store
				.create("items", createItemData(i))
				.then((id) => createdItemIds.push(id)),
		);
		createPromises.push(
			rwClient.store
				.create("events", createEventData(i))
				.then((id) => createdEventIds.push(id)),
		);
	}

	await Promise.all(createPromises);
	return { createdItemIds, createdEventIds };
}

async function updateRandomRecords(
	readWriteClients: ClientState[],
	createdItemIds: string[],
	createdEventIds: string[],
	count: number,
): Promise<void> {
	const updatePromises: Promise<void>[] = [];

	for (let i = 0; i < count; i++) {
		const rwClient = readWriteClients[i].client;

		const randomItemId =
			createdItemIds[Math.floor(Math.random() * createdItemIds.length)];
		updatePromises.push(
			rwClient.store.set(["items", randomItemId], {
				priority: Math.floor(Math.random() * 10) + 1,
				active: Math.random() > 0.5,
				tags: Math.random() > 0.5 ? ["urgent", "updated"] : ["updated"],
			}),
		);

		const randomEventId =
			createdEventIds[Math.floor(Math.random() * createdEventIds.length)];
		updatePromises.push(
			rwClient.store.set(["events", randomEventId], {
				score: Math.random() * 100,
				ratings: Math.random() > 0.5 ? [1, 5] : [2, 3],
			}),
		);
	}

	await Promise.all(updatePromises);
}

export async function run(port: number = 3000) {
	const TOTAL_CLIENTS = 100;
	const READ_WRITE_COUNT = 10;

	console.log(`Creating ${TOTAL_CLIENTS} clients...`);
	const clients = await createClients(TOTAL_CLIENTS, READ_WRITE_COUNT, port);
	console.log("All clients connected.");

	const readWriteClients = clients.filter((c) => c.isReadWrite);

	for (const state of clients) {
		subscribeClient(state);
	}

	console.log("Creating initial data...");
	const { createdItemIds, createdEventIds } = await createInitialData(
		readWriteClients,
		READ_WRITE_COUNT,
	);
	console.log(
		`Created ${createdItemIds.length} items and ${createdEventIds.length} events.`,
	);

	console.log("Read-write clients updating random records...");
	await updateRandomRecords(
		readWriteClients,
		createdItemIds,
		createdEventIds,
		READ_WRITE_COUNT,
	);
	console.log("All updates complete.");

	console.log("Waiting for all clients to converge...");
	await waitForAllFiredAndConverged(clients);
	console.log("All clients converged — filter state is consistent.");

	closeAllClients(clients);
	console.log(`E2E Filters test passed — ${TOTAL_CLIENTS} clients.`);
}
