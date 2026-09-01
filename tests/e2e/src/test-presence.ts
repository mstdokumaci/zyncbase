import type { PresenceChangeBatch, PresenceEntry } from "@zyncbase/client";
import { ZyncBaseClient } from "./client";
import { createTestJwt } from "./harness";

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

function verifyIncludeSelf(clientB: ZyncBaseClient): void {
	const allUsersIncludingSelf = clientB.presence.getAll({ includeSelf: true });
	const namesIncludingSelf = new Set(
		allUsersIncludingSelf.map((user) => user.data.name),
	);
	if (
		allUsersIncludingSelf.length !== 2 ||
		!namesIncludingSelf.has("Alice") ||
		!namesIncludingSelf.has("Bob")
	) {
		throw new Error(
			`Expected includeSelf view to contain Alice and Bob, got ${JSON.stringify([...namesIncludingSelf])}`,
		);
	}
}

function verifyDeltaUpdate(bChanges: PresenceChangeBatch[]): void {
	const updateBatch = bChanges.find(
		(batch) =>
			batch.type === "changes" &&
			batch.changes.some(
				(c) => c.type === "update" && c.entry.data.name === "Alice",
			),
	);
	if (!updateBatch || updateBatch.type !== "changes") {
		throw new Error("Expected update change batch for Alice in delta stream");
	}
	const aliceUpdate = updateBatch.changes.find(
		(c) => c.type === "update" && c.entry.data.name === "Alice",
	);
	if (!aliceUpdate || aliceUpdate.type !== "update") {
		throw new Error("Expected update change for Alice in delta stream");
	}
	if (
		aliceUpdate.entry.data.status !== "active" ||
		(aliceUpdate.entry.data.cursor as { x: number; y: number })?.x !== 100 ||
		(aliceUpdate.entry.data.cursor as { x: number; y: number })?.y !== 200
	) {
		throw new Error(
			`Expected fully merged update entry in delta stream, got ${JSON.stringify(aliceUpdate.entry.data)}`,
		);
	}
	console.log("  Delta subscription received fully merged update entry.");
}

async function testUserPresence(
	clientA: ZyncBaseClient,
	clientB: ZyncBaseClient,
	bChanges: PresenceChangeBatch[],
): Promise<() => void> {
	console.log("Test 1: User presence set + subscribe...");

	const bUsers: PresenceEntry[][] = [];
	const unsubB = clientB.presence.subscribe((users) => {
		bUsers.push(users);
	});

	clientB.presence.set({ status: "active", name: "Bob" });
	clientA.presence.set({ status: "active", name: "Alice" });

	await waitForPresence(
		clientB,
		(users) =>
			users.some((u) => u.data.name === "Alice") &&
			clientB.presence
				.getAll({ includeSelf: true })
				.some((u) => u.data.name === "Bob"),
	);
	console.log("  Client B received Client A's presence.");

	if (bChanges.length === 0 || bChanges[0].type !== "snapshot") {
		throw new Error("Expected initial delta snapshot batch on client B");
	}
	console.log("  Client B received initial delta snapshot.");

	const allUsers = clientB.presence.getAll();
	if (allUsers.length !== 1 || allUsers[0].data.name !== "Alice") {
		throw new Error(`Expected name 'Alice', got '${allUsers[0]?.data?.name}'`);
	}
	verifyIncludeSelf(clientB);
	console.log("  getAll() excludes Bob; includeSelf contains Alice and Bob.");

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
	if (!aliceEntry || aliceEntry.data.status !== "active") {
		throw new Error(
			`Expected status 'active' after cursor update, got '${aliceEntry?.data?.status}'`,
		);
	}
	console.log("  Merge semantics verified.");

	verifyDeltaUpdate(bChanges);

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
	bChanges: PresenceChangeBatch[],
): Promise<void> {
	console.log("Test 6: Presence remove...");
	clientA.presence.remove();
	await waitForPresence(clientB, (users) => users.length === 0);
	const includingSelf = clientB.presence.getAll({ includeSelf: true });
	if (includingSelf.length !== 1 || includingSelf[0].data.name !== "Bob") {
		throw new Error(
			`Expected only Bob in includeSelf view after Alice left, got ${JSON.stringify(includingSelf)}`,
		);
	}
	console.log(
		"  Client B default state is empty after Alice left; includeSelf retains Bob.",
	);

	const leaveBatch = bChanges.find(
		(batch) =>
			batch.type === "changes" && batch.changes.some((c) => c.type === "leave"),
	);
	if (!leaveBatch || leaveBatch.type !== "changes") {
		throw new Error("Expected leave change batch in delta stream");
	}
	console.log("  Delta subscription received leave notification.");

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
	bChanges: PresenceChangeBatch[],
): Promise<void> {
	console.log("Test 8: Namespace switch...");
	const initialLen = bChanges.length;
	await clientA.setPresenceNamespace("other-room");
	await clientB.setPresenceNamespace("other-room");

	for (let i = 0; i < 20; i++) {
		if (
			bChanges.length > initialLen &&
			bChanges[bChanges.length - 1].type === "snapshot"
		) {
			break;
		}
		await sleep(50);
	}

	const afterSwitch = clientB.presence.getAll();
	if (afterSwitch.length !== 0) {
		throw new Error(
			`Expected empty presence after namespace switch, got ${afterSwitch.length} users`,
		);
	}
	console.log("  Namespace switch clears presence cache.");

	const lastBatch = bChanges[bChanges.length - 1];
	if (
		!lastBatch ||
		lastBatch.type !== "snapshot" ||
		lastBatch.users.length !== 0
	) {
		throw new Error(
			`Expected replacement snapshot batch after namespace switch, got ${JSON.stringify(lastBatch)}`,
		);
	}
	console.log(
		"  Delta subscription received replacement snapshot after namespace switch.",
	);
}

export async function run(port: number, jwtSecret: string) {
	const url = `ws://127.0.0.1:${port}`;
	const clientA = new ZyncBaseClient({
		url,
		auth: { token: createTestJwt(jwtSecret, "presence-alice") },
	});
	const clientB = new ZyncBaseClient({
		url,
		auth: { token: createTestJwt(jwtSecret, "presence-bob") },
	});

	try {
		console.log("Connecting clients...");
		await Promise.all([clientA.connect(), clientB.connect()]);
		console.log("Clients connected.");

		await clientA.setPresenceNamespace("public");
		await clientB.setPresenceNamespace("public");

		const bChanges: PresenceChangeBatch[] = [];
		const unsubDeltaB = clientB.presence.subscribeChanges((batch) => {
			bChanges.push(batch);
		});

		const unsubB = await testUserPresence(clientA, clientB, bChanges);
		const unsubShared = await testSharedState(clientA, clientB);

		const bUsers: PresenceEntry[][] = [];
		clientB.presence.subscribe((users) => bUsers.push(users));

		await testRemoveAndThrottle(clientA, clientB, bUsers, bChanges);
		await testNamespaceSwitch(clientA, clientB, bChanges);

		unsubB();
		unsubDeltaB();
		unsubShared();

		console.log("All presence tests passed!");
	} finally {
		clientA.close();
		clientB.close();
	}
}
