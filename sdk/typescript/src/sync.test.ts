import { describe, test, expect, mock } from "bun:test";
import { StoreImpl } from "./store";
import { SubscriptionTracker } from "./subscriptions";
import type { ConnectionManager } from "./connection";
import type { OkResponse, StoreDelta } from "./types";

describe("Store Synchronization Integration", () => {
  test("should deliver initial snapshot and allow unlistening", async () => {
    const tracker = new SubscriptionTracker();
    let capturedDeltaHandler: ((delta: StoreDelta) => void) | null = null;

    // Mock ConnectionManager
    const mockConn = {
      dispatch: mock(async (msg: any) => {
        if (msg.type === "StoreSubscribe") {
          return {
            type: "ok",
            id: msg.id,
            subId: 101,
            value: [{ id: "1", title: "Initial Task" }],
          } as any;
        }
        return { type: "ok", id: msg.id } as any;
      }),
      onDelta: (handler: (delta: StoreDelta) => void) => {
        capturedDeltaHandler = handler;
      },
      getStoreNamespace: () => "public",
    } as unknown as ConnectionManager;

    const store = new StoreImpl(mockConn, tracker);
    
    // Wire the mock conn to the tracker just like ZyncBaseClient does
    mockConn.onDelta((delta) => tracker.dispatch(delta));

    let callCount = 0;
    let lastValue: any = null;

    // 1. Start listening
    const unlisten = store.listen(["tasks", "1"], (val) => {
      callCount++;
      lastValue = val;
    });

    // 1. Initial snapshot check
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(callCount).toBe(1);
    expect(lastValue.title).toBe("Initial Task");

    // 2. Test live update
    if (capturedDeltaHandler) {
      (capturedDeltaHandler as any)({
        type: "StoreDelta",
        subId: 101,
        ops: [{ op: "set", path: ["tasks", "1", "title"], value: "Live Update" }],
      });
    }
    expect(callCount).toBe(2);
    expect(lastValue.title).toBe("Live Update");

    unlisten();
  });

  test("should handle deep-path field retrieval with unflattening", async () => {
    const tracker = new SubscriptionTracker();
    const mockConn = {
      dispatch: mock(async () => ({
        type: "ok",
        id: 1,
        value: [{ id: "3", title: "Nested", must_be_complete__before: 100 }],
      })),
      onDelta: () => {},
      getStoreNamespace: () => "public",
    } as unknown as ConnectionManager;

    const store = new StoreImpl(mockConn, tracker);
    
    // Test retrieval of nested field
    const val = await store.get(["tasks", "3", "must_be_complete", "before"]);
    expect(val).toBe(100);
  });

  test("should throw FIELD_NOT_FOUND when deep field is missing", async () => {
    const tracker = new SubscriptionTracker();
    const mockConn = {
      dispatch: mock(async () => ({
        type: "ok",
        id: 1,
        value: [{ id: "1", title: "Exist" }],
      })),
      onDelta: () => {},
      getStoreNamespace: () => "public",
    } as unknown as ConnectionManager;

    const store = new StoreImpl(mockConn, tracker);
    
    try {
      await store.get(["tasks", "1", "non_existent"]);
      throw new Error("Should have thrown");
    } catch (err: any) {
      expect(err.code).toBe("FIELD_NOT_FOUND");
    }
  });

  test("should throw COLLECTION_NOT_FOUND when server returns it", async () => {
    const tracker = new SubscriptionTracker();
    const mockConn = {
      dispatch: mock(async () => {
        const err = new Error("Collection not found");
        (err as any).code = "COLLECTION_NOT_FOUND";
        throw err;
      }),
      onDelta: () => {},
      getStoreNamespace: () => "public",
    } as unknown as ConnectionManager;

    const store = new StoreImpl(mockConn, tracker);
    
    try {
      await store.get(["missing_table", "1"]);
      throw new Error("Should have thrown");
    } catch (err: any) {
      expect(err.code).toBe("COLLECTION_NOT_FOUND");
    }
  });

  test("should throw SCHEMA_VALIDATION_FAILED when server returns it on set", async () => {
    const tracker = new SubscriptionTracker();
    const mockConn = {
      dispatch: mock(async () => {
        const err = new Error("Schema validation failed");
        (err as any).code = "SCHEMA_VALIDATION_FAILED";
        throw err;
      }),
      onDelta: () => {},
      getStoreNamespace: () => "public",
    } as unknown as ConnectionManager;

    const store = new StoreImpl(mockConn, tracker);
    
    try {
      await store.set(["tasks", "1", "title"], 12345);
      throw new Error("Should have thrown");
    } catch (err: any) {
      expect(err.code).toBe("SCHEMA_VALIDATION_FAILED");
    }
  });
});

describe("Store Listen Reconstruction", () => {
  test("should unflatten initial snapshot with complex flattened keys", async () => {
    const tracker = new SubscriptionTracker();
    const mockConn = {
      dispatch: mock(async (msg: any) => ({
        type: "ok",
        id: msg.id,
        subId: 202,
        value: [{ id: "2", title: "Complex Task", "meta__author": "Mustafa", "meta__priority": 1 }],
      })),
      onDelta: () => {},
      getStoreNamespace: () => "public",
    } as unknown as ConnectionManager;

    const store = new StoreImpl(mockConn, tracker);
    let captured: any = null;

    store.listen(["tasks", "2"], (val) => {
      captured = val;
    });

    // Wait for async dispatch
    await new Promise((resolve) => setTimeout(resolve, 10));

    expect(captured).not.toBeNull();
    expect(captured.title).toBe("Complex Task");
    expect(captured.meta).toBeDefined();
    expect(captured.meta.author).toBe("Mustafa");
    expect(captured.meta.priority).toBe(1);
  });
});
