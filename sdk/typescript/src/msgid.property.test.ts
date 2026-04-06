import { describe, test } from "bun:test";
import * as fc from "fast-check";
import { decode } from "@msgpack/msgpack";
import { ConnectionManager } from "./connection";
import type { ClientOptions } from "./types";

/**
 * Property 4: msg_id monotonicity and uniqueness
 * Validates: Requirements 3.3
 *
 * For any sequence of N dispatched requests (N ≥ 2), the assigned msg_id values
 * SHALL be strictly increasing integers with no duplicates.
 */

/** A MockWebSocket that triggers open immediately and captures sent messages. */
class MockWebSocket {
  static readonly OPEN = 1;
  static readonly CLOSED = 3;

  binaryType: string = "arraybuffer";
  readyState: number = 1; // OPEN
  sentMessages: Uint8Array[] = [];

  onopen: (() => void) | null = null;
  onclose: ((event: any) => void) | null = null;
  onerror: ((event: any) => void) | null = null;
  onmessage: ((event: any) => void) | null = null;

  constructor(_url: string) {
    // Trigger open asynchronously (next microtask)
    Promise.resolve().then(() => {
      if (this.onopen) this.onopen();
    });
  }

  send(data: ArrayBuffer | Uint8Array): void {
    const bytes = data instanceof ArrayBuffer ? new Uint8Array(data) : data;
    this.sentMessages.push(bytes);
  }

  close(): void {
    this.readyState = 3; // CLOSED
  }
}

describe("ConnectionManager", () => {
  test("Property 4: msg_id values are strictly increasing integers with no duplicates", async () => {
    await fc.assert(
      fc.asyncProperty(
        fc.integer({ min: 2, max: 100 }),
        async (n) => {
          // Install mock WebSocket globally
          const originalWebSocket = (globalThis as any).WebSocket;
          (globalThis as any).WebSocket = MockWebSocket;

          const options: ClientOptions = {
            url: "ws://localhost:9999",
            reconnect: false,
          };

          const manager = new ConnectionManager(options);
          await manager.connect();

          // Dispatch N messages (they'll be pending since no responses come)
          const dispatchPromises: Promise<any>[] = [];
          for (let i = 0; i < n; i++) {
            dispatchPromises.push(
              manager.dispatch({ type: "StoreQuery", collection: "test" }).catch(() => {
                // Ignore rejections from disconnect cleanup
              })
            );
          }

          // Collect the sent messages from the mock WebSocket
          const mockWs = (manager as any).ws as MockWebSocket;
          const sentMessages = mockWs.sentMessages;

          // Decode each sent Uint8Array to extract the id field
          const ids: number[] = sentMessages.map((bytes) => {
            const decoded = decode(bytes) as Record<string, any>;
            return decoded.id as number;
          });

          // Clean up
          manager.disconnect();
          (globalThis as any).WebSocket = originalWebSocket;

          // Assert we got exactly N ids
          if (ids.length !== n) return false;

          // Assert ids are [1, 2, 3, ..., N] — strictly increasing, no duplicates
          for (let i = 0; i < ids.length; i++) {
            if (ids[i] !== i + 1) return false;
          }

          // Double-check uniqueness via Set
          const unique = new Set(ids);
          if (unique.size !== ids.length) return false;

          return true;
        }
      ),
      { numRuns: 100 }
    );
  });
});
