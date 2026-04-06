import { describe, test, expect } from "bun:test";
import { ConnectionManager } from "./connection";
import { encode, decode } from "@msgpack/msgpack";
import type { ClientOptions } from "./types";

// Minimal mock WebSocket for unit testing
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

  send(data: Uint8Array) {
    this.sentMessages.push(data);
  }

  close() {
    this.readyState = MockWebSocket.CLOSED;
  }

  // Test helpers
  triggerOpen() {
    this.onopen?.({});
  }

  triggerMessage(data: ArrayBuffer) {
    this.onmessage?.({ data });
  }

  triggerClose(code = 1000, reason = "") {
    this.readyState = MockWebSocket.CLOSED;
    this.onclose?.({ code, reason });
  }

  triggerError() {
    this.onerror?.({});
  }
}

const defaultOptions: ClientOptions = {
  url: "ws://localhost:3000",
  reconnect: false,
};

/** encode() may return a Uint8Array view into a larger buffer; this returns an exact-size ArrayBuffer */
function encodeToBuffer(msg: any): ArrayBuffer {
  const encoded = encode(msg);
  return encoded.buffer.slice(encoded.byteOffset, encoded.byteOffset + encoded.byteLength) as ArrayBuffer;
}

function makeManager(): { manager: ConnectionManager; mockWs: MockWebSocket } {
  const mockWs = new MockWebSocket();
  // Patch global WebSocket
  (globalThis as any).WebSocket = class {
    constructor() { return mockWs; }
    static OPEN = MockWebSocket.OPEN;
  };
  const manager = new ConnectionManager(defaultOptions);
  return { manager, mockWs };
}

