import { describe, expect, test } from "bun:test";
import { encode } from "@msgpack/msgpack";
import { createClient, ZyncBaseClient } from "./client";
import {
	installMockWs,
	MockWebSocket,
	triggerNamespaceOk,
	triggerSchemaSync,
} from "./test-helpers";
import type { ClientOptions } from "./types";

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
	reconnect: false,
};

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
		mockWs.triggerOpen();
		triggerNamespaceOk(mockWs);
		triggerSchemaSync(mockWs);
		await p;
		expect(events).toContain("connected");
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

		const errorResponse = encode({
			type: "error",
			id: decoded.id,
			code: "INTERNAL_ERROR",
			message: "oops",
		});
		mockWs.triggerMessage(errorResponse as unknown as ArrayBuffer);

		await setPromise;
		expect(errors.length).toBeGreaterThan(0);
		expect((errors[0] as Record<string, unknown>).code).toBe("INTERNAL_ERROR");
		client.disconnect();
		restoreWebSocket();
	});
});
