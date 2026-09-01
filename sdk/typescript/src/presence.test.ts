import { describe, expect, jest, test } from "bun:test";
import { packDocId } from "./doc_id.js";
import { PresenceImpl } from "./presence.js";
import { SchemaDictionary } from "./schema_dictionary.js";
import type {
	OkResponse,
	PresenceBroadcast,
	PresenceChangeBatch,
	SharedStateBroadcast,
} from "./types.js";

function createMockConnection() {
	const dispatched: Record<string, unknown>[] = [];
	const schema = new SchemaDictionary();
	let presenceBroadcastHandler:
		| ((msg: PresenceBroadcast | SharedStateBroadcast) => void)
		| null = null;

	return {
		dispatch: (msg: Record<string, unknown>) => {
			const encoded = { ...msg };
			if (
				msg.type === "PresenceSet" &&
				msg.data &&
				typeof msg.data === "object"
			) {
				encoded.data = schema.encodePresenceUserValue(
					msg.data as Record<string, unknown>,
				);
			} else if (
				msg.type === "PresenceSetShared" &&
				msg.data &&
				typeof msg.data === "object"
			) {
				encoded.data = schema.encodePresenceSharedValue(
					msg.data as Record<string, unknown>,
				);
			}
			dispatched.push(encoded);
			return Promise.resolve({ type: "ok", id: 0 } as OkResponse);
		},
		onPresenceBroadcast: (
			handler: (msg: PresenceBroadcast | SharedStateBroadcast) => void,
		) => {
			presenceBroadcastHandler = handler;
		},
		on: () => {},
		schemaDictionary: schema,
		dispatched,
		schema,
		fireBroadcast: (msg: PresenceBroadcast | SharedStateBroadcast) => {
			presenceBroadcastHandler?.(msg);
		},
	};
}

async function setupSchema(schema: SchemaDictionary) {
	await schema.processSchemaSync({
		tables: ["users"],
		fields: [["id", "name"]],
		fieldFlags: [[3, 0]],
		presenceUserFields: ["cursor__x", "cursor__y", "status"],
		presenceSharedFields: ["slide", "playing"],
	});
}

