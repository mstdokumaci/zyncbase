import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { decode } from "@msgpack/msgpack";
import { createClient, ZyncBaseClient } from "./client";
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

		const unlisten = client.store.listen(["users", userId], (value) =>
			values.push(value),
		);
		await new Promise((r) => setTimeout(r, 0));
		const initial = decode(mockWs.sentMessages.at(-1) as Uint8Array) as {
			id: number;
		};
		mockWs.triggerMessage(
			encodeToBuffer({ type: "ok", id: initial.id, subId: 7, value: [] }),
		);
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
		unlisten();
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
