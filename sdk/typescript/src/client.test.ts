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
	 * Reply to a namespace handshake with whatever ids the connection actually
	 * used (reconnects continue the id sequence, so ids are not always 1/2).
	 */
	async function handshakeNamespaces(ws: MockWebSocket): Promise<void> {
		const first = decode(ws.sentMessages.at(-1) as Uint8Array) as {
			id: number;
		};
		ws.triggerMessage(encodeToBuffer({ type: "ok", id: first.id }));
		await new Promise((r) => setTimeout(r, 0));
		const second = decode(ws.sentMessages.at(-1) as Uint8Array) as {
			id: number;
		};
		if (second.id !== first.id) {
			ws.triggerMessage(
				encodeToBuffer({
					type: "ok",
					id: second.id,
					userId: packDocId("019c1e50-7d11-7000-8000-000000000001"),
				}),
			);
			await new Promise((r) => setTimeout(r, 0));
		}
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
		expect(values).toEqual([]);

		// A namespace switch re-runs the replay path without dropping the socket.
		const switching = client.setStoreNamespace("other");
		await new Promise((r) => setTimeout(r, 0));
		const namespace = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
		};
		mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: namespace.id }));
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

	test("a rejected namespace switch restores session readiness", async () => {
		installMockWebSocket();
		const client = createClient(defaultOptions);
		const connected = client.connect();
		await new Promise((r) => setTimeout(r, 0));
		mockWs.triggerOpen();
		triggerNamespaceOk(mockWs);
		triggerSchemaSync(mockWs);
		await connected;

		// The switch clears readiness first; a rejection must put it back or
		// every later registration queues forever.
		const switching = client.setStoreNamespace("another-world");
		await new Promise((r) => setTimeout(r, 0));
		const namespace = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
		};
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

		const pending = client.store.listen(["users", "u1"], () => {});
		await new Promise((r) => setTimeout(r, 10));
		const dispatched = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
			type: number;
		};
		expect(dispatched.type).toBe(WireMessageType.StoreSubscribe);
		mockWs.triggerMessage(
			encodeToBuffer({ type: "ok", id: dispatched.id, subId: 7, value: [] }),
		);
		const handle = await pending;
		await handle.unlisten();
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
