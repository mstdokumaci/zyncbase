import { describe, test, expect } from "bun:test";
import * as fc from "fast-check";
import { SubscriptionTracker } from "./subscriptions";
import type { StoreDelta, StoreSubscribe } from "./types";

/**
 * Property 9: StoreDelta routing to subscriptions
 * Validates: Requirements 3.6, 8.2
 */
describe("SubscriptionTracker", () => {
  test("Property 9: dispatching a StoreDelta invokes the registered callback exactly once with the delta ops", () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 1, max: 100000 }),
        (subId) => {
          const tracker = new SubscriptionTracker();

          const received: any[] = [];
          const callback = (value: any) => received.push(value);

          const params: Omit<StoreSubscribe, "id"> = {
            type: "StoreSubscribe",
            namespace: "public",
            collection: "users",
          };

          tracker.register(subId, {
            params,
            callbacks: [callback],
            projection: null, // store.subscribe style
          });

          const delta: StoreDelta = {
            type: "StoreDelta",
            subId,
            ops: [{ op: "set", path: ["name"], value: "Alice" }],
          };

          tracker.dispatch(delta);

          // Callback invoked exactly once with the delta's ops
          return received.length === 1 && received[0] === delta.ops;
        }
      ),
      { numRuns: 100 }
    );
  });

  test("Property 9: dispatching a StoreDelta for an unregistered subId does NOT invoke any callback", () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 1, max: 100000 }),
        fc.integer({ min: 100001, max: 200000 }),
        (registeredSubId, unregisteredSubId) => {
          const tracker = new SubscriptionTracker();

          const received: any[] = [];
          const callback = (value: any) => received.push(value);

          tracker.register(registeredSubId, {
            params: { type: "StoreSubscribe", namespace: "public", collection: "users" },
            callbacks: [callback],
            projection: null,
          });

          const delta: StoreDelta = {
            type: "StoreDelta",
            subId: unregisteredSubId,
            ops: [{ op: "set", path: ["name"], value: "Bob" }],
          };

          tracker.dispatch(delta);

          // No callback should be invoked for an unregistered subId
          return received.length === 0;
        }
      ),
      { numRuns: 100 }
    );
  });
});

/**
 * Property 10: Subscription replay on reconnect
 * Validates: Requirements 8.5
 */
describe("SubscriptionTracker - replayAll", () => {
    test("Property 11: replayAll(send) invokes send for all currently registered subscriptions", async () => {
      await fc.assert(
        fc.asyncProperty(
          fc.integer({ min: 1, max: 10 }),
          async (n) => {
            const tracker = new SubscriptionTracker();
            const collections = Array.from({ length: n }, (_, i) => `c${i}`);
            const subIds = Array.from({ length: n }, (_, i) => i + 1);

            for (let i = 0; i < n; i++) {
              const params: Omit<StoreSubscribe, "id"> = {
                type: "StoreSubscribe",
                namespace: "public",
                collection: collections[i],
              };
              tracker.register(subIds[i], {
                params,
                callbacks: [],
                projection: null,
              });
            }

            // Collect all params passed to send
            const sent: Omit<StoreSubscribe, "id">[] = [];
            await tracker.replayAll(async (params) => { sent.push(params); });

            // send must be called exactly N times (once per subscription)
            return sent.length === n;
          }
        ),
        { numRuns: 100 }
      );
    });
});