describe("ConnectionManager", () => {
  describe("connect()", () => {
    test("sets binaryType to arraybuffer on WebSocket creation", async () => {
      const { manager, mockWs } = makeManager();
      const connectPromise = manager.connect();
      mockWs.triggerOpen();
      await connectPromise;
      expect(mockWs.binaryType).toBe("arraybuffer");
    });

    test("resolves when WebSocket opens", async () => {
      const { manager, mockWs } = makeManager();
      const connectPromise = manager.connect();
      mockWs.triggerOpen();
      await expect(connectPromise).resolves.toBeUndefined();
    });

    test("emits 'connected' lifecycle event on open", async () => {
      const { manager, mockWs } = makeManager();
      const events: string[] = [];
      manager.on("connected", () => events.push("connected"));
      const connectPromise = manager.connect();
      mockWs.triggerOpen();
      await connectPromise;
      expect(events).toContain("connected");
    });

    test("emits 'statusChange' with 'connected' on open", async () => {
      const { manager, mockWs } = makeManager();
      const statuses: string[] = [];
      manager.on("statusChange", (s: string) => statuses.push(s));
      const connectPromise = manager.connect();
      mockWs.triggerOpen();
      await connectPromise;
      expect(statuses).toContain("connected");
    });

    test("rejects when WebSocket errors", async () => {
      const { manager, mockWs } = makeManager();
      const connectPromise = manager.connect();
      mockWs.triggerError();
      await expect(connectPromise).rejects.toMatchObject({ code: "CONNECTION_FAILED" });
    });
  });

  describe("dispatch() — msg_id and pendingQueue", () => {
    test("assigns incrementing msg_ids starting at 1", async () => {
      const { manager, mockWs } = makeManager();
      const connectPromise = manager.connect();
      mockWs.triggerOpen();
      await connectPromise;

      const p1 = manager.dispatch({ type: "StoreSet", path: ["a", "b"], value: 1 });
      const p2 = manager.dispatch({ type: "StoreSet", path: ["a", "c"], value: 2 });

      const msg1 = decode(mockWs.sentMessages[0]) as any;
      const msg2 = decode(mockWs.sentMessages[1]) as any;

      expect(msg1.id).toBe(1);
      expect(msg2.id).toBe(2);

      // Resolve to avoid unhandled rejections
      // Use encodeToBuffer() to get an exact-size ArrayBuffer
      mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: 1 }));
      mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: 2 }));
      await p1;
      await p2;
    });

    test("resolves promise on type:ok response with matching id", async () => {
      const { manager, mockWs } = makeManager();
      const connectPromise = manager.connect();
      mockWs.triggerOpen();
      await connectPromise;

      const p = manager.dispatch({ type: "StoreSet", path: ["a", "b"], value: 1 });
      mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: 1, value: [{ x: 1 }] }));

      const result = await p;
      expect(result).toMatchObject({ type: "ok", id: 1 });
    });

    test("rejects promise on type:error response with matching id", async () => {
      const { manager, mockWs } = makeManager();
      const connectPromise = manager.connect();
      mockWs.triggerOpen();
      await connectPromise;

      const p = manager.dispatch({ type: "StoreSet", path: ["a", "b"], value: 1 });
      mockWs.triggerMessage(encodeToBuffer({ type: "error", id: 1, code: "PERMISSION_DENIED", message: "Not allowed" }));

      await expect(p).rejects.toMatchObject({ code: "PERMISSION_DENIED" });
    });

    test("discards response with unknown id silently", async () => {
      const { manager, mockWs } = makeManager();
      const connectPromise = manager.connect();
      mockWs.triggerOpen();
      await connectPromise;

      // No dispatch — just send a response with an unknown id
      // Should not throw
      expect(() => mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: 999 }))).not.toThrow();
    });
  });

  describe("StoreDelta routing", () => {
    test("routes StoreDelta to registered delta handler by subId", async () => {
      const { manager, mockWs } = makeManager();
      const connectPromise = manager.connect();
      mockWs.triggerOpen();
      await connectPromise;

      const received: any[] = [];
      manager.onDelta((delta) => received.push(delta));

      const delta = { type: "StoreDelta", subId: 42, ops: [{ op: "set", path: ["users", "u1"], value: { name: "Alice" } }] };
      mockWs.triggerMessage(encodeToBuffer(delta));

      expect(received).toHaveLength(1);
      expect(received[0].subId).toBe(42);
    });

    test("StoreDelta does not affect pendingQueue", async () => {
      const { manager, mockWs } = makeManager();
      const connectPromise = manager.connect();
      mockWs.triggerOpen();
      await connectPromise;

      const p = manager.dispatch({ type: "StoreSet", path: ["a", "b"], value: 1 });

      // Send a StoreDelta — should not resolve/reject the pending dispatch
      const delta = { type: "StoreDelta", subId: 99, ops: [] };
      mockWs.triggerMessage(encodeToBuffer(delta));

      // Now resolve the actual pending request
      mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: 1 }));
      await expect(p).resolves.toMatchObject({ type: "ok", id: 1 });
    });
  });

  describe("lifecycle events", () => {
    test("emits 'disconnected' when WebSocket closes", async () => {
      const { manager, mockWs } = makeManager();
      const connectPromise = manager.connect();
      mockWs.triggerOpen();
      await connectPromise;

      const events: string[] = [];
      manager.on("disconnected", () => events.push("disconnected"));
      mockWs.triggerClose();

      expect(events).toContain("disconnected");
    });

    test("emits 'error' on WebSocket error", async () => {
      const { manager, mockWs } = makeManager();
      const errors: any[] = [];
      manager.on("error", (e: any) => errors.push(e));

      const connectPromise = manager.connect();
      mockWs.triggerError();

      try { await connectPromise; } catch {}

      expect(errors).toHaveLength(1);
      expect(errors[0].code).toBe("CONNECTION_FAILED");
    });

    test("rejects all pending requests when connection closes", async () => {
      const { manager, mockWs } = makeManager();
      const connectPromise = manager.connect();
      mockWs.triggerOpen();
      await connectPromise;

      const p = manager.dispatch({ type: "StoreSet", path: ["a", "b"], value: 1 });
      mockWs.triggerClose(1006, "Abnormal closure");

      await expect(p).rejects.toMatchObject({ code: "CONNECTION_FAILED" });
    });
  });

  describe("disconnect()", () => {
    test("closes the WebSocket and rejects pending requests", async () => {
      const { manager, mockWs } = makeManager();
      const connectPromise = manager.connect();
      mockWs.triggerOpen();
      await connectPromise;

      const p = manager.dispatch({ type: "StoreSet", path: ["a", "b"], value: 1 });
      manager.disconnect();

      await expect(p).rejects.toMatchObject({ code: "CONNECTION_FAILED" });
    });

    test("emits 'disconnected' event", async () => {
      const { manager, mockWs } = makeManager();
      const connectPromise = manager.connect();
      mockWs.triggerOpen();
      await connectPromise;

      const events: string[] = [];
      manager.on("disconnected", () => events.push("disconnected"));
      manager.disconnect();

      expect(events).toContain("disconnected");
    });
  });

  describe("send()", () => {
    test("throws if WebSocket is not open", () => {
      const { manager, mockWs } = makeManager();
      // Don't connect — ws is null
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

      const connectPromise = manager.connect();
      mockWs.triggerOpen();
      await connectPromise;

      expect(events).toHaveLength(0);
    });
  });

  describe("reconnection — exponential backoff", () => {
    test("emits 'reconnecting' on unexpected close when reconnect=true", async () => {
      const mockWs = new MockWebSocket();
      (globalThis as any).WebSocket = class {
        constructor() { return mockWs; }
        static OPEN = MockWebSocket.OPEN;
      };
      const manager = new ConnectionManager({ url: "ws://localhost:3000", reconnect: true, reconnectDelay: 50, maxReconnectDelay: 5000 });

      const events: string[] = [];
      manager.on("reconnecting", () => events.push("reconnecting"));

      const connectPromise = manager.connect();
      mockWs.triggerOpen();
      await connectPromise;

      mockWs.triggerClose(1006, "Abnormal closure");

      // Give the timer a tick to register
      await new Promise(r => setTimeout(r, 10));
      expect(events).toContain("reconnecting");

      // Clean up timer
      manager.disconnect();
    });

    test("does NOT reconnect when reconnect=false", async () => {
      const mockWs = new MockWebSocket();
      (globalThis as any).WebSocket = class {
        constructor() { return mockWs; }
        static OPEN = MockWebSocket.OPEN;
      };
      const manager = new ConnectionManager({ url: "ws://localhost:3000", reconnect: false });

      const events: string[] = [];
      manager.on("reconnecting", () => events.push("reconnecting"));
      manager.on("disconnected", () => events.push("disconnected"));

      const connectPromise = manager.connect();
      mockWs.triggerOpen();
      await connectPromise;

      mockWs.triggerClose(1006, "Abnormal closure");

      await new Promise(r => setTimeout(r, 10));
      expect(events).not.toContain("reconnecting");
      expect(events).toContain("disconnected");
    });

    test("emits 'disconnected' and stops when maxReconnectAttempts exceeded", async () => {
      const mockWs = new MockWebSocket();
      (globalThis as any).WebSocket = class {
        constructor() { return mockWs; }
        static OPEN = MockWebSocket.OPEN;
      };
      const manager = new ConnectionManager({
        url: "ws://localhost:3000",
        reconnect: true,
        reconnectDelay: 10,
        maxReconnectDelay: 100,
        maxReconnectAttempts: 0,
      });

      const events: string[] = [];
      manager.on("reconnecting", () => events.push("reconnecting"));
      manager.on("disconnected", () => events.push("disconnected"));

      const connectPromise = manager.connect();
      mockWs.triggerOpen();
      await connectPromise;

      mockWs.triggerClose(1006, "Abnormal closure");

      await new Promise(r => setTimeout(r, 10));
      expect(events).not.toContain("reconnecting");
      expect(events).toContain("disconnected");
    });

    test("cancels reconnect timer on disconnect()", async () => {
      const mockWs = new MockWebSocket();
      let wsInstances = 0;
      (globalThis as any).WebSocket = class {
        constructor() { wsInstances++; return mockWs; }
        static OPEN = MockWebSocket.OPEN;
      };
      const manager = new ConnectionManager({
        url: "ws://localhost:3000",
        reconnect: true,
        reconnectDelay: 200,
        maxReconnectDelay: 5000,
      });

      const connectPromise = manager.connect();
      mockWs.triggerOpen();
      await connectPromise;

      const instancesBeforeClose = wsInstances;
      mockWs.triggerClose(1006, "Abnormal closure");

      // Immediately cancel before timer fires
      manager.disconnect();

      // Wait longer than the delay to confirm no new connection was attempted
      await new Promise(r => setTimeout(r, 300));
      expect(wsInstances).toBe(instancesBeforeClose);
    });

    test("does NOT reconnect on intentional disconnect()", async () => {
      const mockWs = new MockWebSocket();
      (globalThis as any).WebSocket = class {
        constructor() { return mockWs; }
        static OPEN = MockWebSocket.OPEN;
      };
      const manager = new ConnectionManager({ url: "ws://localhost:3000", reconnect: true, reconnectDelay: 50 });

      const events: string[] = [];
      manager.on("reconnecting", () => events.push("reconnecting"));

      const connectPromise = manager.connect();
      mockWs.triggerOpen();
      await connectPromise;

      manager.disconnect();

      await new Promise(r => setTimeout(r, 100));
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
        const preCap = 1000 * Math.pow(2, attempt);
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

      // attempt=10 → preCap = 1000 * 1024 = 1,024,000 >> 5000
      const delay = manager._computeBackoffDelay(10);
      expect(delay).toBeLessThanOrEqual(5000);
    });

    test("uses default values when options not specified", () => {
      const manager = new ConnectionManager({ url: "ws://localhost:3000" });
      // attempt=0 → preCap = 1000 * 1 = 1000, jitter ±10%
      const delay = manager._computeBackoffDelay(0);
      expect(delay).toBeGreaterThanOrEqual(900);
      expect(delay).toBeLessThanOrEqual(1100);
    });
  });
});
