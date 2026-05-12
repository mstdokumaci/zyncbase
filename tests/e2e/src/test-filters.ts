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
	where: {
		priority: { gte: 5 },
		active: true,
	},
};

const ITEMS_FILTER_B: QueryOptions = {
	where: {
		or: [{ priority: { lt: 3 } }, { tags: { contains: "urgent" } }],
	},
};

const EVENTS_FILTER_A: QueryOptions = {
	where: {
		score: { gte: 50 },
		ratings: { contains: 5 },
	},
};

const EVENTS_FILTER_B: QueryOptions = {
	where: {
		or: [{ score: { lt: 20 } }, { ratings: { contains: 1 } }],
	},
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
			state.eventsRecords.clear();
			for (const event of events as unknown as EventRecord[]) {
				state.eventsRecords.set(event.id, event);
			}
		},
	);
}

function waitForFilteredState(
	state: ClientState,
	expectedItemIds: Set<string>,
	expectedEventIds: Set<string>,
	timeoutMs = 10000,
): Promise<void> {
	const deadline = Date.now() + timeoutMs;
	return new Promise<void>((resolve, reject) => {
		const check = () => {
			const hasAllItems = [...expectedItemIds].every((id) =>
				state.itemsRecords.has(id),
			);
			const hasAllEvents = [...expectedEventIds].every((id) =>
				state.eventsRecords.has(id),
			);
			const noExtraItems = state.itemsRecords.size === expectedItemIds.size;
			const noExtraEvents = state.eventsRecords.size === expectedEventIds.size;

			if (hasAllItems && hasAllEvents && noExtraItems && noExtraEvents) {
				resolve();
				return;
			}
			if (Date.now() > deadline) {
				const missingItems = [...expectedItemIds].filter(
					(id) => !state.itemsRecords.has(id),
				);
				const missingEvents = [...expectedEventIds].filter(
					(id) => !state.eventsRecords.has(id),
				);
				const extraItems = [...state.itemsRecords.keys()].filter(
					(id) => !expectedItemIds.has(id),
				);
				const extraEvents = [...state.eventsRecords.keys()].filter(
					(id) => !expectedEventIds.has(id),
				);
				const parts: string[] = [];
				if (missingItems.length > 0) parts.push(`missing ${missingItems.length} items (${missingItems.join(", ")})`);
				if (missingEvents.length > 0) parts.push(`missing ${missingEvents.length} events`);
				if (extraItems.length > 0) parts.push(`extra ${extraItems.length} items`);
				if (extraEvents.length > 0) parts.push(`extra ${extraEvents.length} events`);
				reject(new Error(`Timeout: ${parts.join(", ")}`));
				return;
			}
			setTimeout(check, 100);
		};
		check();
	});
}

function computeExpectedState(
	allItems: ItemRecord[],
	allEvents: EventRecord[],
	filterLabel: "A" | "B",
): { itemIds: Set<string>; eventIds: Set<string> } {
	const itemMatches = allItems.filter((item) =>
		filterLabel === "A" ? matchesItemFilterA(item) : matchesItemFilterB(item),
	);
	const eventMatches = allEvents.filter((event) =>
		filterLabel === "A"
			? matchesEventFilterA(event)
			: matchesEventFilterB(event),
	);
	return {
		itemIds: new Set(itemMatches.map((i) => i.id)),
		eventIds: new Set(eventMatches.map((e) => e.id)),
	};
}

function closeAllClients(clients: ClientState[]) {
	for (const state of clients) {
		state.client.close();
	}
}

async function createClients(
	totalClients: number,
	port: number,
): Promise<ClientState[]> {
	const clients: ClientState[] = [];

	for (let i = 0; i < totalClients; i++) {
		const client = new ZyncBaseClient({
			url: `ws://127.0.0.1:${port}`,
			debug: i === 0,
		});
		await client.connect();
		clients.push({
			client,
			filterSet: i < 50 ? "A" : "B",
			itemsSub: null,
			eventsSub: null,
			itemsRecords: new Map(),
			eventsRecords: new Map(),
			isReadWrite: i >= totalClients - 10,
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
			rwClient.store.create("items", createItemData(i)).then((id) => {
				createdItemIds.push(id);
			}),
		);
		createPromises.push(
			rwClient.store.create("events", createEventData(i)).then((id) => {
				createdEventIds.push(id);
			}),
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

		const randomItemIdx = Math.floor(Math.random() * createdItemIds.length);
		const randomItemId = createdItemIds[randomItemIdx];
		const newPriority = Math.floor(Math.random() * 10) + 1;
		const newActive = Math.random() > 0.5;
		const newTags = Math.random() > 0.5 ? ["urgent", "updated"] : ["updated"];

		updatePromises.push(
			rwClient.store.set(["items", randomItemId], {
				priority: newPriority,
				active: newActive,
				tags: newTags,
			}),
		);

		const randomEventIdx = Math.floor(Math.random() * createdEventIds.length);
		const randomEventId = createdEventIds[randomEventIdx];
		const newScore = Math.random() * 100;
		const newRatings = Math.random() > 0.5 ? [1, 5] : [2, 3];

		updatePromises.push(
			rwClient.store.set(["events", randomEventId], {
				score: newScore,
				ratings: newRatings,
			}),
		);
	}

	await Promise.all(updatePromises);
}

async function waitForAllClients(
	clients: ClientState[],
	allItems: ItemRecord[],
	allEvents: EventRecord[],
): Promise<void> {
	const waitForPromises: Promise<void>[] = [];
	for (const state of clients) {
		const { itemIds, eventIds } = computeExpectedState(
			allItems,
			allEvents,
			state.filterSet,
		);
		if (itemIds.size > 0 || eventIds.size > 0) {
			waitForPromises.push(waitForFilteredState(state, itemIds, eventIds));
		}
	}
	await Promise.all(waitForPromises);
}

export async function run(port: number = 3000) {
	const TOTAL_CLIENTS = 100;
	const READ_WRITE_COUNT = 10;

	console.log(`Creating ${TOTAL_CLIENTS} clients...`);
	const clients = await createClients(TOTAL_CLIENTS, port);
	console.log("All clients connected.");

	const readWriteClients = clients.filter((c) => c.isReadWrite);

	console.log("Subscribing all clients and starting writes concurrently...");

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

	console.log("Fetching authoritative state from server...");
	const allItems = (await readWriteClients[0].client.store.get([
		"items",
	])) as unknown as ItemRecord[];
	const allEvents = (await readWriteClients[0].client.store.get([
		"events",
	])) as unknown as EventRecord[];
	console.log(
		`Server has ${allItems.length} items and ${allEvents.length} events.`,
	);

	console.log("Waiting for all clients to receive their filtered state...");
	await waitForAllClients(clients, allItems, allEvents);
	console.log("All clients have received their filtered state.");

	closeAllClients(clients);

	console.log(`All ${TOTAL_CLIENTS} clients have correct filtered state.`);
	console.log("E2E Filters test passed successfully!");
}
