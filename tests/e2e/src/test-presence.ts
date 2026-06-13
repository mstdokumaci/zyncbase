import type { PresenceEntry } from "@zyncbase/client";
import { ZyncBaseClient } from "./client";

function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForPresence(
	client: ZyncBaseClient,
	predicate: (users: PresenceEntry[]) => boolean,
	timeoutMs = 3000,
): Promise<PresenceEntry[]> {
	return new Promise<PresenceEntry[]>((resolve, reject) => {
		const timer = setTimeout(() => {
			unsub();
			reject(new Error(`Timeout waiting for presence after ${timeoutMs}ms`));
		}, timeoutMs);

		const unsub = client.presence.subscribe((users) => {
			if (predicate(users)) {
				clearTimeout(timer);
				unsub();
				resolve(users);
			}
		});
	});
}

async function waitForShared(
	client: ZyncBaseClient,
	predicate: (shared: Record<string, unknown> | null) => boolean,
	timeoutMs = 3000,
): Promise<Record<string, unknown> | null> {
	return new Promise<Record<string, unknown> | null>((resolve, reject) => {
		const timer = setTimeout(() => {
			unsub();
			reject(
				new Error(`Timeout waiting for shared state after ${timeoutMs}ms`),
			);
		}, timeoutMs);

		const unsub = client.presence.subscribeShared((shared) => {
			if (predicate(shared)) {
				clearTimeout(timer);
				unsub();
				resolve(shared);
			}
		});
	});
}

async function testUserPresence(
	clientA: ZyncBaseClient,
	clientB: ZyncBaseClient,
): Promise<() => void> {
	console.log("Test 1: User presence set + subscribe...");

	const bUsers: PresenceEntry[][] = [];
	const unsubB = clientB.presence.subscribe((users) => {
		bUsers.push(users);
	});

	clientA.presence.set({ status: "active", name: "Alice" });

	await waitForPresence(clientB, (users) =>
		users.some((u) => u.data.name === "Alice"),
	);
	console.log("  Client B received Client A's presence.");

	const allUsers = clientB.presence.getAll();
	if (allUsers.length !== 1) {
		throw new Error(`Expected 1 user, got ${allUsers.length}`);
	}
	if (allUsers[0].data.name !== "Alice") {
		throw new Error(`Expected name 'Alice', got '${allUsers[0].data.name}'`);
	}
	console.log("  getAll() returns correct user.");

	console.log("Test 2: Merge semantics...");
	clientA.presence.set({ cursor: { x: 100, y: 200 } });

	await waitForPresence(clientB, (users) => {
		const alice = users.find((u) => u.data.name === "Alice");
		return (
			alice !== undefined && (alice.data.cursor as { x: number })?.x === 100
		);
	});

	const aliceEntry = clientB.presence
		.getAll()
		.find((u) => u.data.name === "Alice");
	if (!aliceEntry) throw new Error("Alice not found");
	if (aliceEntry.data.status !== "active") {
		throw new Error(
			`Expected status 'active' after cursor update, got '${aliceEntry.data.status}'`,
		);
	}
	console.log("  Merge semantics verified.");

	console.log("Test 3: Nested field unflattening...");
	const cursor = aliceEntry.data.cursor as { x: number; y: number };
	if (cursor.x !== 100 || cursor.y !== 200) {
		throw new Error(
			`Expected cursor {x:100, y:200}, got ${JSON.stringify(cursor)}`,
		);
	}
	console.log("  Nested cursor field correctly unflattened.");

	return unsubB;
}

async function testSharedState(
	clientA: ZyncBaseClient,
	clientB: ZyncBaseClient,
): Promise<() => void> {
	console.log("Test 4: Shared state...");

	const sharedStates: (Record<string, unknown> | null)[] = [];
	const unsubShared = clientB.presence.subscribeShared((shared) => {
		sharedStates.push(shared);
	});

	clientA.presence.setShared({ slide: 5 });

	await waitForShared(
		clientB,
		(shared) => shared !== null && shared.slide === 5,
	);
	console.log("  Client B received shared state from Client A.");

	const shared = clientB.presence.getShared();
	if (!shared || shared.slide !== 5) {
		throw new Error(`Expected shared.slide=5, got ${JSON.stringify(shared)}`);
	}
	console.log("  getShared() returns correct state.");

	console.log("Test 5: Shared state merge...");
	clientA.presence.setShared({ playing: true });

	await waitForShared(
		clientB,
		(s) => s !== null && s.playing === true && s.slide === 5,
	);

	const mergedShared = clientB.presence.getShared();
	if (
		!mergedShared ||
		mergedShared.slide !== 5 ||
		mergedShared.playing !== true
	) {
		throw new Error(
			`Expected merged shared {slide:5, playing:true}, got ${JSON.stringify(mergedShared)}`,
		);
	}
	console.log("  Shared state merge verified.");

	return unsubShared;
}

async function testRemoveAndThrottle(
	clientA: ZyncBaseClient,
	clientB: ZyncBaseClient,
	bUsers: PresenceEntry[][],
): Promise<void> {
	console.log("Test 6: Presence remove...");
	clientA.presence.remove();
	await waitForPresence(clientB, (users) => users.length === 0);
	console.log(
		"  Client B received leave event after Client A removed presence.",
	);

	console.log("Test 7: Throttle (~60fps)...");
	const beforeCount = bUsers.length;
	for (let i = 0; i < 10; i++) {
		clientA.presence.set({ cursor: { x: i, y: i } });
	}
	await sleep(100);

	const updatesReceived = bUsers.length - beforeCount;
	console.log(
		`  Received ${updatesReceived} updates from 10 rapid set() calls.`,
	);
	if (updatesReceived >= 10) {
		throw new Error(
			`Throttle not working: received ${updatesReceived} updates from 10 rapid calls`,
		);
	}
	console.log("  Throttle verified.");
}

async function testNamespaceSwitch(
	clientA: ZyncBaseClient,
	clientB: ZyncBaseClient,
): Promise<void> {
	console.log("Test 8: Namespace switch...");
	await clientA.setPresenceNamespace("other-room");
	await clientB.setPresenceNamespace("other-room");

	const afterSwitch = clientB.presence.getAll();
	if (afterSwitch.length !== 0) {
		throw new Error(
			`Expected empty presence after namespace switch, got ${afterSwitch.length} users`,
		);
	}
	console.log("  Namespace switch clears presence cache.");
}

export async function run(port: number = 3000) {
	const clientA = new ZyncBaseClient(`ws://127.0.0.1:${port}`);
	const clientB = new ZyncBaseClient(`ws://127.0.0.1:${port}`);

	try {
		console.log("Connecting clients...");
		await Promise.all([clientA.connect(), clientB.connect()]);
		console.log("Clients connected.");

		await clientA.setPresenceNamespace("public");
		await clientB.setPresenceNamespace("public");

		const unsubB = await testUserPresence(clientA, clientB);
		const unsubShared = await testSharedState(clientA, clientB);

		const bUsers: PresenceEntry[][] = [];
		clientB.presence.subscribe((users) => bUsers.push(users));

		await testRemoveAndThrottle(clientA, clientB, bUsers);
		await testNamespaceSwitch(clientA, clientB);

		unsubB();
		unsubShared();

		console.log("All presence tests passed!");
	} finally {
		clientA.close();
		clientB.close();
	}
}