describe("PresenceImpl", () => {
	test("set() dispatches PresenceSet with encoded data", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);

		presence.set({ status: "active" });

		expect(conn.dispatched.length).toBe(1);
		expect(conn.dispatched[0].type).toBe("PresenceSet");
		const data = conn.dispatched[0].data as Array<[number, unknown]>;
		const statusPair = data.find((pair) => pair[0] === 2);
		expect(statusPair).toBeDefined();
		expect(statusPair?.[1]).toBe("active");
	});

	test("set() throttles to ~60fps", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);

		presence.set({ cursor: { x: 1, y: 2 } });
		presence.set({ cursor: { x: 3, y: 4 } });
		presence.set({ cursor: { x: 5, y: 6 } });

		expect(conn.dispatched.length).toBe(1);

		await new Promise((resolve) => setTimeout(resolve, 20));

		expect(conn.dispatched.length).toBe(2);
	});

	test("set() does not let a throttle timer overwrite newer data", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);

		jest.useFakeTimers();
		try {
			jest.advanceTimersByTime(16);
			presence.set({ cursor: { x: 1, y: 1 } });
			presence.set({ cursor: { x: 2, y: 2 } });
			jest.advanceTimersByTime(15);
			presence.set({ cursor: { x: 3, y: 3 } });
			jest.advanceTimersByTime(1);

			expect(conn.dispatched.length).toBe(2);
			const data = conn.dispatched.at(-1)?.data as Array<[number, unknown]>;
			expect(data.find(([index]) => index === 1)?.[1]).toBe(3);
		} finally {
			jest.useRealTimers();
		}
	});

	test("setShared() dispatches PresenceSetShared with encoded data", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);

		presence.setShared({ slide: 5 });

		expect(conn.dispatched.length).toBe(1);
		expect(conn.dispatched[0].type).toBe("PresenceSetShared");
		const data = conn.dispatched[0].data as Array<[number, unknown]>;
		const slidePair = data.find((pair) => pair[0] === 0);
		expect(slidePair).toBeDefined();
		expect(slidePair?.[1]).toBe(5);
	});

	test("remove() dispatches PresenceRemove", () => {
		const conn = createMockConnection();
		const presence = new PresenceImpl(conn);

		presence.remove();

		expect(conn.dispatched.length).toBe(1);
		expect(conn.dispatched[0].type).toBe("PresenceRemove");
	});

	test("subscribe() dispatches PresenceSubscribe and populates cache from snapshot", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);

		conn.dispatch = (msg: Record<string, unknown>) => {
			conn.dispatched.push(msg);
			if (msg.type === "PresenceSubscribe") {
				return Promise.resolve({
					type: "ok",
					id: 0,
					subId: 100,
					users: [
						{
							userId: packDocId("user_1"),
							data: conn.schema.decodePresenceUserValue([
								[0, 100],
								[1, 200],
								[2, "active"],
							]),
							joinedAt: 1234567890,
						},
					],
				} as OkResponse);
			}
			return Promise.resolve({ type: "ok", id: 0 } as OkResponse);
		};

		let receivedUsers: { userId: string; data: Record<string, unknown> }[] = [];
		presence.subscribe((users) => {
			receivedUsers = users;
		});

		await new Promise((resolve) => setTimeout(resolve, 10));

		expect(conn.dispatched[0].type).toBe("PresenceSubscribe");
		expect(receivedUsers.length).toBe(1);
		expect(receivedUsers[0].data).toEqual({
			cursor: { x: 100, y: 200 },
			status: "active",
		});
	});

	test("subscribe() returns unsubscribe function that dispatches PresenceUnsubscribe", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);

		conn.dispatch = (msg: Record<string, unknown>) => {
			conn.dispatched.push(msg);
			if (msg.type === "PresenceSubscribe") {
				return Promise.resolve({
					type: "ok",
					id: 0,
					subId: 100,
					users: [],
				} as OkResponse);
			}
			return Promise.resolve({ type: "ok", id: 0 } as OkResponse);
		};

		const unsubscribe = presence.subscribe(() => {});
		await new Promise((resolve) => setTimeout(resolve, 10));

		unsubscribe();

		expect(conn.dispatched.some((m) => m.type === "PresenceUnsubscribe")).toBe(
			true,
		);
	});

	test("get() returns cached user entry", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);

		conn.dispatch = (msg: Record<string, unknown>) => {
			if (msg.type === "PresenceSubscribe") {
				return Promise.resolve({
					type: "ok",
					id: 0,
					subId: 100,
					users: [
						{
							userId: packDocId("user_1"),
							data: conn.schema.decodePresenceUserValue([[2, "active"]]),
							joinedAt: 1234567890,
						},
					],
				} as OkResponse);
			}
			return Promise.resolve({ type: "ok", id: 0 } as OkResponse);
		};

		presence.subscribe(() => {});
		await new Promise((resolve) => setTimeout(resolve, 10));

		const userId = conn.schema.decodePresenceUserId(packDocId("user_1"));
		const entry = presence.get(userId);
		expect(entry).toBeDefined();
		expect(entry?.data.status).toBe("active");
	});

	test("getAll() excludes self by default", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);
		presence.setLocalUserId(
			conn.schema.decodePresenceUserId(packDocId("user_1")),
		);

		conn.dispatch = (msg: Record<string, unknown>) => {
			if (msg.type === "PresenceSubscribe") {
				return Promise.resolve({
					type: "ok",
					id: 0,
					subId: 100,
					users: [
						{
							userId: packDocId("user_1"),
							data: conn.schema.decodePresenceUserValue([[2, "active"]]),
							joinedAt: 1234567890,
						},
					],
				} as OkResponse);
			}
			return Promise.resolve({ type: "ok", id: 0 } as OkResponse);
		};

		presence.subscribe(() => {});
		await new Promise((resolve) => setTimeout(resolve, 10));

		const others = presence.getAll();
		expect(others.length).toBe(0);

		const everyone = presence.getAll({ includeSelf: true });
		expect(everyone.length).toBe(1);
	});

	test("PresenceBroadcast updates cache and fires callbacks", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);

		conn.dispatch = (msg: Record<string, unknown>) => {
			if (msg.type === "PresenceSubscribe") {
				return Promise.resolve({
					type: "ok",
					id: 0,
					subId: 100,
					users: [],
				} as OkResponse);
			}
			return Promise.resolve({ type: "ok", id: 0 } as OkResponse);
		};

		let callbackCount = 0;
		presence.subscribe(() => {
			callbackCount++;
		});
		await new Promise((resolve) => setTimeout(resolve, 10));

		conn.fireBroadcast({
			type: "PresenceBroadcast",
			subId: 100,
			users: [
				{
					userId: packDocId("user_2"),
					event: "join",
					data: conn.schema.decodePresenceUserValue([
						[0, 50],
						[1, 75],
					]),
					joinedAt: 9999,
				},
			],
		} as PresenceBroadcast);

		expect(callbackCount).toBe(2);
		const userId = conn.schema.decodePresenceUserId(packDocId("user_2"));
		const entry = presence.get(userId);
		expect(entry?.data).toEqual({ cursor: { x: 50, y: 75 } });
	});

	test("PresenceBroadcast removal preserves lookups and older snapshots", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);

		conn.dispatch = (msg: Record<string, unknown>) => {
			if (msg.type === "PresenceSubscribe") {
				return Promise.resolve({
					type: "ok",
					id: 0,
					subId: 100,
					users: [
						{
							userId: packDocId("user_3"),
							data: conn.schema.decodePresenceUserValue([[2, "active"]]),
							joinedAt: 1111,
						},
						{
							userId: packDocId("user_4"),
							data: conn.schema.decodePresenceUserValue([[2, "active"]]),
							joinedAt: 2222,
						},
					],
				} as OkResponse);
			}
			return Promise.resolve({ type: "ok", id: 0 } as OkResponse);
		};

		const snapshots: Array<ReturnType<typeof presence.getAll>> = [];
		presence.subscribe((users) => snapshots.push(users));
		await new Promise((resolve) => setTimeout(resolve, 10));
		const initialSnapshot = snapshots[0];

		conn.fireBroadcast({
			type: "PresenceBroadcast",
			subId: 100,
			users: [
				{
					userId: packDocId("user_3"),
					event: "leave",
				},
			],
		} as PresenceBroadcast);

		const removedId = conn.schema.decodePresenceUserId(packDocId("user_3"));
		const retainedId = conn.schema.decodePresenceUserId(packDocId("user_4"));
		expect(presence.get(removedId)).toBeUndefined();
		expect(presence.get(retainedId)?.data.status).toBe("active");
		expect(presence.getAll().map((entry) => entry.userId)).toEqual([
			retainedId,
		]);
		expect(snapshots[1]).not.toBe(initialSnapshot);
		expect(initialSnapshot.map((entry) => entry.userId)).toEqual([
			removedId,
			retainedId,
		]);

		conn.fireBroadcast({
			type: "PresenceBroadcast",
			subId: 100,
			users: [
				{
					userId: packDocId("user_4"),
					event: "update",
					data: conn.schema.decodePresenceUserValue([[2, "idle"]]),
				},
			],
		} as PresenceBroadcast);

		expect(presence.get(retainedId)?.data.status).toBe("idle");
		expect(initialSnapshot[1].data.status).toBe("active");
	});

	test("PresenceBroadcast update for unknown user inserts entry with fallback joinedAt 0", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);

		conn.dispatch = (msg: Record<string, unknown>) => {
			if (msg.type === "PresenceSubscribe") {
				return Promise.resolve({
					type: "ok",
					id: 0,
					subId: 100,
					users: [],
				} as OkResponse);
			}
			return Promise.resolve({ type: "ok", id: 0 } as OkResponse);
		};

		presence.subscribe(() => {});
		await new Promise((resolve) => setTimeout(resolve, 10));

		conn.fireBroadcast({
			type: "PresenceBroadcast",
			subId: 100,
			users: [
				{
					userId: packDocId("user_5"),
					event: "update",
					data: conn.schema.decodePresenceUserValue([[2, "online"]]),
				},
			],
		} as PresenceBroadcast);

		const unknownId = conn.schema.decodePresenceUserId(packDocId("user_5"));
		const entry = presence.get(unknownId);
		expect(entry).toBeDefined();
		expect(entry?.joinedAt).toBe(0);
		expect(entry?.data.status).toBe("online");
	});

	test("subscribeShared() dispatches PresenceSubscribeShared and populates cache", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);

		conn.dispatch = (msg: Record<string, unknown>) => {
			conn.dispatched.push(msg);
			if (msg.type === "PresenceSubscribeShared") {
				return Promise.resolve({
					type: "ok",
					id: 0,
					subId: 200,
					shared: conn.schema.decodePresenceSharedValue([
						[0, 5],
						[1, true],
					]),
				} as OkResponse);
			}
			return Promise.resolve({ type: "ok", id: 0 } as OkResponse);
		};

		let receivedShared: Record<string, unknown> | null = null;
		presence.subscribeShared((shared) => {
			receivedShared = shared;
		});

		await new Promise((resolve) => setTimeout(resolve, 10));

		expect(conn.dispatched[0].type).toBe("PresenceSubscribeShared");
		expect(receivedShared).toEqual({ slide: 5, playing: true });
	});

	test("getShared() returns cached shared state", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);

		conn.dispatch = (msg: Record<string, unknown>) => {
			if (msg.type === "PresenceSubscribeShared") {
				return Promise.resolve({
					type: "ok",
					id: 0,
					subId: 200,
					shared: conn.schema.decodePresenceSharedValue([[0, 10]]),
				} as OkResponse);
			}
			return Promise.resolve({ type: "ok", id: 0 } as OkResponse);
		};

		presence.subscribeShared(() => {});
		await new Promise((resolve) => setTimeout(resolve, 10));

		expect(presence.getShared()).toEqual({ slide: 10 });
	});

	test("SharedStateBroadcast merges into cache", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);

		conn.dispatch = (msg: Record<string, unknown>) => {
			if (msg.type === "PresenceSubscribeShared") {
				return Promise.resolve({
					type: "ok",
					id: 0,
					subId: 200,
					shared: conn.schema.decodePresenceSharedValue([[0, 1]]),
				} as OkResponse);
			}
			return Promise.resolve({ type: "ok", id: 0 } as OkResponse);
		};

		let receivedShared: Record<string, unknown> | null = null;
		presence.subscribeShared((shared) => {
			receivedShared = shared;
		});
		await new Promise((resolve) => setTimeout(resolve, 10));

		conn.fireBroadcast({
			type: "SharedStateBroadcast",
			subId: 200,
			data: [conn.schema.decodePresenceSharedValue([[1, false]])],
		} as SharedStateBroadcast);

		expect(receivedShared).toEqual({ slide: 1, playing: false });
	});

	test("invalidate() clears caches and subIds but preserves callbacks", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);

		let callbackFired = false;

		conn.dispatch = (msg: Record<string, unknown>) => {
			if (msg.type === "PresenceSubscribe") {
				return Promise.resolve({
					type: "ok",
					id: 0,
					subId: 100,
					users: [
						{
							userId: packDocId("user_1"),
							data: conn.schema.decodePresenceUserValue([[2, "active"]]),
							joinedAt: 1234,
						},
					],
				} as OkResponse);
			}
			return Promise.resolve({ type: "ok", id: 0 } as OkResponse);
		};

		presence.subscribe(() => {
			callbackFired = true;
		});
		await new Promise((resolve) => setTimeout(resolve, 10));

		expect(presence.getAll().length).toBe(1);

		presence.invalidate();

		// Caches cleared but callbacks survive
		expect(presence.getAll().length).toBe(0);
		expect(presence.getShared()).toBeNull();

		// replaySubscriptions should work because callbacks are preserved
		callbackFired = false;
		presence.replaySubscriptions();
		await new Promise((resolve) => setTimeout(resolve, 10));
		expect(callbackFired).toBe(true);
	});

	test("stale subscribe promise does not overwrite cache after invalidate()", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);

		let resolveStale: (value: OkResponse) => void = () => {};
		const stalePromise = new Promise<OkResponse>((resolve) => {
			resolveStale = resolve;
		});

		let isFirstSubscribe = true;
		conn.dispatch = (msg: Record<string, unknown>) => {
			if (msg.type === "PresenceSubscribe") {
				if (isFirstSubscribe) {
					isFirstSubscribe = false;
					return stalePromise;
				}
				// Second subscribe = new namespace data
				return Promise.resolve({
					type: "ok",
					id: 0,
					subId: 200,
					users: [
						{
							userId: packDocId("user_2"),
							data: conn.schema.decodePresenceUserValue([[2, "new_status"]]),
							joinedAt: 5678,
						},
					],
				} as OkResponse);
			}
			return Promise.resolve({ type: "ok", id: 0 } as OkResponse);
		};

		presence.subscribe(() => {});
		expect(presence.getAll().length).toBe(0);

		// Simulate namespace switch: invalidate then re-subscribe
		presence.invalidate();
		presence.replaySubscriptions();
		await new Promise((resolve) => setTimeout(resolve, 10));

		// Cache has new data
		expect(presence.getAll().length).toBe(1);

		// Now resolve the stale promise from the old subscription
		resolveStale({
			type: "ok",
			id: 0,
			subId: 100,
			users: [
				{
					userId: packDocId("user_1"),
					data: conn.schema.decodePresenceUserValue([[2, "stale_status"]]),
					joinedAt: 1234,
				},
			],
		} as OkResponse);
		await new Promise((resolve) => setTimeout(resolve, 10));

		// Cache should NOT have stale data — still has the new namespace data
		expect(presence.getAll().length).toBe(1);
		const newUserId = conn.schema.decodePresenceUserId(packDocId("user_2"));
		expect(presence.get(newUserId)).toBeDefined();
		const staleUserId = conn.schema.decodePresenceUserId(packDocId("user_1"));
		expect(presence.get(staleUserId)).toBeUndefined();
	});

	test("invalidate() resets lastSetTime so first set() after reconnect is not throttled", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);

		presence.set({ status: "active" });
		expect(conn.dispatched.length).toBe(1);

		// Without resetting lastSetTime, the second set would compute
		// elapsed < THROTTLE_INTERVAL_MS and be throttled/delayed.
		presence.invalidate();
		presence.set({ status: "away" });

		// With the fix, second set dispatches immediately.
		expect(conn.dispatched.length).toBe(2);
	});

	test("replaySubscriptions unsubscribes user if client unsubscribed before promise resolves", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);

		let resolveReplay: (value: OkResponse) => void = () => {};
		const replayPromise = new Promise<OkResponse>((resolve) => {
			resolveReplay = resolve;
		});

		let subscribeCall = 0;
		const handleSubscribe = (msg: Record<string, unknown>) => {
			if (msg.type !== "PresenceSubscribe") return null;
			subscribeCall++;
			if (subscribeCall === 1) {
				return Promise.resolve({
					type: "ok",
					id: 0,
					subId: 100,
					users: [],
				} as OkResponse);
			}
			if (subscribeCall === 2) return replayPromise;
			return null;
		};
		conn.dispatch = (msg: Record<string, unknown>) => {
			conn.dispatched.push(msg);
			return (
				handleSubscribe(msg) ??
				Promise.resolve({ type: "ok", id: 0 } as OkResponse)
			);
		};

		const unsubscribe = presence.subscribe(() => {});
		await new Promise((resolve) => setTimeout(resolve, 10));

		expect(
			conn.dispatched.filter((m) => m.type === "PresenceSubscribe").length,
		).toBe(1);

		conn.dispatched.length = 0;

		presence.invalidate();
		presence.replaySubscriptions();

		unsubscribe();

		resolveReplay({
			type: "ok",
			id: 0,
			subId: 200,
			users: [],
		} as OkResponse);
		await new Promise((resolve) => setTimeout(resolve, 10));

		const unsubMsgs = conn.dispatched.filter(
			(m) => m.type === "PresenceUnsubscribe",
		);
		expect(unsubMsgs.length).toBe(1);
		expect(unsubMsgs[0].subId).toBe(200);
	});

	test("replaySubscriptions unsubscribes shared if client unsubscribed before promise resolves", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);

		let resolveReplay: (value: OkResponse) => void = () => {};
		const replayPromise = new Promise<OkResponse>((resolve) => {
			resolveReplay = resolve;
		});

		let subscribeCall = 0;
		const handleSubscribeShared = (msg: Record<string, unknown>) => {
			if (msg.type !== "PresenceSubscribeShared") return null;
			subscribeCall++;
			if (subscribeCall === 1) {
				return Promise.resolve({
					type: "ok",
					id: 0,
					subId: 100,
				} as OkResponse);
			}
			if (subscribeCall === 2) return replayPromise;
			return null;
		};
		conn.dispatch = (msg: Record<string, unknown>) => {
			conn.dispatched.push(msg);
			return (
				handleSubscribeShared(msg) ??
				Promise.resolve({ type: "ok", id: 0 } as OkResponse)
			);
		};

		const unsubscribe = presence.subscribeShared(() => {});
		await new Promise((resolve) => setTimeout(resolve, 10));

		expect(
			conn.dispatched.filter((m) => m.type === "PresenceSubscribeShared")
				.length,
		).toBe(1);

		conn.dispatched.length = 0;

		presence.invalidate();
		presence.replaySubscriptions();

		unsubscribe();

		resolveReplay({
			type: "ok",
			id: 0,
			subId: 200,
		} as OkResponse);
		await new Promise((resolve) => setTimeout(resolve, 10));

		const unsubMsgs = conn.dispatched.filter(
			(m) => m.type === "PresenceUnsubscribeShared",
		);
		expect(unsubMsgs.length).toBe(1);
		expect(unsubMsgs[0].subId).toBe(200);
	});

	test("subscribeChanges receives initial snapshot followed by ordered join, update, leave batch", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);

		conn.dispatch = (msg: Record<string, unknown>) => {
			if (msg.type === "PresenceSubscribe") {
				return Promise.resolve({
					type: "ok",
					id: 0,
					subId: 100,
					users: [
						{
							userId: packDocId("user_1"),
							data: conn.schema.decodePresenceUserValue([
								[0, 10],
								[1, 20],
								[2, "online"],
							]),
							joinedAt: 1000,
						},
					],
				} as OkResponse);
			}
			return Promise.resolve({ type: "ok", id: 0 } as OkResponse);
		};

		const batches: PresenceChangeBatch[] = [];
		presence.subscribeChanges((batch) => {
			batches.push(batch);
		});

		await new Promise((resolve) => setTimeout(resolve, 10));

		expect(batches.length).toBe(1);
		expect(batches[0].type).toBe("snapshot");
		if (batches[0].type === "snapshot") {
			expect(batches[0].users.length).toBe(1);
			expect(batches[0].users[0].data).toEqual({
				cursor: { x: 10, y: 20 },
				status: "online",
			});
		}

		conn.fireBroadcast({
			type: "PresenceBroadcast",
			subId: 100,
			users: [
				{
					userId: packDocId("user_2"),
					event: "join",
					data: conn.schema.decodePresenceUserValue([
						[0, 30],
						[1, 40],
						[2, "active"],
					]),
					joinedAt: 2000,
				},
				{
					userId: packDocId("user_1"),
					event: "update",
					data: conn.schema.decodePresenceUserValue([[2, "away"]]),
				},
				{
					userId: packDocId("user_2"),
					event: "leave",
				},
			],
		} as PresenceBroadcast);

		expect(batches.length).toBe(2);
		expect(batches[1].type).toBe("changes");
		if (batches[1].type === "changes") {
			expect(batches[1].changes.length).toBe(3);
			expect(batches[1].changes[0]).toEqual({
				type: "join",
				entry: {
					userId: conn.schema.decodePresenceUserId(packDocId("user_2")),
					data: { cursor: { x: 30, y: 40 }, status: "active" },
					joinedAt: 2000,
				},
			});
			expect(batches[1].changes[1]).toEqual({
				type: "update",
				entry: {
					userId: conn.schema.decodePresenceUserId(packDocId("user_1")),
					data: { cursor: { x: 10, y: 20 }, status: "away" },
					joinedAt: 1000,
				},
			});
			expect(batches[1].changes[2]).toEqual({
				type: "leave",
				userId: conn.schema.decodePresenceUserId(packDocId("user_2")),
			});
		}
	});

	test("subscribeChanges excludes self from snapshot and delta changes", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);
		const selfId = conn.schema.decodePresenceUserId(packDocId("user_self"));
		presence.setLocalUserId(selfId);

		conn.dispatch = (msg: Record<string, unknown>) => {
			if (msg.type === "PresenceSubscribe") {
				return Promise.resolve({
					type: "ok",
					id: 0,
					subId: 100,
					users: [
						{
							userId: packDocId("user_self"),
							data: conn.schema.decodePresenceUserValue([[2, "active"]]),
							joinedAt: 1000,
						},
						{
							userId: packDocId("user_other"),
							data: conn.schema.decodePresenceUserValue([[2, "active"]]),
							joinedAt: 2000,
						},
					],
				} as OkResponse);
			}
			return Promise.resolve({ type: "ok", id: 0 } as OkResponse);
		};

		const batches: PresenceChangeBatch[] = [];
		presence.subscribeChanges((batch) => {
			batches.push(batch);
		});
		await new Promise((resolve) => setTimeout(resolve, 10));

		expect(batches.length).toBe(1);
		expect(batches[0].type).toBe("snapshot");
		if (batches[0].type === "snapshot") {
			expect(batches[0].users.map((u) => u.userId)).toEqual([
				conn.schema.decodePresenceUserId(packDocId("user_other")),
			]);
		}

		// Self-only broadcast does not fire delta callbacks
		conn.fireBroadcast({
			type: "PresenceBroadcast",
			subId: 100,
			users: [
				{
					userId: packDocId("user_self"),
					event: "update",
					data: conn.schema.decodePresenceUserValue([[2, "idle"]]),
				},
			],
		} as PresenceBroadcast);
		expect(batches.length).toBe(1);

		// Mixed broadcast includes only other user's changes
		conn.fireBroadcast({
			type: "PresenceBroadcast",
			subId: 100,
			users: [
				{
					userId: packDocId("user_self"),
					event: "update",
					data: conn.schema.decodePresenceUserValue([[2, "away"]]),
				},
				{
					userId: packDocId("user_other"),
					event: "update",
					data: conn.schema.decodePresenceUserValue([[2, "idle"]]),
				},
			],
		} as PresenceBroadcast);
		expect(batches.length).toBe(2);
		expect(batches[1].type).toBe("changes");
		if (batches[1].type === "changes") {
			expect(batches[1].changes.length).toBe(1);
			expect(batches[1].changes[0].type).toBe("update");
			if (batches[1].changes[0].type === "update") {
				expect(batches[1].changes[0].entry.userId).toBe(
					conn.schema.decodePresenceUserId(packDocId("user_other")),
				);
			}
		}
	});

	test("delta-only subscription does not invoke getAll() on broadcast", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);

		conn.dispatch = (msg: Record<string, unknown>) => {
			if (msg.type === "PresenceSubscribe") {
				return Promise.resolve({
					type: "ok",
					id: 0,
					subId: 100,
					users: [],
				} as OkResponse);
			}
			return Promise.resolve({ type: "ok", id: 0 } as OkResponse);
		};

		presence.subscribeChanges(() => {});
		await new Promise((resolve) => setTimeout(resolve, 10));

		let getAllCalled = 0;
		const originalGetAll = presence.getAll.bind(presence);
		presence.getAll = (...args) => {
			getAllCalled++;
			return originalGetAll(...args);
		};

		conn.fireBroadcast({
			type: "PresenceBroadcast",
			subId: 100,
			users: [
				{
					userId: packDocId("user_1"),
					event: "join",
					data: conn.schema.decodePresenceUserValue([[2, "active"]]),
					joinedAt: 1234,
				},
			],
		} as PresenceBroadcast);

		expect(getAllCalled).toBe(0);
	});

	test("snapshot and delta listeners share one server subscription and lifecycle", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);

		conn.dispatch = (msg: Record<string, unknown>) => {
			conn.dispatched.push(msg);
			if (msg.type === "PresenceSubscribe") {
				return Promise.resolve({
					type: "ok",
					id: 0,
					subId: 100,
					users: [
						{
							userId: packDocId("user_1"),
							data: conn.schema.decodePresenceUserValue([[2, "active"]]),
							joinedAt: 1000,
						},
					],
				} as OkResponse);
			}
			return Promise.resolve({ type: "ok", id: 0 } as OkResponse);
		};

		const unsubSnapshot = presence.subscribe(() => {});
		const unsubDelta = presence.subscribeChanges(() => {});
		await new Promise((resolve) => setTimeout(resolve, 10));

		expect(
			conn.dispatched.filter((m) => m.type === "PresenceSubscribe").length,
		).toBe(1);

		// Remove snapshot listener: delta listener keeps server subscription alive
		unsubSnapshot();
		expect(
			conn.dispatched.filter((m) => m.type === "PresenceUnsubscribe").length,
		).toBe(0);
		expect(presence.getAll().length).toBe(1);

		// Remove delta listener: now no subscribers remain, so unsubscribe and clear cache
		unsubDelta();
		expect(
			conn.dispatched.filter((m) => m.type === "PresenceUnsubscribe").length,
		).toBe(1);
		expect(presence.getAll().length).toBe(0);
	});

	test("delta-only listener survives invalidate and receives replacement snapshot on replay", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);

		conn.dispatch = (msg: Record<string, unknown>) => {
			if (msg.type === "PresenceSubscribe") {
				return Promise.resolve({
					type: "ok",
					id: 0,
					subId: 100,
					users: [
						{
							userId: packDocId("user_1"),
							data: conn.schema.decodePresenceUserValue([[2, "active"]]),
							joinedAt: 1000,
						},
					],
				} as OkResponse);
			}
			return Promise.resolve({ type: "ok", id: 0 } as OkResponse);
		};

		const batches: PresenceChangeBatch[] = [];
		presence.subscribeChanges((batch) => {
			batches.push(batch);
		});
		await new Promise((resolve) => setTimeout(resolve, 10));
		expect(batches.length).toBe(1);
		expect(batches[0].type).toBe("snapshot");

		presence.invalidate();
		expect(presence.getAll().length).toBe(0);

		conn.dispatch = (msg: Record<string, unknown>) => {
			if (msg.type === "PresenceSubscribe") {
				return Promise.resolve({
					type: "ok",
					id: 0,
					subId: 200,
					users: [
						{
							userId: packDocId("user_2"),
							data: conn.schema.decodePresenceUserValue([[2, "online"]]),
							joinedAt: 2000,
						},
					],
				} as OkResponse);
			}
			return Promise.resolve({ type: "ok", id: 0 } as OkResponse);
		};

		presence.replaySubscriptions();
		await new Promise((resolve) => setTimeout(resolve, 10));

		expect(batches.length).toBe(2);
		expect(batches[1].type).toBe("snapshot");
		if (batches[1].type === "snapshot") {
			expect(batches[1].users.length).toBe(1);
			expect(batches[1].users[0].userId).toBe(
				conn.schema.decodePresenceUserId(packDocId("user_2")),
			);
		}
	});

	test("stale subscribe promise does not notify or overwrite delta-only listener after invalidate", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);

		let resolveStale: (value: OkResponse) => void = () => {};
		const stalePromise = new Promise<OkResponse>((resolve) => {
			resolveStale = resolve;
		});

		let isFirstSubscribe = true;
		conn.dispatch = (msg: Record<string, unknown>) => {
			if (msg.type === "PresenceSubscribe") {
				if (isFirstSubscribe) {
					isFirstSubscribe = false;
					return stalePromise;
				}
				return Promise.resolve({
					type: "ok",
					id: 0,
					subId: 200,
					users: [
						{
							userId: packDocId("user_2"),
							data: conn.schema.decodePresenceUserValue([[2, "new_status"]]),
							joinedAt: 5678,
						},
					],
				} as OkResponse);
			}
			return Promise.resolve({ type: "ok", id: 0 } as OkResponse);
		};

		const batches: PresenceChangeBatch[] = [];
		presence.subscribeChanges((batch) => {
			batches.push(batch);
		});

		presence.invalidate();
		presence.replaySubscriptions();
		await new Promise((resolve) => setTimeout(resolve, 10));

		expect(batches.length).toBe(1);
		expect(batches[0].type).toBe("snapshot");
		if (batches[0].type === "snapshot") {
			expect(batches[0].users[0].userId).toBe(
				conn.schema.decodePresenceUserId(packDocId("user_2")),
			);
		}

		resolveStale({
			type: "ok",
			id: 0,
			subId: 100,
			users: [
				{
					userId: packDocId("user_1"),
					data: conn.schema.decodePresenceUserValue([[2, "stale_status"]]),
					joinedAt: 1234,
				},
			],
		} as OkResponse);
		await new Promise((resolve) => setTimeout(resolve, 10));

		// Still only 1 snapshot batch received, cache unchanged
		expect(batches.length).toBe(1);
		const staleUserId = conn.schema.decodePresenceUserId(packDocId("user_1"));
		expect(presence.get(staleUserId)).toBeUndefined();
	});
});

