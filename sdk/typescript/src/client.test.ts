import { describe, test, expect, mock } from "bun:test";
import { createClient, ZyncBaseClient } from "./client";
import { encode } from "@msgpack/msgpack";
import type { ClientOptions } from "./types";

// ─── Mock WebSocket ───────────────────────────────────────────────────────────

class MockWebSocket {
  static OPEN = 1;
  static CLOSING = 2;
  static CLOSED = 3;

  readyState = MockWebSocket.OPEN;
  binaryType: string = "";
  sentMessages: Uint8Array[] = [];

  onopen: ((event: any) => void) | null = null;
  onclose: ((event: any) => void) | null = null;
  onerror: ((event: any) => void) | null = null;
  onmessage: ((event: any) => void) | null = null;

  send(data: Uint8Array) { this.sentMessages.push(data); }
  close() { this.readyState = MockWebSocket.CLOSED; }

  triggerOpen() { this.onopen?.({}); }
  triggerMessage(data: ArrayBuffer) { this.onmessage?.({ data }); }
  triggerClose(code = 1000, reason = "") {
    this.readyState = MockWebSocket.CLOSED;
    this.onclose?.({ code, reason });
  }
}

let mockWs: MockWebSocket;
const OriginalWebSocket = globalThis.WebSocket;

function installMockWebSocket() {
  mockWs = new MockWebSocket();
  (globalThis as any).WebSocket = class {
    static OPEN = MockWebSocket.OPEN;
    static CLOSING = MockWebSocket.CLOSING;
    static CLOSED = MockWebSocket.CLOSED;
    constructor(_url: string) { return mockWs as any; }
  };
}

function restoreWebSocket() {
  (globalThis as any).WebSocket = OriginalWebSocket;
}

const defaultOptions: ClientOptions = {
  url: "ws://localhost:3000",
  reconnect: false,
};

// ─── Tests ────────────────────────────────────────────────────────────────────

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
    (globalThis as any).WebSocket = class {
      static OPEN = 1;
      constructor() { wsCreated = true; }
    };
    createClient(defaultOptions);
    expect(wsCreated).toBe(false);
    restoreWebSocket();
  });
});

describe("ZyncBaseClient", () => {
  test("connect() returns a Promise<void> that resolves on open", async () => {
    installMockWebSocket();
    const client = createClient(defaultOptions);
    const p = client.connect();
    mockWs.triggerOpen();
    await expect(p).resolves.toBeUndefined();
    restoreWebSocket();
  });

  test("disconnect() closes the socket", async () => {
    installMockWebSocket();
    const client = createClient(defaultOptions);
    const p = client.connect();
    mockWs.triggerOpen();
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
    await p;
    expect(events).toContain("connected");
    restoreWebSocket();
  });

  test("utils.id() returns a valid UUIDv7 string", () => {
    const client = createClient(defaultOptions);
    const id = client.utils.id();
    expect(id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  });

  test("client.on('error', cb) receives errors from fire-and-forget store.set", async () => {
    installMockWebSocket();
    const client = createClient(defaultOptions);
    const errors: any[] = [];
    client.on("error", (err) => errors.push(err));

    const p = client.connect();
    mockWs.triggerOpen();
    await p;

    // Trigger a set call but catch its rejection to allow the test to continue
    const setPromise = client.store.set("users.u1", { name: "Alice" }).catch(() => {});

    // Find the dispatched message and respond with an error
    await new Promise((r) => setTimeout(r, 0)); // flush microtasks
    const lastMsg = mockWs.sentMessages[mockWs.sentMessages.length - 1];
    const { decode } = await import("@msgpack/msgpack");
    const decoded = decode(lastMsg) as any;

    const errorResponse = encode({ type: "error", id: decoded.id, code: "INTERNAL_ERROR", message: "oops" });
    // Pass as Uint8Array directly (connection.ts handles both ArrayBuffer and Uint8Array)
    mockWs.triggerMessage(errorResponse as unknown as ArrayBuffer);

    await setPromise;
    expect(errors.length).toBeGreaterThan(0);
    expect(errors[0].code).toBe("INTERNAL_ERROR");

    restoreWebSocket();
  });
});
