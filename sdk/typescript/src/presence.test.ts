import { describe, expect, test } from "bun:test";
import { PresenceImpl } from "./presence.js";
import { SchemaDictionary } from "./schema_dictionary.js";
import type {
	OkResponse,
	PresenceBroadcast,
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
							userId: new Uint8Array(16).fill(1),
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
							userId: new Uint8Array(16).fill(1),
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

		const userId = conn.schema.decodePresenceUserId(new Uint8Array(16).fill(1));
		const entry = presence.get(userId);
		expect(entry).toBeDefined();
		expect(entry?.data.status).toBe("active");
	});

	test("getAll() excludes self by default", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schema);
		const presence = new PresenceImpl(conn);
		presence.setLocalUserId(
			conn.schema.decodePresenceUserId(new Uint8Array(16).fill(1)),
		);

		conn.dispatch = (msg: Record<string, unknown>) => {
			if (msg.type === "PresenceSubscribe") {
				return Promise.resolve({
					type: "ok",
					id: 0,
					subId: 100,
					users: [
						{
							userId: new Uint8Array(16).fill(1),
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
					userId: new Uint8Array(16).fill(2),
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
		const userId = conn.schema.decodePresenceUserId(new Uint8Array(16).fill(2));
		const entry = presence.get(userId);
		expect(entry?.data).toEqual({ cursor: { x: 50, y: 75 } });
	});

	test("PresenceBroadcast leave removes user from cache", async () => {
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
							userId: new Uint8Array(16).fill(3),
							data: conn.schema.decodePresenceUserValue([[2, "active"]]),
							joinedAt: 1111,
						},
					],
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
					userId: new Uint8Array(16).fill(3),
					event: "leave",
				},
			],
		} as PresenceBroadcast);

		const userId = conn.schema.decodePresenceUserId(new Uint8Array(16).fill(3));
		expect(presence.get(userId)).toBeUndefined();
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
							userId: new Uint8Array(16).fill(1),
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
							userId: new Uint8Array(16).fill(2),
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
					userId: new Uint8Array(16).fill(1),
					data: conn.schema.decodePresenceUserValue([[2, "stale_status"]]),
					joinedAt: 1234,
				},
			],
		} as OkResponse);
		await new Promise((resolve) => setTimeout(resolve, 10));

		// Cache should NOT have stale data — still has the new namespace data
		expect(presence.getAll().length).toBe(1);
		const newUserId = conn.schema.decodePresenceUserId(
			new Uint8Array(16).fill(2),
		);
		expect(presence.get(newUserId)).toBeDefined();
		const staleUserId = conn.schema.decodePresenceUserId(
			new Uint8Array(16).fill(1),
		);
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

		const bin = new Uint8Array([
			0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67,
			0x89, 0xab, 0xcd, 0xef,
		]);
		const uuid = schema.decodePresenceUserId(bin);

		expect(uuid).toBe("01234567-89ab-cdef-0123-456789abcdef");
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