describe("SchemaDictionary presence encode/decode", () => {
	test("encodePresenceUserValue flattens and indexes nested data", async () => {
		const schema = new SchemaDictionary();
		await setupSchema(schema);

		const encoded = schema.encodePresenceUserValue({
			cursor: { x: 100, y: 200 },
			status: "active",
		});

		expect(encoded).toEqual([
			[0, 100],
			[1, 200],
			[2, "active"],
		]);
	});

	test("decodePresenceUserValue unindexes and unflattens wire data", async () => {
		const schema = new SchemaDictionary();
		await setupSchema(schema);

		const decoded = schema.decodePresenceUserValue([
			[0, 100],
			[1, 200],
			[2, "active"],
		]);

		expect(decoded).toEqual({
			cursor: { x: 100, y: 200 },
			status: "active",
		});
	});

	test("encodePresenceSharedValue flattens and indexes nested data", async () => {
		const schema = new SchemaDictionary();
		await setupSchema(schema);

		const encoded = schema.encodePresenceSharedValue({
			slide: 5,
			playing: true,
		});

		expect(encoded).toEqual([
			[0, 5],
			[1, true],
		]);
	});

	test("decodePresenceSharedValue unindexes and unflattens wire data", async () => {
		const schema = new SchemaDictionary();
		await setupSchema(schema);

		const decoded = schema.decodePresenceSharedValue([
			[0, 5],
			[1, true],
		]);

		expect(decoded).toEqual({ slide: 5, playing: true });
	});

	test("decodePresenceUserId converts bin16 to UUID string", async () => {
		const schema = new SchemaDictionary();
		await setupSchema(schema);

		const bin = packDocId("019c1e50-7d11-7abc-9def-0123456789ab");
		const uuid = schema.decodePresenceUserId(bin);

		expect(uuid).toBe("019c1e50-7d11-7abc-9def-0123456789ab");
	});

	test("encodePresenceUserValue throws on unknown field", async () => {
		const schema = new SchemaDictionary();
		await setupSchema(schema);

		expect(() => schema.encodePresenceUserValue({ unknown: "field" })).toThrow(
			"unknown presence user field",
		);
	});

	test("hasPresenceUserFields returns true when fields are defined", async () => {
		const schema = new SchemaDictionary();
		await setupSchema(schema);
		expect(schema.hasPresenceUserFields()).toBe(true);
	});

	test("hasPresenceUserFields returns false when no fields defined", async () => {
		const schema = new SchemaDictionary();
		await schema.processSchemaSync({
			tables: ["users"],
			fields: [["id"]],
			fieldFlags: [[3]],
		});
		expect(schema.hasPresenceUserFields()).toBe(false);
	});

	test("decodePresenceUserValue handles null-with-nested-key conflict without crashing", async () => {
		const schema = new SchemaDictionary();
		await schema.processSchemaSync({
			tables: ["users"],
			fields: [["id", "name"]],
			fieldFlags: [[3, 0]],
			presenceUserFields: ["cursor", "cursor__x", "cursor__y", "status"],
		});

		// Wire data that maps to flat keys "cursor" (null) and "cursor__x" (100).
		// Without the null check in path.ts's setDeepProperty, typeof null === "object"
		// bypasses the initialization block and throws TypeError.
		expect(() =>
			schema.decodePresenceUserValue([
				[0, null],
				[1, 100],
				[2, 200],
				[3, "active"],
			]),
		).not.toThrow();
	});
});
