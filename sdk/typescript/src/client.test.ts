import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { decode } from "@msgpack/msgpack";
import { createClient, ZyncBaseClient } from "./client";
import { WireMessageType } from "./connection_wire";
import { packDocId, unpackDocId } from "./doc_id";
import {
	encodeToBuffer,
	installMockFetchTicket,
	installMockWs,
	MockWebSocket,
	restoreFetch,
	TEST_USER_ID,
	triggerNamespaceOk,
	triggerSchemaSync,
} from "./test-helpers";
import type { ClientOptions, JsonValue } from "./types";

let mockWs: MockWebSocket;
const OriginalWebSocket = globalThis.WebSocket;

function installMockWebSocket() {
	mockWs = new MockWebSocket();
	installMockWs(mockWs);
}

function restoreWebSocket() {
	(globalThis as unknown as { WebSocket: unknown }).WebSocket =
		OriginalWebSocket;
}

const defaultOptions: ClientOptions = {
	url: "ws://localhost:3000",
	auth: { anonymous: true },
	reconnect: false,
	liveness: { enabled: false },
};

beforeEach(() => {
	installMockFetchTicket();
});

afterEach(() => {
	restoreFetch();
});

describe("createClient", () => {
	test("returns a ZyncBaseClient instance without connecting", () => {
		const client = createClient(defaultOptions);
		expect(client).toBeInstanceOf(ZyncBaseClient);
		expect(client.store).toBeDefined();
		expect(client.utils).toBeDefined();
		expect(typeof client.utils.id).toBe("function");
	});

	test("does not open a WebSocket before connect() is called", () => {
		let wsCreated = false;
		(globalThis as unknown as { WebSocket: unknown }).WebSocket = class {
			static OPEN = 1;
			constructor() {
				wsCreated = true;
			}
		};
		createClient(defaultOptions);
		expect(wsCreated).toBe(false);
		restoreWebSocket();
	});
});

