import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { decode } from "@msgpack/msgpack";
import { ConnectionManager } from "./connection";
import { WireMessageType } from "./connection_wire";
import { packDocId } from "./doc_id";
import {
	connectManager,
	encodeToBuffer,
	installMockFetchTicket,
	MockWebSocket,
	makeManager,
	restoreFetch,
	TEST_USER_ID,
} from "./test-helpers";

beforeEach(() => {
	installMockFetchTicket();
});

afterEach(() => {
	restoreFetch();
});

function sentType(bytes: Uint8Array): number {
	return (decode(bytes) as { type: number }).type;
}

async function useCanonicalDeltaSchema(
	manager: ConnectionManager,
): Promise<void> {
	await manager.schemaDictionary.processSchemaSync({
		version: "1.0.0",
		tables: ["users"],
		fields: [["id", "name"]],
		fieldFlags: [[0b10, 0]],
	});
}

describe("ConnectionManager", () => {
	describe("connect()", () => {
		test("sets binaryType to arraybuffer on WebSocket creation", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);
			expect(mockWs.binaryType).toBe("arraybuffer");
		});

		test("resolves when WebSocket opens", async () => {
			const { manager, mockWs } = makeManager();
			await expect(connectManager(manager, mockWs)).resolves.toBeUndefined();
		});

		test("emits 'connected' lifecycle event on open", async () => {
			const { manager, mockWs } = makeManager();
			const events: string[] = [];
			manager.on("connected", () => events.push("connected"));
			await connectManager(manager, mockWs);
			expect(events).toContain("connected");
		});

		test("records the internal user id before connected", async () => {
			const { manager, mockWs } = makeManager();
			const seen: Array<string | null> = [];
			manager.on("connected", () => seen.push(manager.userId));

			await connectManager(manager, mockWs);

			expect(seen).toEqual([TEST_USER_ID]);
		});

		test("clears the user id on close and until the next scope ack", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);
			expect(manager.userId).toBe(TEST_USER_ID);

			mockWs.triggerClose(1006, "gone");
			expect(manager.userId).toBeNull();

			const reconnected = manager.connect();
			await new Promise((r) => setTimeout(r, 0));
			mockWs.triggerOpen();
			expect(manager.userId).toBeNull();

			const storeAck = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
				id: number;
				type: number;
			};
			expect(storeAck.type).toBe(WireMessageType.StoreSetNamespace);
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "ok",
					id: storeAck.id,
					userId: packDocId(TEST_USER_ID),
				}),
			);
			await reconnected;
			expect(manager.userId).toBe(TEST_USER_ID);
		});

		test("rejects a presence namespace response without a binary user id", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const presence = manager.dispatch({ type: "PresenceSet", data: {} });
			mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: 2 }));

			await expect(presence).rejects.toThrow(
				"PresenceSetNamespace response missing binary userId",
			);
		});

		test("rejects a store namespace response without a binary user id", async () => {
			const { manager, mockWs } = makeManager();
			const connected = manager.connect();
			await new Promise((resolve) => setTimeout(resolve, 0));
			mockWs.triggerOpen();
			mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: 1 }));

			await expect(connected).rejects.toThrow(
				"StoreSetNamespace response missing binary userId",
			);
			expect(manager.userId).toBeNull();
		});

		test("connects with the store scope alone, which provides the user id", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			expect(manager.userId).toBe(TEST_USER_ID);
			expect(mockWs.sentMessages.map((bytes) => sentType(bytes))).toEqual([
				WireMessageType.StoreSetNamespace,
			]);
		});

		test("rejects a presence namespace response with a malformed user id", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const presence = manager.dispatch({ type: "PresenceSet", data: {} });
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "ok",
					id: 2,
					userId: new Uint8Array(15),
				}),
			);

			await expect(presence).rejects.toThrow("invalid userId binary length 15");
		});

		test("emits 'statusChange' with 'connected' on open", async () => {
			const { manager, mockWs } = makeManager();
			const statuses: string[] = [];
			manager.on("statusChange", (s: unknown) => statuses.push(s as string));
			await connectManager(manager, mockWs);
			expect(statuses).toContain("connected");
		});

		test("rejects when WebSocket errors", async () => {
			const { manager, mockWs } = makeManager();
			const connectPromise = manager.connect();
			await new Promise((r) => setTimeout(r, 0));
			mockWs.triggerError();
			await expect(connectPromise).rejects.toMatchObject({
				code: "CONNECTION_FAILED",
			});
		});
	});

	describe("presence scope", () => {
		const tick = () => new Promise((r) => setTimeout(r, 0));
		const ack = (mockWs: MockWebSocket, id: number) =>
			mockWs.triggerMessage(
				encodeToBuffer({ type: "ok", id, userId: packDocId(TEST_USER_ID) }),
			);

		test("the first presence message requests the scope once, then everything queued on it", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const set = manager.dispatch({ type: "PresenceSet", data: {} });
			const subscribe = manager.dispatch({ type: "PresenceSubscribe" });
			expect(mockWs.sentMessages.map(sentType)).toEqual([
				WireMessageType.StoreSetNamespace,
				WireMessageType.PresenceSetNamespace,
			]);

			ack(mockWs, 2);
			await tick();
			expect(mockWs.sentMessages.slice(2).map(sentType)).toEqual([
				WireMessageType.PresenceSet,
				WireMessageType.PresenceSubscribe,
			]);
			mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: 3 }));
			mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: 4 }));
			await Promise.all([set, subscribe]);

			await Promise.all([
				manager.dispatch({ type: "PresenceRemove" }),
				Promise.resolve().then(() =>
					mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: 5 })),
				),
			]);
			expect(sentType(mockWs.sentMessages[4])).toBe(
				WireMessageType.PresenceRemove,
			);
		});

		test("store messages never request the presence scope", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const query = manager.dispatch({ type: "StoreQuery", table_index: "a" });
			mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: 2, value: [] }));
			await query;

			expect(mockWs.sentMessages.map(sentType)).toEqual([
				WireMessageType.StoreSetNamespace,
				WireMessageType.StoreQuery,
			]);
		});

		test("a denied presence scope fails the presence message, not the session", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const denied = manager.dispatch({ type: "PresenceSet", data: {} });
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "error",
					id: 2,
					code: "NAMESPACE_UNAUTHORIZED",
					message: "No access to namespace",
				}),
			);
			await expect(denied).rejects.toMatchObject({
				code: "NAMESPACE_UNAUTHORIZED",
			});
			expect(manager.status).toBe("connected");

			// The next presence message asks again.
			const retried = manager.dispatch({ type: "PresenceSet", data: {} });
			expect(sentType(mockWs.sentMessages.at(-1) as Uint8Array)).toBe(
				WireMessageType.PresenceSetNamespace,
			);
			retried.catch(() => {});
			manager.disconnect();
		});

		test("only presence-scoped actions request the presence scope", async () => {
			const { manager, mockWs } = makeManager();
			await manager.schemaDictionary.processSchemaSync({
				version: "1.0.0",
				tables: [],
				fields: [],
				fieldFlags: [],
				actions: ["checkout", "ping"],
				actionParams: [[], []],
				actionReturns: [[], []],
				actionFlags: [0b00, 0b10],
			});
			await connectManager(manager, mockWs);

			manager
				.dispatchNoRetry({ type: "ActionCall", action_id: "checkout" })
				.catch(() => {});
			expect(sentType(mockWs.sentMessages.at(-1) as Uint8Array)).toBe(
				WireMessageType.ActionCall,
			);

			manager
				.dispatchNoRetry({ type: "ActionCall", action_id: "ping" })
				.catch(() => {});
			expect(sentType(mockWs.sentMessages.at(-1) as Uint8Array)).toBe(
				WireMessageType.PresenceSetNamespace,
			);
			ack(mockWs, 3);
			await tick();
			expect(sentType(mockWs.sentMessages.at(-1) as Uint8Array)).toBe(
				WireMessageType.ActionCall,
			);
			manager.disconnect();
		});

		test("a reconnect starts without the presence scope", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);
			const first = manager.dispatch({ type: "PresenceSet", data: {} });
			ack(mockWs, 2);
			await tick();
			mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: 3 }));
			await first;

			mockWs.triggerClose(1006, "gone");
			const reconnected = manager.connect();
			await tick();
			mockWs.triggerOpen();
			ack(mockWs, 4);
			await reconnected;
			expect(sentType(mockWs.sentMessages.at(-1) as Uint8Array)).toBe(
				WireMessageType.StoreSetNamespace,
			);

			const again = manager.dispatch({ type: "PresenceSet", data: {} });
			expect(sentType(mockWs.sentMessages.at(-1) as Uint8Array)).toBe(
				WireMessageType.PresenceSetNamespace,
			);
			again.catch(() => {});
			manager.disconnect();
		});

		test("a queued subscription is rejected when its scope is replaced", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);
			const subscribe = manager.dispatch({ type: "PresenceSubscribe" });
			const outcome = subscribe.then(
				() => null,
				(err: { code?: string }) => err.code,
			);
			const switched = manager.setPresenceNamespace("other");
			expect(mockWs.sentMessages.map(sentType)).toEqual([
				WireMessageType.StoreSetNamespace,
				WireMessageType.PresenceSetNamespace,
				WireMessageType.PresenceSetNamespace,
			]);
			const [initial, replacement] = mockWs.sentMessages
				.slice(1)
				.map((bytes) => decode(bytes) as { id: number });

			ack(mockWs, initial.id);
			await tick();
			expect(await outcome).toBe("REQUEST_SUPERSEDED");
			expect(mockWs.sentMessages.map(sentType)).toEqual([
				WireMessageType.StoreSetNamespace,
				WireMessageType.PresenceSetNamespace,
				WireMessageType.PresenceSetNamespace,
			]);

			ack(mockWs, replacement.id);
			await switched;
			expect(mockWs.sentMessages.map(sentType)).toEqual([
				WireMessageType.StoreSetNamespace,
				WireMessageType.PresenceSetNamespace,
				WireMessageType.PresenceSetNamespace,
			]);
		});

		test("a same-namespace call joins a pending scope request", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);
			const first = manager.setPresenceNamespace("public");
			const second = manager.setPresenceNamespace("public");
			expect(mockWs.sentMessages.map(sentType)).toEqual([
				WireMessageType.StoreSetNamespace,
				WireMessageType.PresenceSetNamespace,
			]);

			ack(mockWs, 2);
			await Promise.all([first, second]);
			await manager.setPresenceNamespace("public");
			expect(mockWs.sentMessages).toHaveLength(2);
		});

		test("a late superseded setup cannot overwrite the latest scope", async () => {
			const { manager, mockWs } = makeManager({
				presenceNamespace: "initial",
			});
			await connectManager(manager, mockWs);
			const first = manager.setPresenceNamespace("first");
			const firstOutcome = first.then(
				() => null,
				(err: { code?: string }) => err.code,
			);
			const second = manager.setPresenceNamespace("second");
			const [firstScope, secondScope] = mockWs.sentMessages
				.slice(1)
				.map((bytes) => decode(bytes) as { id: number });

			mockWs.triggerMessage(
				encodeToBuffer({
					type: "ok",
					id: firstScope.id,
					userId: packDocId("019c1e50-7d11-7000-8000-000000000002"),
				}),
			);
			await tick();
			expect(await firstOutcome).toBe("REQUEST_SUPERSEDED");
			expect(manager.getPresenceNamespace()).toBe("initial");
			expect(manager.userId).toBe(TEST_USER_ID);

			ack(mockWs, secondScope.id);
			await second;
			expect(manager.getPresenceNamespace()).toBe("second");
			expect(manager.userId).toBe(TEST_USER_ID);
		});

		test("a rejected presence switch keeps the previous namespace usable", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);
			const initial = manager.setPresenceNamespace("public");
			ack(mockWs, 2);
			await initial;

			const rejected = manager.setPresenceNamespace("other");
			const rejectedScope = decode(
				mockWs.sentMessages.at(-1) as Uint8Array,
			) as {
				id: number;
			};
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "error",
					id: rejectedScope.id,
					code: "NAMESPACE_SWITCH_REJECTED",
					message: "Namespace switching is not allowed",
				}),
			);
			await expect(rejected).rejects.toMatchObject({
				code: "NAMESPACE_SWITCH_REJECTED",
			});
			expect(manager.getPresenceNamespace()).toBe("public");

			const retried = manager.dispatch({ type: "PresenceSet", data: {} });
			const presence = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
				id: number;
			};
			expect(sentType(mockWs.sentMessages.at(-1) as Uint8Array)).toBe(
				WireMessageType.PresenceSet,
			);
			mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: presence.id }));
			await retried;
			expect(manager.getPresenceNamespace()).toBe("public");
		});

		test("a rejected switch restores the confirmed scope, not a pending one", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);
			const confirmed = manager.setPresenceNamespace("public");
			ack(mockWs, 2);
			await confirmed;

			const pending = manager.setPresenceNamespace("other");
			pending.catch(() => {});
			const rejected = manager.setPresenceNamespace("third");
			const rejectedScope = decode(
				mockWs.sentMessages.at(-1) as Uint8Array,
			) as { id: number };
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "error",
					id: rejectedScope.id,
					code: "NAMESPACE_SWITCH_REJECTED",
					message: "Namespace switching is not allowed",
				}),
			);
			await expect(rejected).rejects.toMatchObject({
				code: "NAMESPACE_SWITCH_REJECTED",
			});
			expect(manager.getPresenceNamespace()).toBe("public");

			const presence = manager.dispatch({ type: "PresenceSet", data: {} });
			const sent = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
				id: number;
			};
			expect(sentType(mockWs.sentMessages.at(-1) as Uint8Array)).toBe(
				WireMessageType.PresenceSet,
			);
			mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: sent.id }));
			await presence;
			manager.disconnect();
		});

		test("a superseded setup is not retried after the latest request", async () => {
			const { manager, mockWs } = makeManager({
				reconnectDelay: 10,
			});
			await connectManager(manager, mockWs);
			const first = manager.setPresenceNamespace("first");
			const firstOutcome = first.then(
				() => null,
				(err: { code?: string }) => err.code,
			);
			const firstScope = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
				id: number;
			};
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "error",
					id: firstScope.id,
					code: "RATE_LIMITED",
					message: "Too many requests",
					retryAfter: 100,
				}),
			);
			await tick();

			const second = manager.setPresenceNamespace("second");
			const secondOutcome = second.then(
				() => null,
				(err: { code?: string }) => err.code,
			);
			const secondScope = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
				id: number;
			};
			const third = manager.setPresenceNamespace("first");
			const thirdScope = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
				id: number;
			};
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "error",
					id: secondScope.id,
					code: "RATE_LIMITED",
					message: "Too many requests",
				}),
			);
			await tick();

			await new Promise((r) => setTimeout(r, 150));
			expect(mockWs.sentMessages.map(sentType)).toEqual([
				WireMessageType.StoreSetNamespace,
				WireMessageType.PresenceSetNamespace,
				WireMessageType.PresenceSetNamespace,
				WireMessageType.PresenceSetNamespace,
			]);

			ack(mockWs, thirdScope.id);
			await third;
			expect(await firstOutcome).toBe("REQUEST_SUPERSEDED");
			expect(await secondOutcome).toBe("REQUEST_SUPERSEDED");
			expect(manager.getPresenceNamespace()).toBe("first");
		});

		test("a retry on a replacement socket requests the presence scope again", async () => {
			const { manager, mockWs } = makeManager({
				reconnect: false,
				reconnectDelay: 10,
			});
			await connectManager(manager, mockWs);
			const presence = manager.dispatch({ type: "PresenceSet", data: {} });
			const scope = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
				id: number;
			};
			expect(sentType(mockWs.sentMessages.at(-1) as Uint8Array)).toBe(
				WireMessageType.PresenceSetNamespace,
			);
			ack(mockWs, scope.id);
			await tick();
			const firstAttempt = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
				id: number;
			};
			expect(sentType(mockWs.sentMessages.at(-1) as Uint8Array)).toBe(
				WireMessageType.PresenceSet,
			);

			mockWs.triggerMessage(
				encodeToBuffer({
					type: "error",
					id: firstAttempt.id,
					code: "RATE_LIMITED",
					message: "Too many requests",
					retryAfter: 100,
				}),
			);
			await tick();
			mockWs.triggerClose(1006, "gone");
			const reconnected = manager.connect();
			await tick();
			mockWs.triggerOpen();
			const store = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
				id: number;
			};
			expect(sentType(mockWs.sentMessages.at(-1) as Uint8Array)).toBe(
				WireMessageType.StoreSetNamespace,
			);
			ack(mockWs, store.id);
			await reconnected;

			await new Promise((r) => setTimeout(r, 150));
			const setup = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
				id: number;
			};
			expect(sentType(mockWs.sentMessages.at(-1) as Uint8Array)).toBe(
				WireMessageType.PresenceSetNamespace,
			);
			ack(mockWs, setup.id);
			await tick();
			const retried = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
				id: number;
			};
			expect(sentType(mockWs.sentMessages.at(-1) as Uint8Array)).toBe(
				WireMessageType.PresenceSet,
			);
			mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: retried.id }));
			await presence;
			manager.disconnect();
		});

		test("a presence write retry is rejected after a namespace switch", async () => {
			const { manager, mockWs } = makeManager({ reconnectDelay: 10 });
			await connectManager(manager, mockWs);
			const write = manager.dispatch({ type: "PresenceSet", data: {} });
			const outcome = write.then(
				() => null,
				(err: { code?: string }) => err.code,
			);
			const scope = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
				id: number;
			};
			ack(mockWs, scope.id);
			await tick();
			const attempt = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
				id: number;
			};
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "error",
					id: attempt.id,
					code: "RATE_LIMITED",
					message: "Too many requests",
					retryAfter: 100,
				}),
			);
			await tick();

			const switched = manager.setPresenceNamespace("other");
			const replacement = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
				id: number;
			};
			ack(mockWs, replacement.id);
			await switched;
			await new Promise((r) => setTimeout(r, 150));

			expect(await outcome).toBe("REQUEST_SUPERSEDED");
			expect(mockWs.sentMessages.map(sentType)).toEqual([
				WireMessageType.StoreSetNamespace,
				WireMessageType.PresenceSetNamespace,
				WireMessageType.PresenceSet,
				WireMessageType.PresenceSetNamespace,
			]);
		});

		test("a same-namespace call after disconnect fails with CONNECTION_FAILED", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);
			const ready = manager.setPresenceNamespace("public");
			ack(mockWs, 2);
			await ready;
			manager.disconnect();
			await expect(
				manager.setPresenceNamespace("public"),
			).rejects.toMatchObject({ code: "CONNECTION_FAILED" });
		});

		test("numeric presence action registrations request the presence scope", async () => {
			const { manager, mockWs } = makeManager();
			await manager.schemaDictionary.processSchemaSync({
				version: "1.0.0",
				tables: [],
				fields: [],
				fieldFlags: [],
				actions: ["checkout", "ping"],
				actionParams: [[], []],
				actionReturns: [[], []],
				actionFlags: [0b00, 0b10],
			});
			await connectManager(manager, mockWs);
			manager
				.dispatchNoRetry({ type: "ActionRegister", action_ids: [0] })
				.catch(() => {});
			expect(sentType(mockWs.sentMessages.at(-1) as Uint8Array)).toBe(
				WireMessageType.ActionRegister,
			);
			manager
				.dispatchNoRetry({ type: "ActionRegister", action_ids: [1] })
				.catch(() => {});
			expect(sentType(mockWs.sentMessages.at(-1) as Uint8Array)).toBe(
				WireMessageType.PresenceSetNamespace,
			);
			ack(mockWs, 3);
			await tick();
			expect(sentType(mockWs.sentMessages.at(-1) as Uint8Array)).toBe(
				WireMessageType.ActionRegister,
			);
			manager.disconnect();
		});
	});

	describe("liveness", () => {
		test("enables liveness by default and closes when a probe times out", async () => {
			const { manager, mockWs } = makeManager({
				liveness: { intervalMs: 1_000, timeoutMs: 300 },
			});
			await connectManager(manager, mockWs);

			const wait = (ms: number) =>
				new Promise((resolve) => setTimeout(resolve, ms));
			const seenPingIds = new Set<number>();
			const findPing = () =>
				mockWs.sentMessages
					.map((bytes) => decode(bytes))
					.find(
						(message): message is { type: number; id: number } =>
							message !== null &&
							typeof message === "object" &&
							"type" in message &&
							message.type === 0x02 &&
							"id" in message &&
							typeof message.id === "number" &&
							!seenPingIds.has(message.id),
					);
			const waitForPing = async () => {
				for (let attempt = 0; attempt < 200; attempt++) {
					const ping = findPing();
					if (ping) {
						seenPingIds.add(ping.id);
						return ping;
					}
					await wait(10);
				}
				throw new Error("Ping request was not sent");
			};
			const ping = await waitForPing();

			mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: ping.id }));
			await wait(20);
			expect(mockWs.readyState).toBe(MockWebSocket.OPEN);

			await waitForPing();
			await wait(350);
			expect(mockWs.readyState).toBe(MockWebSocket.CLOSED);
			manager.disconnect();
		});
	});

	describe("dispatch() — msg_id and PendingRequests", () => {
		test("assigns incrementing msg_ids starting at 1", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const p1 = manager.dispatch({
				type: "StoreSet",
				path: ["a", "b"],
				value: 1,
			});
			const p2 = manager.dispatch({
				type: "StoreSet",
				path: ["a", "c"],
				value: 2,
			});

			const msg1 = decode(mockWs.sentMessages[1]) as Record<string, unknown>;
			const msg2 = decode(mockWs.sentMessages[2]) as Record<string, unknown>;

			expect(msg1.id).toBe(2);
			expect(msg2.id).toBe(3);

			mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: 2 }));
			mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: 3 }));
			await p1;
			await p2;
		});

		test("resolves promise on type:ok response with matching id", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const p = manager.dispatch({
				type: "StoreSet",
				path: ["a", "b"],
				value: 1,
			});
			mockWs.triggerMessage(
				encodeToBuffer({ type: "ok", id: 2, value: [{ x: 1 }] }),
			);

			const result = await p;
			expect(result).toMatchObject({ type: "ok", id: 2 });
		});

		test("rejects promise on type:error response with matching id", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const p = manager.dispatch({
				type: "StoreSet",
				path: ["a", "b"],
				value: 1,
			});
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "error",
					id: 2,
					code: "PERMISSION_DENIED",
					message: "Not allowed",
				}),
			);

			await expect(p).rejects.toMatchObject({ code: "PERMISSION_DENIED" });
		});

		test("discards response with unknown id silently", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			expect(() =>
				mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: 999 })),
			).not.toThrow();
		});
	});

	describe("dispatchWrite()", () => {
		const write = { type: "StoreSet", path: ["a", "b"], value: 1 } as const;
		const wait = (ms: number) =>
			new Promise((resolve) => setTimeout(resolve, ms));
		const sentId = (mockWs: MockWebSocket, type: number): number | undefined =>
			mockWs.sentMessages
				.map((bytes) => decode(bytes) as { type: number; id: number })
				.find((message) => message.type === type)?.id;

		test("resolves on WriteCommitted with the request id", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const p = manager.dispatchWrite(write);
			mockWs.triggerMessage(encodeToBuffer({ type: "WriteCommitted", id: 2 }));

			await expect(p).resolves.toBeUndefined();
		});

		test("rejects on WriteError with phase and batchIndex", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const p = manager.dispatchWrite({
				type: "StoreBatch",
				ops: [["r", ["a", "b"]]],
			});
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "WriteError",
					id: 2,
					code: "UNIQUE_CONSTRAINT_VIOLATED",
					message: "duplicate",
					phase: "write",
					batchIndex: 0,
				}),
			);

			await expect(p).rejects.toMatchObject({
				code: "UNIQUE_CONSTRAINT_VIOLATED",
				retryable: false,
				details: { phase: "write", batchIndex: 0 },
			});
		});

		test("tags an accept-phase error with phase accept", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const p = manager.dispatchWrite(write);
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "error",
					id: 2,
					code: "PERMISSION_DENIED",
					message: "Not allowed",
				}),
			);

			await expect(p).rejects.toMatchObject({
				code: "PERMISSION_DENIED",
				details: { phase: "accept" },
			});
		});

		test("rejects with TIMEOUT when no outcome arrives", async () => {
			const { manager, mockWs } = makeManager({ writeTimeoutMs: 20 });
			await connectManager(manager, mockWs);

			await expect(manager.dispatchWrite(write)).rejects.toMatchObject({
				code: "TIMEOUT",
				category: "network",
				retryable: true,
				message:
					"Write outcome not received within 20 ms; the write may still commit",
			});
			// A late outcome for the timed-out id is ignored.
			mockWs.triggerMessage(encodeToBuffer({ type: "WriteCommitted", id: 2 }));
		});

		test("rejects writeTimeoutMs outside the timer range", () => {
			expect(() => makeManager({ writeTimeoutMs: 0 })).toThrow(RangeError);
		});

		test("socket close rejects pending writes", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const p = manager.dispatchWrite(write);
			mockWs.triggerClose(1006, "");

			await expect(p).rejects.toMatchObject({ code: "CONNECTION_FAILED" });
		});

		test("RATE_LIMITED is not retried", async () => {
			const { manager, mockWs } = makeManager({ reconnectDelay: 10 });
			await connectManager(manager, mockWs);

			const p = manager.dispatchWrite(write);
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "error",
					id: 2,
					code: "RATE_LIMITED",
					message: "Too many requests",
					retryAfter: 5,
				}),
			);

			await expect(p).rejects.toMatchObject({ code: "RATE_LIMITED" });
			await wait(20);
			expect(mockWs.sentMessages).toHaveLength(2);
		});

		test("WriteCommitted counts as a liveness response", async () => {
			const { manager, mockWs } = makeManager({
				liveness: { intervalMs: 1_000, timeoutMs: 300 },
			});
			await connectManager(manager, mockWs);

			const p = manager.dispatchWrite(write);
			const requestId = sentId(mockWs, WireMessageType.StoreSet);
			for (let i = 0; i < 200 && !sentId(mockWs, WireMessageType.Ping); i++) {
				await wait(10);
			}
			expect(sentId(mockWs, WireMessageType.Ping)).toBeDefined();

			mockWs.triggerMessage(
				encodeToBuffer({ type: "WriteCommitted", id: requestId }),
			);
			await p;
			await wait(350);
			expect(mockWs.readyState).toBe(MockWebSocket.OPEN);
			manager.disconnect();
		});
	});

	describe("StoreDelta routing", () => {
		test("routes StoreDelta to registered delta handler by subId", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);
			await useCanonicalDeltaSchema(manager);

			const received: unknown[] = [];
			manager.onDelta((delta) => received.push(delta));

			const delta = {
				type: "StoreDelta",
				subId: 42,
				ops: [{ op: "set", path: [0, "u1"], value: ["u1", "Alice"] }],
			};
			mockWs.triggerMessage(encodeToBuffer(delta));
			await (manager as unknown as { processingPromise: Promise<void> })
				.processingPromise;

			expect(received).toHaveLength(1);
			expect((received[0] as Record<string, unknown>).subId).toBe(42);
		});

		test("routes multiple deltas from one concatenated frame in order", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);
			await useCanonicalDeltaSchema(manager);

			const received: unknown[] = [];
			manager.onDelta((delta) => received.push(delta));

			const delta1 = encodeToBuffer({
				type: "StoreDelta",
				subId: 1,
				ops: [{ op: "set", path: [0, "u1"], value: ["u1", "Alice"] }],
			});
			const delta2 = encodeToBuffer({
				type: "StoreDelta",
				subId: 2,
				ops: [{ op: "set", path: [0, "u2"], value: ["u2", "Bob"] }],
			});
			const frame = new Uint8Array(delta1.byteLength + delta2.byteLength);
			frame.set(new Uint8Array(delta1), 0);
			frame.set(new Uint8Array(delta2), delta1.byteLength);

			mockWs.triggerMessage(
				frame.buffer.slice(
					frame.byteOffset,
					frame.byteOffset + frame.byteLength,
				) as ArrayBuffer,
			);
			await (manager as unknown as { processingPromise: Promise<void> })
				.processingPromise;

			expect(received).toHaveLength(2);
			expect((received[0] as { subId: number }).subId).toBe(1);
			expect((received[1] as { subId: number }).subId).toBe(2);
		});

		test("StoreDelta does not affect pendingQueue", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const p = manager.dispatch({
				type: "StoreSet",
				path: ["a", "b"],
				value: 1,
			});

			const delta = {
				type: "StoreDelta",
				subId: 99,
				ops: [{ op: "remove", path: [1, "u1"] }],
			};
			mockWs.triggerMessage(encodeToBuffer(delta));

			mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: 2 }));
			await expect(p).resolves.toMatchObject({ type: "ok", id: 2 });
		});
	});

	describe("SchemaSync race condition", () => {
		test("processes StoreDelta only after SchemaSync is fully ready", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);
			expect(manager.isSchemaReady()).toBe(false);

			const received: unknown[] = [];
			manager.onDelta((delta) => received.push(delta));

			const schema = {
				type: "SchemaSync",
				version: "1.0.0",
				tables: ["users"],
				fields: [["id", "name", "age"]],
				fieldFlags: [[0b10, 0b00, 0b00]],
			};
			mockWs.triggerMessage(encodeToBuffer(schema));

			const delta = {
				type: "StoreDelta",
				subId: 1,
				ops: [{ op: "set", path: [0, "u1"], value: ["u1", "Alice", null] }],
			};
			mockWs.triggerMessage(encodeToBuffer(delta));

			await (manager as unknown as { processingPromise: Promise<void> })
				.processingPromise;

			expect(manager.isSchemaReady()).toBe(true);
			expect(received).toHaveLength(1);
			expect(
				(received[0] as { ops: { path: string[] }[] }).ops[0].path,
			).toEqual(["users", "u1"]);
		});
	});

	describe("schema version", () => {
		test("exposes the server's version and reports changes with schemaChange", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);
			expect(manager.schemaVersion).toBe("1.0.0");

			const changes: unknown[] = [];
			manager.on("schemaChange", (detail) => changes.push(detail));
			const sync = (version: string) =>
				mockWs.triggerMessage(
					encodeToBuffer({
						type: "SchemaSync",
						version,
						tables: ["a", "users", "tasks"],
						fields: [
							["b", "c"],
							["name", "age"],
							["title", "meta"],
						],
						fieldFlags: [
							[0, 0],
							[0, 0],
							[0, 0],
						],
					}),
				);
			const processed = () =>
				(manager as unknown as { processingPromise: Promise<void> })
					.processingPromise;

			sync("1.0.0");
			await processed();
			expect(changes).toEqual([]);

			sync("2.0.0");
			await processed();
			expect(manager.schemaVersion).toBe("2.0.0");
			expect(changes).toEqual([{ previousVersion: "1.0.0", version: "2.0.0" }]);
		});
	});

	describe("lifecycle events", () => {
		test("emits 'disconnected' when WebSocket closes", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const events: string[] = [];
			manager.on("disconnected", () => events.push("disconnected"));
			mockWs.triggerClose();

			expect(events).toContain("disconnected");
		});

		test("emits 'error' on WebSocket error", async () => {
			const { manager, mockWs } = makeManager();
			const errors: unknown[] = [];
			manager.on("error", (e: unknown) => errors.push(e));

			const connectPromise = manager.connect();
			await new Promise((r) => setTimeout(r, 0));
			mockWs.triggerError();

			try {
				await connectPromise;
			} catch {}

			expect(errors).toHaveLength(1);
			expect((errors[0] as Record<string, unknown>).code).toBe(
				"CONNECTION_FAILED",
			);
		});

		test("rejects all pending requests when connection closes", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const p = manager.dispatch({
				type: "StoreSet",
				path: ["a", "b"],
				value: 1,
			});
			mockWs.triggerClose(1006, "Abnormal closure");

			await expect(p).rejects.toMatchObject({ code: "CONNECTION_FAILED" });
		});
	});

	describe("disconnect()", () => {
		test("closes the WebSocket and rejects pending requests", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const p = manager.dispatch({
				type: "StoreSet",
				path: ["a", "b"],
				value: 1,
			});
			manager.disconnect();

			await expect(p).rejects.toMatchObject({ code: "CONNECTION_FAILED" });
		});

		test("emits 'disconnected' event", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const events: string[] = [];
			manager.on("disconnected", () => events.push("disconnected"));
			manager.disconnect();

			expect(events).toContain("disconnected");
		});

		test("clears the user id", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			manager.disconnect();

			expect(manager.userId).toBeNull();
		});
	});

	describe("send()", () => {
		test("throws if WebSocket is not open", () => {
			const { manager } = makeManager();
			expect(() => manager.send(new Uint8Array([1, 2, 3]))).toThrow();
		});
	});

	describe("on() / off()", () => {
		test("off() removes a registered listener", async () => {
			const { manager, mockWs } = makeManager();
			const events: string[] = [];
			const handler = () => events.push("connected");
			manager.on("connected", handler);
			manager.off("connected", handler);

			await connectManager(manager, mockWs);

			expect(events).toHaveLength(0);
		});
	});

	describe("reconnection — exponential backoff", () => {
		test("emits 'reconnecting' on unexpected close when reconnect=true", async () => {
			const mockWs = new MockWebSocket();
			function wsFactory1() {
				return mockWs;
			}
			(globalThis as Record<string, unknown>).WebSocket = Object.assign(
				wsFactory1,
				{ OPEN: MockWebSocket.OPEN },
			);

			const manager = new ConnectionManager({
				url: "ws://localhost:3000",
				auth: { anonymous: true },
				reconnect: true,
				reconnectDelay: 50,
				maxReconnectDelay: 5000,
				liveness: { enabled: false },
			});

			const events: string[] = [];
			manager.on("reconnecting", () => events.push("reconnecting"));

			await connectManager(manager, mockWs);

			mockWs.triggerClose(1006, "Abnormal closure");

			await new Promise((r) => setTimeout(r, 10));
			expect(events).toContain("reconnecting");

			manager.disconnect();
		});

		test("rejects user dispatches while the namespace handshake is in flight", async () => {
			const { manager, mockWs } = makeManager({
				reconnect: true,
				reconnectDelay: 10,
			});
			const connected = manager.connect();
			await new Promise((r) => setTimeout(r, 0));
			mockWs.triggerOpen();
			// StoreSetNamespace has been sent; its ack has not arrived yet.
			expect(mockWs.sentMessages).toHaveLength(1);

			// A user dispatch must not hit the wire before the server session
			// exists — otherwise the server answers SESSION_NOT_READY.
			const user = manager.dispatch({
				type: "StoreSet",
				path: ["a"],
				value: 1,
			});
			await expect(user).rejects.toMatchObject({
				code: "CONNECTION_FAILED",
				retryable: true,
			});
			expect(mockWs.sentMessages).toHaveLength(1);

			// Complete the handshake.
			mockWs.triggerMessage(
				encodeToBuffer({ type: "ok", id: 1, userId: packDocId(TEST_USER_ID) }),
			);
			await connected;
			manager.disconnect();
		});

		test("keeps the reconnect loop alive when the namespace handshake fails", async () => {
			const { manager, mockWs } = makeManager({
				reconnect: true,
				reconnectDelay: 10,
			});
			const events: string[] = [];
			manager.on("reconnecting", () => events.push("reconnecting"));

			const connected = manager.connect();
			await new Promise((r) => setTimeout(r, 0));
			mockWs.triggerOpen();
			// StoreSetNamespace (id=1) is rejected with a retryable error — a
			// failed handshake must not terminate the reconnect loop.
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "error",
					id: 1,
					code: "SERVER_SHUTDOWN",
					message: "namespace setup failed",
				}),
			);

			await expect(connected).rejects.toThrow("namespace setup failed");
			await new Promise((r) => setTimeout(r, 20));
			expect(events).toContain("reconnecting");

			manager.disconnect();
		});

		test("does NOT reconnect when the handshake fails with a non-retryable error", async () => {
			const { manager, mockWs } = makeManager({
				reconnect: true,
				reconnectDelay: 10,
			});
			const events: string[] = [];
			manager.on("reconnecting", () => events.push("reconnecting"));

			const connected = manager.connect();
			await new Promise((r) => setTimeout(r, 0));
			mockWs.triggerOpen();
			// PERMISSION_DENIED derives authorization/retryable: false — the
			// client must stop instead of retrying a permanently denied
			// namespace forever.
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "error",
					id: 1,
					code: "PERMISSION_DENIED",
					message: "namespace denied",
				}),
			);

			await expect(connected).rejects.toThrow("namespace denied");
			await new Promise((r) => setTimeout(r, 20));
			expect(events).not.toContain("reconnecting");

			manager.disconnect();
		});

		test("does NOT reconnect when ticket acquisition fails non-retryably", async () => {
			installMockFetchTicket({
				status: 401,
				body: JSON.stringify({
					code: "AUTH_FAILED",
					message: "bad credentials",
				}),
			});

			const manager = new ConnectionManager({
				url: "ws://localhost:3000",
				auth: { anonymous: true },
				reconnect: true,
				reconnectDelay: 10,
				liveness: { enabled: false },
			});
			const events: string[] = [];
			manager.on("reconnecting", () => events.push("reconnecting"));

			await expect(manager.connect()).rejects.toMatchObject({
				code: "AUTH_FAILED",
				retryable: false,
			});
			await new Promise((r) => setTimeout(r, 20));
			expect(events).not.toContain("reconnecting");

			manager.disconnect();
		});

		test("classifies close codes and stops retrying non-retryable auth failures", async () => {
			const { manager, mockWs } = makeManager({ reconnect: true });
			await connectManager(manager, mockWs);

			const errors: unknown[] = [];
			let reconnecting = false;
			manager.on("error", (error) => errors.push(error));
			manager.on("reconnecting", () => (reconnecting = true));
			mockWs.triggerClose(4001, "Invalid credentials");

			expect(reconnecting).toBe(false);
			expect(errors[0]).toMatchObject({
				code: "AUTH_FAILED",
				retryable: false,
			});
		});

		test("uses ServerDisconnect when the transport close code is unavailable", async () => {
			const { manager, mockWs } = makeManager({ reconnect: false });
			await connectManager(manager, mockWs);

			const errors: unknown[] = [];
			manager.on("error", (error) => errors.push(error));
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "ServerDisconnect",
					code: "AUTH_FAILED",
					message: "Refresh was rejected",
				}),
			);
			await new Promise((resolve) => setTimeout(resolve, 0));
			mockWs.triggerClose(1006, "");

			expect(errors[0]).toMatchObject({
				code: "AUTH_FAILED",
				message: "Refresh was rejected",
				retryable: false,
			});
		});

		test("does NOT reconnect when reconnect=false", async () => {
			const mockWs = new MockWebSocket();
			function wsFactory2() {
				return mockWs;
			}
			(globalThis as Record<string, unknown>).WebSocket = Object.assign(
				wsFactory2,
				{ OPEN: MockWebSocket.OPEN },
			);

			const manager = new ConnectionManager({
				url: "ws://localhost:3000",
				auth: { anonymous: true },
				reconnect: false,
			});

			const events: string[] = [];
			manager.on("reconnecting", () => events.push("reconnecting"));
			manager.on("disconnected", () => events.push("disconnected"));

			await connectManager(manager, mockWs);

			mockWs.triggerClose(1006, "Abnormal closure");

			await new Promise((r) => setTimeout(r, 10));
			expect(events).not.toContain("reconnecting");
			expect(events).toContain("disconnected");
		});

		test("emits 'disconnected' and stops when maxReconnectAttempts exceeded", async () => {
			const mockWs = new MockWebSocket();
			function wsFactory3() {
				return mockWs;
			}
			(globalThis as Record<string, unknown>).WebSocket = Object.assign(
				wsFactory3,
				{ OPEN: MockWebSocket.OPEN },
			);

			const manager = new ConnectionManager({
				url: "ws://localhost:3000",
				auth: { anonymous: true },
				reconnect: true,
				reconnectDelay: 10,
				maxReconnectDelay: 100,
				maxReconnectAttempts: 0,
			});

			const events: string[] = [];
			manager.on("reconnecting", () => events.push("reconnecting"));
			manager.on("disconnected", () => events.push("disconnected"));

			await connectManager(manager, mockWs);

			mockWs.triggerClose(1006, "Abnormal closure");

			await new Promise((r) => setTimeout(r, 10));
			expect(events).not.toContain("reconnecting");
			expect(events).toContain("disconnected");
		});

		test("cancels reconnect timer on disconnect()", async () => {
			const mockWs = new MockWebSocket();
			let wsInstances = 0;
			function wsFactory4() {
				wsInstances++;
				return mockWs;
			}
			(globalThis as Record<string, unknown>).WebSocket = Object.assign(
				wsFactory4,
				{ OPEN: MockWebSocket.OPEN },
			);

			const manager = new ConnectionManager({
				url: "ws://localhost:3000",
				auth: { anonymous: true },
				reconnect: true,
				reconnectDelay: 200,
				maxReconnectDelay: 5000,
			});

			await connectManager(manager, mockWs);

			const instancesBeforeClose = wsInstances;
			mockWs.triggerClose(1006, "Abnormal closure");

			manager.disconnect();

			await new Promise((r) => setTimeout(r, 300));
			expect(wsInstances).toBe(instancesBeforeClose);
		});

		test("does NOT reconnect on intentional disconnect()", async () => {
			const mockWs = new MockWebSocket();
			function wsFactory5() {
				return mockWs;
			}
			(globalThis as Record<string, unknown>).WebSocket = Object.assign(
				wsFactory5,
				{ OPEN: MockWebSocket.OPEN },
			);

			const manager = new ConnectionManager({
				url: "ws://localhost:3000",
				auth: { anonymous: true },
				reconnect: true,
				reconnectDelay: 50,
			});

			const events: string[] = [];
			manager.on("reconnecting", () => events.push("reconnecting"));

			await connectManager(manager, mockWs);

			manager.disconnect();

			await new Promise((r) => setTimeout(r, 100));
			expect(events).not.toContain("reconnecting");
		});
	});

	describe("_computeBackoffDelay()", () => {
		test("returns delay within ±10% jitter bounds and capped at maxReconnectDelay", () => {
			const manager = new ConnectionManager({
				url: "ws://localhost:3000",
				reconnectDelay: 1000,
				maxReconnectDelay: 30000,
			});

			for (let attempt = 0; attempt <= 5; attempt++) {
				const preCap = 1000 * 2 ** attempt;
				const delay = manager._computeBackoffDelay(attempt);
				const lower = preCap * 0.9;
				const upper = Math.min(preCap * 1.1, 30000);
				expect(delay).toBeGreaterThanOrEqual(lower);
				expect(delay).toBeLessThanOrEqual(upper);
			}
		});

		test("caps delay at maxReconnectDelay", () => {
			const manager = new ConnectionManager({
				url: "ws://localhost:3000",
				reconnectDelay: 1000,
				maxReconnectDelay: 5000,
			});

			const delay = manager._computeBackoffDelay(10);
			expect(delay).toBeLessThanOrEqual(5000);
		});

		test("uses default values when options not specified", () => {
			const manager = new ConnectionManager({ url: "ws://localhost:3000" });
			const delay = manager._computeBackoffDelay(0);
			expect(delay).toBeGreaterThanOrEqual(900);
			expect(delay).toBeLessThanOrEqual(1100);
		});
	});

	describe("dispatch() — automatic retry", () => {
		test("retries on RATE_LIMITED and succeeds", async () => {
			const { manager, mockWs } = makeManager({ reconnectDelay: 10 });
			await connectManager(manager, mockWs);

			const p = manager.dispatch({
				type: "StoreSet",
				path: ["a", "b"],
				value: 1,
			});

			// First attempt: send RATE_LIMITED with retryAfter
			await new Promise((r) => setTimeout(r, 0));
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "error",
					id: 2,
					code: "RATE_LIMITED",
					message: "Too many requests",
					retryAfter: 50,
				}),
			);

			// Wait for retry
			await new Promise((r) => setTimeout(r, 100));

			// Second attempt: send ok
			mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: 3 }));

			const result = await p;
			expect(result).toMatchObject({ type: "ok", id: 3 });
			expect(mockWs.sentMessages.length).toBeGreaterThanOrEqual(3);
		});

		test("does not retry validation errors", async () => {
			const { manager, mockWs } = makeManager();
			await connectManager(manager, mockWs);

			const p = manager.dispatch({
				type: "StoreSet",
				path: ["a", "b"],
				value: 1,
			});

			mockWs.triggerMessage(
				encodeToBuffer({
					type: "error",
					id: 2,
					code: "SCHEMA_VALIDATION_FAILED",
					message: "Invalid data",
				}),
			);

			await expect(p).rejects.toMatchObject({
				code: "SCHEMA_VALIDATION_FAILED",
			});

			// Only one message sent (no retry)
			expect(mockWs.sentMessages.length).toBe(2);
		});

		test("gives up after maxServerRetries for server errors", async () => {
			const { manager, mockWs } = makeManager({
				reconnectDelay: 10,
				maxServerRetries: 2,
			});
			await connectManager(manager, mockWs);

			const p = manager.dispatch({
				type: "StoreSet",
				path: ["a", "b"],
				value: 1,
			});

			// First attempt: INTERNAL_ERROR
			await new Promise((r) => setTimeout(r, 0));
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "error",
					id: 2,
					code: "INTERNAL_ERROR",
					message: "Server error",
				}),
			);

			// Wait for first retry
			await new Promise((r) => setTimeout(r, 50));

			// Second attempt: INTERNAL_ERROR
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "error",
					id: 3,
					code: "INTERNAL_ERROR",
					message: "Server error",
				}),
			);

			// Wait for second retry
			await new Promise((r) => setTimeout(r, 50));

			// Third attempt: INTERNAL_ERROR (should give up)
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "error",
					id: 4,
					code: "INTERNAL_ERROR",
					message: "Server error",
				}),
			);

			await expect(p).rejects.toMatchObject({ code: "INTERNAL_ERROR" });
		});

		test("does not retry when retryRateLimits is false", async () => {
			const { manager, mockWs } = makeManager({ retryRateLimits: false });
			await connectManager(manager, mockWs);

			const p = manager.dispatch({
				type: "StoreSet",
				path: ["a", "b"],
				value: 1,
			});

			mockWs.triggerMessage(
				encodeToBuffer({
					type: "error",
					id: 2,
					code: "RATE_LIMITED",
					message: "Too many requests",
				}),
			);

			await expect(p).rejects.toMatchObject({ code: "RATE_LIMITED" });

			// Only one message sent (no retry)
			expect(mockWs.sentMessages.length).toBe(2);
		});

		test("respects retryAfter delay", async () => {
			const { manager, mockWs } = makeManager({ reconnectDelay: 10 });
			await connectManager(manager, mockWs);

			const p = manager.dispatch({
				type: "StoreSet",
				path: ["a", "b"],
				value: 1,
			});

			// First attempt: RATE_LIMITED with retryAfter=200
			await new Promise((r) => setTimeout(r, 0));
			const startTime = Date.now();
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "error",
					id: 2,
					code: "RATE_LIMITED",
					message: "Too many requests",
					retryAfter: 200,
				}),
			);

			// Wait for retry (should take ~200ms, not ~10ms)
			await new Promise((r) => setTimeout(r, 100));
			// Should still be waiting
			expect(mockWs.sentMessages.length).toBe(2);

			// Wait for retry to happen
			await new Promise((r) => setTimeout(r, 150));
			// Now retry should have happened
			expect(mockWs.sentMessages.length).toBe(3);

			// Send ok to resolve
			mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: 3 }));
			await p;

			const elapsed = Date.now() - startTime;
			expect(elapsed).toBeGreaterThanOrEqual(180);
		});
	});
});