describe("ZyncBaseClient", () => {
	test("connect() returns a Promise<void> that resolves on SchemaSync", async () => {
		installMockWebSocket();
		const client = createClient(defaultOptions);
		const p = client.connect();
		await new Promise((r) => setTimeout(r, 0));
		mockWs.triggerOpen();
		triggerNamespaceOk(mockWs);
		triggerSchemaSync(mockWs);
		await expect(p).resolves.toBeUndefined();
		client.disconnect();
		restoreWebSocket();
	});

	test("disconnect() closes the socket", async () => {
		installMockWebSocket();
		const client = createClient(defaultOptions);
		const p = client.connect();
		await new Promise((r) => setTimeout(r, 0));
		mockWs.triggerOpen();
		triggerNamespaceOk(mockWs);
		triggerSchemaSync(mockWs);
		await p;
		client.disconnect();
		expect(mockWs.readyState).toBe(MockWebSocket.CLOSED);
		restoreWebSocket();
	});

	test("on(event, cb) delegates to ConnectionManager — 'connected' fires", async () => {
		installMockWebSocket();
		const client = createClient(defaultOptions);
		const events: string[] = [];
		client.on("connected", () => events.push("connected"));
		const p = client.connect();
		await new Promise((r) => setTimeout(r, 0));
		mockWs.triggerOpen();
		triggerNamespaceOk(mockWs);
		triggerSchemaSync(mockWs);
		await p;
		expect(events).toContain("connected");
		client.disconnect();
		restoreWebSocket();
	});

	/** Poll until `cond` holds — inbound processing is a chained async pipeline. */
	async function waitFor(cond: () => boolean, timeoutMs = 500): Promise<void> {
		const start = Date.now();
		while (!cond()) {
			if (Date.now() - start > timeoutMs) {
				throw new Error("waitFor: condition not met in time");
			}
			await new Promise((r) => setTimeout(r, 5));
		}
	}

	/**
	 * Reply to the namespace handshake with whatever id the connection actually
	 * used (reconnects continue the id sequence, so it is not always 1).
	 */
	async function handshakeNamespaces(ws: MockWebSocket): Promise<void> {
		const handshake = decode(ws.sentMessages.at(-1) as Uint8Array) as {
			id: number;
			type: number;
		};
		expect(handshake.type).toBe(WireMessageType.StoreSetNamespace);
		ws.triggerMessage(
			encodeToBuffer({
				type: "ok",
				id: handshake.id,
				userId: packDocId(TEST_USER_ID),
			}),
		);
		await new Promise((r) => setTimeout(r, 0));
	}

	test("lifecycle: first connect emits connected + synced, a reconnect adds reconnected", async () => {
		installMockWebSocket();
		const client = createClient({
			...defaultOptions,
			reconnect: true,
			reconnectDelay: 10,
		});
		const events: string[] = [];
		client.on("connected", () => events.push("connected"));
		client.on("reconnected", () => events.push("reconnected"));
		client.on("synced", () => events.push("synced"));

		expect(client.status).toBe("disconnected");
		const p = client.connect();
		await new Promise((r) => setTimeout(r, 0));
		expect(client.status).toBe("connecting");
		mockWs.triggerOpen();
		await handshakeNamespaces(mockWs);
		triggerSchemaSync(mockWs);
		await p;
		expect(client.status).toBe("connected");
		expect(events).toEqual(["connected", "synced"]);

		// Drop the socket — the SDK reconnects on the configured backoff.
		mockWs.triggerClose(1006, "Abnormal closure");
		expect(client.status).not.toBe("connected");
		// Wait for the reconnect to acquire its ticket and wire up the socket.
		await waitFor(() => client.status === "connecting");
		await new Promise((r) => setTimeout(r, 10));
		mockWs.triggerOpen();
		await handshakeNamespaces(mockWs);
		triggerSchemaSync(mockWs);
		await waitFor(() => events.length === 5);

		expect(client.status).toBe("connected");
		expect(events).toEqual([
			"connected",
			"synced",
			"connected",
			"reconnected",
			"synced",
		]);
		client.disconnect();
		restoreWebSocket();
	});

	test("a non-retryable replay failure surfaces as an error and is not retried", async () => {
		installMockWebSocket();
		const client = createClient(defaultOptions);
		const errors: Array<{ code: string; retryable: boolean }> = [];
		client.on("error", (err) => errors.push(err));

		const connected = client.connect();
		await new Promise((r) => setTimeout(r, 0));
		mockWs.triggerOpen();
		triggerNamespaceOk(mockWs);
		triggerSchemaSync(mockWs);
		await connected;

		const pendingListen = client.store.listen(["users", "u1"], () => {});
		await new Promise((r) => setTimeout(r, 0));
		const initial = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
		};
		mockWs.triggerMessage(
			encodeToBuffer({ type: "ok", id: initial.id, subId: 7, value: [] }),
		);
		await pendingListen;
		client.disconnect();

		const reconnecting = client.connect();
		reconnecting.catch(() => {});
		await new Promise((r) => setTimeout(r, 0));
		mockWs.triggerOpen();
		await handshakeNamespaces(mockWs);
		triggerSchemaSync(mockWs);
		await waitFor(() => {
			const last = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
				type?: number;
			};
			return last.type === WireMessageType.StoreSubscribe;
		});

		// The replay fails non-retryably: the failure is surfaced to the
		// application and no backoff retry follows.
		const failed = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
		};
		mockWs.triggerMessage(
			encodeToBuffer({
				type: "error",
				id: failed.id,
				code: "PERMISSION_DENIED",
				message: "replay denied",
			}),
		);
		await waitFor(() => errors.length === 1);
		expect(errors[0]).toMatchObject({
			code: "PERMISSION_DENIED",
			retryable: false,
		});

		// No retry within (nor after) the first backoff window: the session
		// stays unrecovered and connect() stays pending.
		const sentAfterError = mockWs.sentMessages.length;
		await new Promise((r) => setTimeout(r, 350));
		expect(mockWs.sentMessages.length).toBe(sentAfterError);

		client.disconnect();
		await expect(reconnecting).rejects.toMatchObject({
			code: "CLIENT_DISCONNECT",
		});
		restoreWebSocket();
	});

	test("connect() rejects when a terminal disconnect precedes synced", async () => {
		installMockWebSocket();
		const client = createClient(defaultOptions);
		const p = client.connect();
		await new Promise((r) => setTimeout(r, 0));
		mockWs.triggerOpen();
		triggerNamespaceOk(mockWs);

		// Tear the connection down before SchemaSync: recovery cannot complete.
		client.disconnect();
		await expect(p).rejects.toMatchObject({ code: "CLIENT_DISCONNECT" });
		restoreWebSocket();
	});

	test("a registration issued before the session is ready queues until synced", async () => {
		installMockWebSocket();
		const client = createClient(defaultOptions);
		const subscribes = () =>
			mockWs.sentMessages.filter((message) => {
				const msg = decode(message) as { type: number };
				return msg.type === WireMessageType.StoreSubscribe;
			});

		const p = client.connect();
		await new Promise((r) => setTimeout(r, 0));
		mockWs.triggerOpen();
		await handshakeNamespaces(mockWs);

		// Schema not yet delivered — the registration must not dispatch.
		const pending = client.store.listen(["users", "u1"], () => {});
		await new Promise((r) => setTimeout(r, 10));
		expect(subscribes()).toHaveLength(0);

		triggerSchemaSync(mockWs);
		await waitFor(() => subscribes().length === 1);
		const sub = decode(subscribes()[0]) as { id: number };
		mockWs.triggerMessage(
			encodeToBuffer({ type: "ok", id: sub.id, subId: 7, value: [] }),
		);

		await p;
		const handle = await pending;
		await handle.unlisten();
		client.disconnect();
		restoreWebSocket();
	});

	test("subscription replay re-delivers document listen snapshots", async () => {
		const userId = "019c1e50-7d11-7000-8000-000000000001";
		installMockWebSocket();
		const client = createClient(defaultOptions);
		const values: JsonValue[] = [];
		const connected = client.connect();
		await new Promise((r) => setTimeout(r, 0));
		mockWs.triggerOpen();
		triggerNamespaceOk(mockWs);
		triggerSchemaSync(mockWs);
		await connected;

		const pendingListen = client.store.listen(["users", userId], (value) =>
			values.push(value),
		);
		await new Promise((r) => setTimeout(r, 0));
		const initial = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
		};
		mockWs.triggerMessage(
			encodeToBuffer({ type: "ok", id: initial.id, subId: 7, value: [] }),
		);
		const handle = await pendingListen;
		await new Promise((r) => setTimeout(r, 0));
		expect(values).toEqual([null]);

		// A namespace switch re-runs the replay path without dropping the socket.
		const switching = client.setStoreNamespace("other");
		await new Promise((r) => setTimeout(r, 0));
		const namespace = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
		};
		mockWs.triggerMessage(
			encodeToBuffer({
				type: "ok",
				id: namespace.id,
				userId: packDocId(TEST_USER_ID),
			}),
		);
		await new Promise((r) => setTimeout(r, 0));

		const replay = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
			conditions?: unknown;
		};
		const condition = (replay.conditions as [number, number, Uint8Array][])[0];
		expect(condition[0]).toBe(0);
		expect(condition[1]).toBe(0);
		expect(unpackDocId(condition[2])).toBe(userId);
		mockWs.triggerMessage(
			encodeToBuffer({
				type: "ok",
				id: replay.id,
				subId: 11,
				value: [[packDocId(userId), 1, "Ada", 0, 0]],
			}),
		);
		await switching;

		// The remapped document listen receives its snapshot again.
		expect(values).toEqual([
			null,
			{
				id: userId,
				namespace_id: 1,
				name: "Ada",
				created_at: 0,
				updated_at: 0,
			},
		]);
		const pendingUnlisten = handle.unlisten();
		await new Promise((r) => setTimeout(r, 350));
		const unsubscribe = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
		};
		mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: unsubscribe.id }));
		await pendingUnlisten;
		client.disconnect();
		restoreWebSocket();
	});

	test("a reconnect without store subscriptions re-enables delta delivery", async () => {
		const userId = "019c1e50-7d11-7000-8000-000000000001";
		installMockWebSocket();
		const client = createClient(defaultOptions);
		const values: JsonValue[] = [];

		const connected = client.connect();
		await new Promise((r) => setTimeout(r, 0));
		mockWs.triggerOpen();
		triggerNamespaceOk(mockWs);
		triggerSchemaSync(mockWs);
		await connected;
		client.disconnect();

		// No store subscriptions exist at reconnect time: the restore must
		// still leave the tracker connected so later deltas are delivered.
		const reconnected = client.connect();
		await new Promise((r) => setTimeout(r, 0));
		mockWs.triggerOpen();
		await handshakeNamespaces(mockWs);
		triggerSchemaSync(mockWs);
		await reconnected;

		const pendingListen = client.store.listen(["users", userId], (value) =>
			values.push(value),
		);
		await new Promise((r) => setTimeout(r, 0));
		const initial = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
		};
		mockWs.triggerMessage(
			encodeToBuffer({ type: "ok", id: initial.id, subId: 7, value: [] }),
		);
		await pendingListen;

		mockWs.triggerMessage(
			encodeToBuffer({
				type: "StoreDelta",
				subId: 7,
				ops: [
					{
						op: "set",
						path: [0, userId],
						value: [packDocId(userId), 1, "Ada", 0, 0],
					},
				],
			}),
		);
		await waitFor(() => values.length === 2);
		expect(values[0]).toBeNull();
		expect(values[1]).toMatchObject({ name: "Ada" });

		client.disconnect();
		restoreWebSocket();
	});

	test("a presence denial during restore does not block store restoration", async () => {
		installMockWebSocket();
		const client = createClient(defaultOptions);
		const errors: Array<{ code?: string }> = [];
		const synced: string[] = [];
		client.on("error", (err) => errors.push(err));
		client.on("synced", () => synced.push("synced"));

		const connected = client.connect();
		await new Promise((r) => setTimeout(r, 0));
		mockWs.triggerOpen();
		triggerNamespaceOk(mockWs);
		triggerSchemaSync(mockWs);
		await connected;

		const pendingListen = client.store.listen(["users", "u1"], () => {});
		await new Promise((r) => setTimeout(r, 0));
		const storeSub = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
			type: number;
		};
		expect(storeSub.type).toBe(WireMessageType.StoreSubscribe);
		mockWs.triggerMessage(
			encodeToBuffer({ type: "ok", id: storeSub.id, subId: 7, value: [] }),
		);
		await pendingListen;

		const pendingPresence = client.presence.subscribe(() => {});
		await new Promise((r) => setTimeout(r, 0));
		const presenceScope = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
			type: number;
		};
		expect(presenceScope.type).toBe(WireMessageType.PresenceSetNamespace);
		mockWs.triggerMessage(
			encodeToBuffer({
				type: "ok",
				id: presenceScope.id,
				userId: packDocId(TEST_USER_ID),
			}),
		);
		await new Promise((r) => setTimeout(r, 0));
		const presenceSub = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
			type: number;
		};
		expect(presenceSub.type).toBe(WireMessageType.PresenceSubscribe);
		mockWs.triggerMessage(
			encodeToBuffer({
				type: "ok",
				id: presenceSub.id,
				subId: 30,
				users: [],
			}),
		);
		await pendingPresence;
		client.disconnect();

		const reconnecting = client.connect();
		await new Promise((r) => setTimeout(r, 0));
		const marker = mockWs.sentMessages.length;
		mockWs.triggerOpen();
		await handshakeNamespaces(mockWs);
		triggerSchemaSync(mockWs);
		await waitFor(() => {
			const replayed = mockWs.sentMessages
				.slice(marker)
				.map((message) => decode(message) as { type: number });
			return (
				replayed.some(
					(message) => message.type === WireMessageType.PresenceSetNamespace,
				) &&
				replayed.some(
					(message) => message.type === WireMessageType.StoreSubscribe,
				)
			);
		}, 1_000);
		const replayed = mockWs.sentMessages
			.slice(marker)
			.map((message) => decode(message) as { id: number; type: number });
		const presenceScopeReplay = replayed.find(
			(message) => message.type === WireMessageType.PresenceSetNamespace,
		);
		const storeReplay = replayed.find(
			(message) => message.type === WireMessageType.StoreSubscribe,
		);
		expect(presenceScopeReplay).toBeDefined();
		expect(storeReplay).toBeDefined();
		mockWs.triggerMessage(
			encodeToBuffer({
				type: "error",
				id: presenceScopeReplay?.id,
				code: "NAMESPACE_UNAUTHORIZED",
				message: "No presence access",
			}),
		);
		mockWs.triggerMessage(
			encodeToBuffer({
				type: "ok",
				id: storeReplay?.id,
				subId: 8,
				value: [],
			}),
		);
		await reconnecting;
		await waitFor(() => synced.length === 2);
		expect(errors.some((err) => err.code === "NAMESPACE_UNAUTHORIZED")).toBe(
			true,
		);
		client.disconnect();
		restoreWebSocket();
	});

	test("a rejected presence switch preserves active presence consumers", async () => {
		installMockWebSocket();
		const client = createClient({
			...defaultOptions,
			presenceNamespace: "public",
		});
		const connected = client.connect();
		await new Promise((r) => setTimeout(r, 0));
		mockWs.triggerOpen();
		triggerNamespaceOk(mockWs);
		triggerSchemaSync(mockWs);
		await connected;

		const deliveries: number[] = [];
		const pendingPresence = client.presence.subscribe((users) =>
			deliveries.push(users.length),
		);
		await new Promise((r) => setTimeout(r, 0));
		const presenceScope = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
			type: number;
		};
		mockWs.triggerMessage(
			encodeToBuffer({
				type: "ok",
				id: presenceScope.id,
				userId: packDocId(TEST_USER_ID),
			}),
		);
		await new Promise((r) => setTimeout(r, 0));
		const presenceSub = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
			type: number;
		};
		mockWs.triggerMessage(
			encodeToBuffer({
				type: "ok",
				id: presenceSub.id,
				subId: 30,
				users: [],
			}),
		);
		await pendingPresence;

		const switching = client.setPresenceNamespace("other");
		await new Promise((r) => setTimeout(r, 0));
		const rejected = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
		};
		mockWs.triggerMessage(
			encodeToBuffer({
				type: "error",
				id: rejected.id,
				code: "NAMESPACE_SWITCH_REJECTED",
				message: "Namespace switching is not allowed",
			}),
		);
		await expect(switching).rejects.toMatchObject({
			code: "NAMESPACE_SWITCH_REJECTED",
		});
		mockWs.triggerMessage(
			encodeToBuffer([
				WireMessageType.PresenceBroadcast,
				30,
				[[packDocId("019c1e50-7d11-7000-8000-000000000002"), 0, [], 1]],
			]),
		);
		await waitFor(() => deliveries.length === 2);
		expect(deliveries.at(-1)).toBe(1);

		const scopeRequestCount = () =>
			mockWs.sentMessages.filter((message) => {
				const msg = decode(message) as { type: number };
				return msg.type === WireMessageType.PresenceSetNamespace;
			}).length;
		const beforeSet = scopeRequestCount();
		const setting = client.presence.set({});
		await new Promise((r) => setTimeout(r, 0));
		const setMessage = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
			type: number;
		};
		expect(setMessage.type).toBe(WireMessageType.PresenceSet);
		mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: setMessage.id }));
		await setting;
		expect(scopeRequestCount()).toBe(beforeSet);
		client.disconnect();
		restoreWebSocket();
	});

	test("a superseded presence switch does not invalidate presence state", async () => {
		installMockWebSocket();
		const client = createClient(defaultOptions);
		const connected = client.connect();
		await new Promise((r) => setTimeout(r, 0));
		mockWs.triggerOpen();
		triggerNamespaceOk(mockWs);
		triggerSchemaSync(mockWs);
		await connected;

		const deliveries: number[] = [];
		client.presence.subscribe((users) => deliveries.push(users.length));
		await new Promise((r) => setTimeout(r, 0));
		const presenceScope = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
			type: number;
		};
		mockWs.triggerMessage(
			encodeToBuffer({
				type: "ok",
				id: presenceScope.id,
				userId: packDocId(TEST_USER_ID),
			}),
		);
		await new Promise((r) => setTimeout(r, 0));
		const presenceSub = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
			type: number;
		};
		mockWs.triggerMessage(
			encodeToBuffer({
				type: "ok",
				id: presenceSub.id,
				subId: 30,
				users: [],
			}),
		);
		mockWs.triggerMessage(
			encodeToBuffer([
				WireMessageType.PresenceBroadcast,
				30,
				[[packDocId("019c1e50-7d11-7000-8000-000000000002"), 0, [], 1]],
			]),
		);
		await waitFor(() => deliveries.length === 2);
		expect(client.presence.getAll()).toHaveLength(1);

		const switching = client.setPresenceNamespace("other");
		await new Promise((r) => setTimeout(r, 0));
		const rejected = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
		};
		mockWs.triggerMessage(
			encodeToBuffer({
				type: "error",
				id: rejected.id,
				code: "REQUEST_SUPERSEDED",
				message: "Superseded by a newer switch",
			}),
		);
		await expect(switching).rejects.toMatchObject({
			code: "REQUEST_SUPERSEDED",
		});
		expect(client.presence.getAll()).toHaveLength(1);
		expect(deliveries).toHaveLength(2);
		client.disconnect();
		restoreWebSocket();
	});

	test("a queued presence set is rejected when the namespace switches", async () => {
		installMockWebSocket();
		const client = createClient({
			...defaultOptions,
			presenceNamespace: "public",
		});
		try {
			const connected = client.connect();
			await new Promise((r) => setTimeout(r, 0));
			mockWs.triggerOpen();
			triggerNamespaceOk(mockWs);
			triggerSchemaSync(mockWs);
			await connected;

			const scopeSetup = client.setPresenceNamespace("public");
			await new Promise((r) => setTimeout(r, 0));
			const scope = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
				id: number;
				type: number;
			};
			expect(scope.type).toBe(WireMessageType.PresenceSetNamespace);
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "ok",
					id: scope.id,
					userId: packDocId(TEST_USER_ID),
				}),
			);
			await scopeSetup;

			const immediate = client.presence.set({});
			await new Promise((r) => setTimeout(r, 0));
			const immediateSet = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
				id: number;
				type: number;
			};
			expect(immediateSet.type).toBe(WireMessageType.PresenceSet);
			mockWs.triggerMessage(
				encodeToBuffer({ type: "ok", id: immediateSet.id }),
			);
			await immediate;

			const queued = client.presence.set({});
			const queuedOutcome = queued.then(
				() => null,
				(err: { code?: string }) => err.code,
			);
			const switching = client.setPresenceNamespace("other");
			await new Promise((r) => setTimeout(r, 20));
			const replacement = decode(
				mockWs.sentMessages.at(-1) as Uint8Array,
			) as { id: number; type: number };
			expect(replacement.type).toBe(WireMessageType.PresenceSetNamespace);
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "ok",
					id: replacement.id,
					userId: packDocId(TEST_USER_ID),
				}),
			);
			await switching;
			await new Promise((r) => setTimeout(r, 0));

			const presenceSets = mockWs.sentMessages.filter((message) => {
				const msg = decode(message) as { type: number };
				return msg.type === WireMessageType.PresenceSet;
			});
			expect(presenceSets).toHaveLength(1);
			expect(await queuedOutcome).toBe("REQUEST_SUPERSEDED");
		} finally {
			client.disconnect();
			restoreWebSocket();
		}
	});

	test("a rejected switch resumes a queued presence set in the old namespace", async () => {
		installMockWebSocket();
		const client = createClient({
			...defaultOptions,
			presenceNamespace: "public",
		});
		try {
			const connected = client.connect();
			await new Promise((r) => setTimeout(r, 0));
			mockWs.triggerOpen();
			triggerNamespaceOk(mockWs);
			triggerSchemaSync(mockWs);
			await connected;

			const scopeSetup = client.setPresenceNamespace("public");
			await new Promise((r) => setTimeout(r, 0));
			const scope = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
				id: number;
				type: number;
			};
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "ok",
					id: scope.id,
					userId: packDocId(TEST_USER_ID),
				}),
			);
			await scopeSetup;

			const immediate = client.presence.set({});
			await new Promise((r) => setTimeout(r, 0));
			const immediateSet = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
				id: number;
				type: number;
			};
			mockWs.triggerMessage(
				encodeToBuffer({ type: "ok", id: immediateSet.id }),
			);
			await immediate;

			const queued = client.presence.set({});
			const queuedOutcome = queued.then(
				() => null,
				(err: { code?: string }) => err.code,
			);
			const switching = client.setPresenceNamespace("other");
			await new Promise((r) => setTimeout(r, 0));
			const rejected = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
				id: number;
			};
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "error",
					id: rejected.id,
					code: "NAMESPACE_SWITCH_REJECTED",
					message: "Namespace switching is not allowed",
				}),
			);
			await expect(switching).rejects.toMatchObject({
				code: "NAMESPACE_SWITCH_REJECTED",
			});
			await new Promise((r) => setTimeout(r, 20));

			const presenceSets = mockWs.sentMessages.filter((message) => {
				const msg = decode(message) as { type: number };
				return msg.type === WireMessageType.PresenceSet;
			});
			expect(presenceSets).toHaveLength(2);
			const resumed = decode(presenceSets.at(-1) as Uint8Array) as {
				id: number;
			};
			mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: resumed.id }));
			await queued;
			expect(await queuedOutcome).toBeNull();
		} finally {
			client.disconnect();
			restoreWebSocket();
		}
	});

	test("a stale switch promise rejects with REQUEST_SUPERSEDED", async () => {
		installMockWebSocket();
		const client = createClient(defaultOptions);
		try {
			const connected = client.connect();
			await new Promise((r) => setTimeout(r, 0));
			mockWs.triggerOpen();
			triggerNamespaceOk(mockWs);
			triggerSchemaSync(mockWs);
			await connected;

			const first = client.setPresenceNamespace("room1");
			first.catch(() => {});
			await new Promise((r) => setTimeout(r, 0));
			const firstScope = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
				id: number;
			};
			const second = client.setPresenceNamespace("room2");
			second.catch(() => {});
			await new Promise((r) => setTimeout(r, 0));

			mockWs.triggerMessage(
				encodeToBuffer({
					type: "ok",
					id: firstScope.id,
					userId: packDocId(TEST_USER_ID),
				}),
			);
			await expect(first).rejects.toMatchObject({
				code: "REQUEST_SUPERSEDED",
			});
		} finally {
			client.disconnect();
			restoreWebSocket();
		}
	});

	test("a stale switch completion does not invalidate a newer switch", async () => {
		installMockWebSocket();
		const client = createClient(defaultOptions);
		try {
			const connected = client.connect();
			await new Promise((r) => setTimeout(r, 0));
			mockWs.triggerOpen();
			triggerNamespaceOk(mockWs);
			triggerSchemaSync(mockWs);
			await connected;

			const deliveries: number[] = [];
			client.presence.subscribe((users) => deliveries.push(users.length));
			await new Promise((r) => setTimeout(r, 0));
			const presenceScope = decode(
				mockWs.sentMessages.at(-1) as Uint8Array,
			) as { id: number; type: number };
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "ok",
					id: presenceScope.id,
					userId: packDocId(TEST_USER_ID),
				}),
			);
			await new Promise((r) => setTimeout(r, 0));
			const presenceSub = decode(
				mockWs.sentMessages.at(-1) as Uint8Array,
			) as { id: number; type: number };
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "ok",
					id: presenceSub.id,
					subId: 30,
					users: [],
				}),
			);
			mockWs.triggerMessage(
				encodeToBuffer([
					WireMessageType.PresenceBroadcast,
					30,
					[[packDocId("019c1e50-7d11-7000-8000-000000000002"), 0, [], 1]],
				]),
			);
			await waitFor(() => deliveries.length === 2);
			expect(client.presence.getAll()).toHaveLength(1);

			const first = client.setPresenceNamespace("room1");
			first.catch(() => {});
			await new Promise((r) => setTimeout(r, 0));
			const firstScope = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
				id: number;
			};
			const second = client.setPresenceNamespace("room2");
			second.catch(() => {});
			await new Promise((r) => setTimeout(r, 0));

			mockWs.triggerMessage(
				encodeToBuffer({
					type: "ok",
					id: firstScope.id,
					userId: packDocId(TEST_USER_ID),
				}),
			);
			await new Promise((r) => setTimeout(r, 0));

			expect(client.presence.getAll()).toHaveLength(1);
			expect(deliveries).toHaveLength(2);
		} finally {
			client.disconnect();
			restoreWebSocket();
		}
	});

	test("a failed presence switch invalidates the server-reset scope", async () => {
		installMockWebSocket();
		const client = createClient(defaultOptions);
		try {
			const connected = client.connect();
			await new Promise((r) => setTimeout(r, 0));
			mockWs.triggerOpen();
			triggerNamespaceOk(mockWs);
			triggerSchemaSync(mockWs);
			await connected;

			const deliveries: number[] = [];
			client.presence.subscribe((users) => deliveries.push(users.length));
			await new Promise((r) => setTimeout(r, 0));
			const presenceScope = decode(
				mockWs.sentMessages.at(-1) as Uint8Array,
			) as { id: number; type: number };
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "ok",
					id: presenceScope.id,
					userId: packDocId(TEST_USER_ID),
				}),
			);
			await new Promise((r) => setTimeout(r, 0));
			const presenceSub = decode(
				mockWs.sentMessages.at(-1) as Uint8Array,
			) as { id: number; type: number };
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "ok",
					id: presenceSub.id,
					subId: 30,
					users: [],
				}),
			);
			mockWs.triggerMessage(
				encodeToBuffer([
					WireMessageType.PresenceBroadcast,
					30,
					[[packDocId("019c1e50-7d11-7000-8000-000000000002"), 0, [], 1]],
				]),
			);
			await waitFor(() => deliveries.length === 2);
			expect(client.presence.getAll()).toHaveLength(1);

			const switching = client.setPresenceNamespace("other");
			await new Promise((r) => setTimeout(r, 0));
			const rejected = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
				id: number;
			};
			mockWs.triggerMessage(
				encodeToBuffer({
					type: "error",
					id: rejected.id,
					code: "NAMESPACE_UNAUTHORIZED",
					message: "No presence access",
				}),
			);
			await expect(switching).rejects.toMatchObject({
				code: "NAMESPACE_UNAUTHORIZED",
			});
			await new Promise((r) => setTimeout(r, 0));
			expect(client.presence.getAll()).toHaveLength(0);
		} finally {
			client.disconnect();
			restoreWebSocket();
		}
	});

	test("setStoreNamespace replays store subscriptions without touching presence", async () => {
		installMockWebSocket();
		const client = createClient(defaultOptions);
		const connected = client.connect();
		await new Promise((r) => setTimeout(r, 0));
		mockWs.triggerOpen();
		triggerNamespaceOk(mockWs);
		triggerSchemaSync(mockWs);
		await connected;

		const pendingPresence = client.presence.subscribe(() => {});
		await new Promise((r) => setTimeout(r, 0));
		const presenceScope = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
			type: number;
		};
		expect(presenceScope.type).toBe(WireMessageType.PresenceSetNamespace);
		mockWs.triggerMessage(
			encodeToBuffer({
				type: "ok",
				id: presenceScope.id,
				userId: packDocId(TEST_USER_ID),
			}),
		);
		await new Promise((r) => setTimeout(r, 0));
		const presenceSubscribe = decode(
			mockWs.sentMessages.at(-1) as Uint8Array,
		) as { id: number; type: number };
		expect(presenceSubscribe.type).toBe(WireMessageType.PresenceSubscribe);
		mockWs.triggerMessage(
			encodeToBuffer({
				type: "ok",
				id: presenceSubscribe.id,
				subId: 30,
				users: [],
			}),
		);
		const unsubscribe = await pendingPresence;

		const switching = client.setStoreNamespace("other");
		await new Promise((r) => setTimeout(r, 0));
		const namespace = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
		};
		mockWs.triggerMessage(
			encodeToBuffer({
				type: "ok",
				id: namespace.id,
				userId: packDocId(TEST_USER_ID),
			}),
		);
		await switching;

		// The switch restored the store scope without re-subscribing presence.
		const presenceSubscribes = mockWs.sentMessages.filter((message) => {
			const msg = decode(message) as { type: number };
			return msg.type === WireMessageType.PresenceSubscribe;
		});
		expect(presenceSubscribes).toHaveLength(1);

		const removing = unsubscribe();
		await new Promise((r) => setTimeout(r, 0));
		const remove = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
		};
		mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: remove.id }));
		await removing;
		client.disconnect();
		restoreWebSocket();
	});

	test("setPresenceNamespace establishes a same-namespace scope once and waits for it", async () => {
		installMockWebSocket();
		const client = createClient({
			...defaultOptions,
			presenceNamespace: "public",
		});
		const connected = client.connect();
		await new Promise((r) => setTimeout(r, 0));
		mockWs.triggerOpen();
		triggerNamespaceOk(mockWs);
		triggerSchemaSync(mockWs);
		await connected;

		const first = client.setPresenceNamespace("public");
		const second = client.setPresenceNamespace("public");
		await new Promise((r) => setTimeout(r, 0));
		const setups = mockWs.sentMessages
			.map((message) => decode(message) as { id: number; type: number })
			.filter(
				(message) => message.type === WireMessageType.PresenceSetNamespace,
			);
		expect(setups).toHaveLength(1);

		mockWs.triggerMessage(
			encodeToBuffer({
				type: "ok",
				id: setups[0].id,
				userId: packDocId(TEST_USER_ID),
			}),
		);
		await Promise.all([first, second]);

		await client.setPresenceNamespace("public");
		const setupCount = mockWs.sentMessages.filter((message) => {
			const msg = decode(message) as { type: number };
			return msg.type === WireMessageType.PresenceSetNamespace;
		}).length;
		expect(setupCount).toBe(1);
		client.disconnect();
		restoreWebSocket();
	});

	test("a rejected namespace switch restores session readiness", async () => {
		installMockWebSocket();
		const client = createClient(defaultOptions);
		const connected = client.connect();
		await new Promise((r) => setTimeout(r, 0));
		mockWs.triggerOpen();
		triggerNamespaceOk(mockWs);
		triggerSchemaSync(mockWs);
		await connected;

		// A listen whose ack crosses the switch must still register: until the
		// outcome is known its scope cannot be invalidated.
		const crossing = client.store.listen(["users", "u1"], () => {});
		await new Promise((r) => setTimeout(r, 0));
		const crossingSub = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
			type: number;
		};
		expect(crossingSub.type).toBe(WireMessageType.StoreSubscribe);

		// The switch gates new establishments while its outcome is unknown.
		const switching = client.setStoreNamespace("another-world");
		await new Promise((r) => setTimeout(r, 0));
		const namespace = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
			type: number;
		};
		expect(namespace.type).toBe(WireMessageType.StoreSetNamespace);
		const gated = mockWs.sentMessages.length;
		const queued = client.store.listen(["users", "u2"], () => {});
		await new Promise((r) => setTimeout(r, 10));
		expect(mockWs.sentMessages.length).toBe(gated);

		// A rejection releases the gate without invalidating the old scope.
		mockWs.triggerMessage(
			encodeToBuffer({
				type: "error",
				id: namespace.id,
				code: "NAMESPACE_SWITCH_REJECTED",
				message: "rejected",
			}),
		);
		await expect(switching).rejects.toMatchObject({
			code: "NAMESPACE_SWITCH_REJECTED",
		});
		await new Promise((r) => setTimeout(r, 10));
		// Exactly the gated listen goes out — no stale re-subscribe, no
		// cleanup unsubscribe.
		expect(mockWs.sentMessages.length).toBe(gated + 1);
		const queuedMsg = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
			type: number;
		};
		expect(queuedMsg.type).toBe(WireMessageType.StoreSubscribe);
		mockWs.triggerMessage(
			encodeToBuffer({ type: "ok", id: queuedMsg.id, subId: 8, value: [] }),
		);
		const queuedHandle = await queued;

		// The pre-switch acknowledgement registers as-is.
		const beforeCrossing = mockWs.sentMessages.length;
		mockWs.triggerMessage(
			encodeToBuffer({
				type: "ok",
				id: crossingSub.id,
				subId: 7,
				value: [],
			}),
		);
		await new Promise((r) => setTimeout(r, 10));
		expect(mockWs.sentMessages.length).toBe(beforeCrossing);
		const crossingHandle = await crossing;
		await crossingHandle.unlisten();
		await queuedHandle.unlisten();
		client.disconnect();
		restoreWebSocket();
	});

	test("utils.id() returns a valid UUIDv7 string", () => {
		const client = createClient(defaultOptions);
		const id = client.utils.id();
		expect(id).toMatch(
			/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
		);
	});

	test("client.on('error', cb) receives errors from fire-and-forget store.set", async () => {
		installMockWebSocket();
		const client = createClient(defaultOptions);
		const errors: unknown[] = [];
		client.on("error", (err) => errors.push(err));

		const p = client.connect();
		await new Promise((r) => setTimeout(r, 0));
		mockWs.triggerOpen();
		triggerNamespaceOk(mockWs);
		triggerSchemaSync(mockWs);
		await p;

		const setPromise = client.store
			.set("users.u1", { name: "Alice" })
			.catch(() => {});

		await new Promise((r) => setTimeout(r, 0));
		const lastMsg = mockWs.sentMessages[mockWs.sentMessages.length - 1];
		const { decode } = await import("@msgpack/msgpack");
		const decoded = decode(lastMsg) as Record<string, unknown>;

		const errorResponse = encodeToBuffer({
			type: "error",
			id: decoded.id,
			code: "SCHEMA_VALIDATION_FAILED",
			message: "oops",
		});
		mockWs.triggerMessage(errorResponse);

		await setPromise;
		expect(errors.length).toBeGreaterThan(0);
		expect((errors[0] as Record<string, unknown>).code).toBe(
			"SCHEMA_VALIDATION_FAILED",
		);
		client.disconnect();
		restoreWebSocket();
	});

	test("authRefresh() dispatches AuthRefresh wire message", async () => {
		installMockWebSocket();
		const client = createClient(defaultOptions);
		const p = client.connect();
		await new Promise((r) => setTimeout(r, 0));
		mockWs.triggerOpen();
		triggerNamespaceOk(mockWs);
		triggerSchemaSync(mockWs);
		await p;

		const refreshPromise = client.authRefresh("new-jwt-token");
		const lastMsg = mockWs.sentMessages[mockWs.sentMessages.length - 1];
		const { decode } = await import("@msgpack/msgpack");
		const decoded = decode(lastMsg) as Record<string, unknown>;
		expect(decoded.type).toBe(0x04);
		expect(decoded.token).toBe("new-jwt-token");

		mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: decoded.id }));
		await refreshPromise;

		client.disconnect();
		restoreWebSocket();
	});
});
