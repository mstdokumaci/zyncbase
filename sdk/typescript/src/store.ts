// Store API

import { ZyncBaseError, ErrorCodes } from "./errors.js";
import { normalizePath, encodeWirePath } from "./path.js";
import { generateUUIDv7 } from "./uuid.js";
import type { ConnectionManager } from "./connection.js";
import type { SubscriptionTracker } from "./subscriptions.js";
import type {
  Path,
  QueryOptions,
  BatchOperation,
  SubscriptionHandle,
  StoreSubscribe,
  StoreDelta,
} from "./types.js";

/**
 * Recursively flatten a nested object using `__` as the key separator.
 * Arrays are stored as-is (not flattened).
 *
 * Example:
 *   flatten({ a: { b: 1, c: 2 } }) → { "a__b": 1, "a__c": 2 }
 */
export function flatten(obj: Record<string, any>, prefix = ""): Record<string, any> {
  const result: Record<string, any> = {};
  for (const key of Object.keys(obj)) {
    const fullKey = prefix ? `${prefix}__${key}` : key;
    const value = obj[key];
    if (
      value !== null &&
      typeof value === "object" &&
      !Array.isArray(value)
    ) {
      const nested = flatten(value, fullKey);
      for (const nestedKey of Object.keys(nested)) {
        result[nestedKey] = nested[nestedKey];
      }
    } else {
      result[fullKey] = value;
    }
  }
  return result;
}

/**
 * Reconstruct a nested object from `__`-separated flat keys.
 *
 * Example:
 *   unflatten({ "a__b": 1, "a__c": 2 }) → { a: { b: 1, c: 2 } }
 */
export function unflatten(obj: Record<string, any>): Record<string, any> {
  const result: Record<string, any> = {};
  for (const key of Object.keys(obj)) {
    const parts = key.split("__");
    let current = result;
    for (let i = 0; i < parts.length - 1; i++) {
      const part = parts[i];
      if (current[part] === undefined || typeof current[part] !== "object" || Array.isArray(current[part])) {
        current[part] = {};
      }
      current = current[part];
    }
    current[parts[parts.length - 1]] = obj[key];
  }
  return result;
}

// ─── Operator codes ───────────────────────────────────────────────────────────

const OP_CODES: Record<string, number> = {
  eq: 0, ne: 1, gt: 2, lt: 3, gte: 4, lte: 5,
  contains: 6, startsWith: 7, endsWith: 8,
  in: 9, notIn: 10, isNull: 11, isNotNull: 12,
};

type WireCondition = [string, number] | [string, number, any];

/**
 * Encode a single condition object (e.g. { age: { gte: 18 } }) into wire tuples.
 * Nested field paths are flattened with `__`.
 */
function encodeConditionObject(
  obj: Record<string, any>,
  prefix = ""
): WireCondition[] {
  const conditions: WireCondition[] = [];
  for (const [key, val] of Object.entries(obj)) {
    const fieldKey = prefix ? `${prefix}__${key}` : key;
    if (val !== null && typeof val === "object" && !Array.isArray(val)) {
      // Check if this is an operator object (has known op keys)
      const opKeys = Object.keys(val).filter((k) => k in OP_CODES);
      if (opKeys.length > 0) {
        for (const op of opKeys) {
          const code = OP_CODES[op];
          if (op === "isNull" || op === "isNotNull") {
            conditions.push([fieldKey, code]);
          } else {
            conditions.push([fieldKey, code, val[op]]);
          }
        }
      } else {
        // Nested field object — recurse
        conditions.push(...encodeConditionObject(val, fieldKey));
      }
    }
  }
  return conditions;
}

/**
 * Encode SDK-side QueryOptions into wire-format fields for StoreQuery / StoreSubscribe.
 */
export function encodeQueryOptions(options: QueryOptions): {
  conditions?: WireCondition[];
  orConditions?: WireCondition[];
  orderBy?: [string, number];
  limit?: number;
  after?: string;
} {
  const result: ReturnType<typeof encodeQueryOptions> = {};

  if (options.where) {
    const { or, ...rest } = options.where as any;
    const conditions = encodeConditionObject(rest);
    if (conditions.length > 0) result.conditions = conditions;

    if (Array.isArray(or)) {
      const orConditions: WireCondition[] = [];
      for (const clause of or) {
        orConditions.push(...encodeConditionObject(clause));
      }
      if (orConditions.length > 0) result.orConditions = orConditions;
    }
  }

  if (options.orderBy) {
    const [field, dir] = Object.entries(options.orderBy)[0];
    result.orderBy = [field, dir === "desc" ? 1 : 0];
  }

  if (options.limit !== undefined) result.limit = options.limit;
  if (options.after !== undefined) result.after = options.after;

  return result;
}

// ─── StoreImpl ────────────────────────────────────────────────────────────────

export class StoreImpl {
  constructor(
    private readonly conn: ConnectionManager,
    private readonly tracker: SubscriptionTracker,
    private readonly emitError: (err: ZyncBaseError) => void = () => {},
  ) {}

  // ─── Writes ────────────────────────────────────────────────────────────────

  async set(path: Path, value: any): Promise<void> {
    const segments = normalizePath(path);
    if (segments.length === 1) {
      throw new ZyncBaseError("store.set requires a path of depth 2 or more", {
        code: ErrorCodes.INVALID_PATH,
        category: "client",
        retryable: false,
      });
    }

    // Flatten object values for depth-2 writes
    let wireValue = value;
    if (
      segments.length === 2 &&
      value !== null &&
      typeof value === "object" &&
      !Array.isArray(value)
    ) {
      wireValue = flatten(value);
    }
    const wirePath = encodeWirePath(segments);
    try {
      await this.conn.dispatch({ type: "StoreSet", path: wirePath, value: wireValue });
    } catch (err: any) {
      this.emitError?.(err);
      throw err;
    }
  }

  async remove(path: Path): Promise<void> {
    const segments = normalizePath(path);
    if (segments.length !== 2) {
      throw new ZyncBaseError("store.remove requires a path of depth 2 (collection + document id)", {
        code: ErrorCodes.INVALID_PATH,
        category: "client",
        retryable: false,
      });
    }

    const wirePath = encodeWirePath(segments);
    try {
      await this.conn.dispatch({ type: "StoreRemove", path: wirePath });
    } catch (err: any) {
      this.emitError?.(err);
      throw err;
    }
  }

  // ─── Create ────────────────────────────────────────────────────────────────

  async create(collection: string, value: any): Promise<string> {
    const uuid = generateUUIDv7();
    const segments = [collection, uuid];
    let wireValue = value;
    if (
      value !== null &&
      typeof value === "object" &&
      !Array.isArray(value)
    ) {
      wireValue = flatten(value);
    }
    const wirePath = encodeWirePath(segments);
    try {
      await this.conn.dispatch({ type: "StoreSet", path: wirePath, value: wireValue });
    } catch (err: any) {
      this.emitError?.(err);
      throw err;
    }
    return uuid;
  }

  async push(collection: string, value: any): Promise<string> {
    // For now, push is the same as create.
    return this.create(collection, value);
  }

  async update(path: Path, value: any): Promise<void> {
    // For now, update is synonymous with set (doc-level merging is handled by storage engine)
    return this.set(path, value);
  }

  // ─── Reads ─────────────────────────────────────────────────────────────────

  get(path: Path): Promise<any> {
    const segments = normalizePath(path);

    if (segments.length === 1) {
      // depth-1: query entire collection
      return this.conn.dispatch({
        type: "StoreQuery",
        collection: segments[0],
      }).then((ok) => {
        const rows: any[] = ok.value ?? [];
        return rows.map((row) =>
          row !== null && typeof row === "object" && !Array.isArray(row)
            ? unflatten(row)
            : row
        );
      }).catch((err) => {
        this.emitError?.(err);
        throw err;
      });
    }

    if (segments.length === 2) {
      // depth-2: query by id
      return this.conn.dispatch({
        type: "StoreQuery",
        collection: segments[0],
        conditions: [["id", 0, segments[1]]],
      }).then((ok) => {
        const rows: any[] = ok.value ?? [];
        if (rows.length === 0) return null;
        const row = rows[0];
        return row !== null && typeof row === "object" && !Array.isArray(row)
          ? unflatten(row)
          : row;
      });
    }

    // depth-3+: query by id, extract nested field
    return this.conn.dispatch({
      type: "StoreQuery",
      collection: segments[0],
      conditions: [["id", 0, segments[1]]],
    }).then((ok) => {
      const rows: any[] = ok.value ?? [];
      if (rows.length === 0) return undefined;
      const row = rows[0];
      const record = unflatten(rows[0]);
      
      let val = record;
      for (const part of segments.slice(2)) {
        if (val === null || typeof val !== "object" || !(part in val)) {
          throw new ZyncBaseError(`Field ${part} not found at path ${segments.join(".")}`, {
            code: ErrorCodes.FIELD_NOT_FOUND,
            category: "client",
            retryable: false,
          });
        }
        val = val[part];
      }
      return val;
    });
  }

  query(collection: string, options?: QueryOptions): Promise<any[] & { nextCursor: string | null }> {
    const encoded = options ? encodeQueryOptions(options) : {};
    return this.conn.dispatch({
      type: "StoreQuery",
      collection,
      ...encoded,
    }).then((ok) => {
      const rows: any[] = (ok.value ?? []).map((row: any) =>
        row !== null && typeof row === "object" && !Array.isArray(row)
          ? unflatten(row)
          : row
      );
      (rows as any).nextCursor = ok.nextCursor ?? null;
      return rows as any[] & { nextCursor: string | null };
    });
  }

  // ─── Batch ─────────────────────────────────────────────────────────────────

  batch(operations: BatchOperation[]): Promise<void> {
    if (operations.length > 500) {
      return Promise.reject(
        new ZyncBaseError("Batch exceeds maximum of 500 operations", {
          code: ErrorCodes.BATCH_TOO_LARGE,
          category: "client",
          retryable: false,
        })
      );
    }

    // Validate all paths first
    const wireOps: (["s", string[], any] | ["r", string[]])[] = [];
    for (const op of operations) {
      let segments: string[];
      try {
        segments = normalizePath(op.path);
      } catch (err) {
        return Promise.reject(err);
      }
      const wirePath = encodeWirePath(segments);
      if (op.op === "set") {
        let wireValue = op.value;
        if (
          segments.length === 2 &&
          wireValue !== null &&
          typeof wireValue === "object" &&
          !Array.isArray(wireValue)
        ) {
          wireValue = flatten(wireValue);
        }
        wireOps.push(["s", wirePath, wireValue]);
      } else {
        wireOps.push(["r", wirePath]);
      }
    }

    return this.conn.dispatch({
      type: "StoreBatch",
      ops: wireOps,
    }).then(() => undefined);
  }

  // ─── Subscriptions ─────────────────────────────────────────────────────────

  listen(path: Path, callback: (value: any) => void): () => void {
    const segments = normalizePath(path);

    let subscribeParams: Omit<StoreSubscribe, "id">;
    let projection: import("./subscriptions.js").ListenProjection;

    if (segments.length === 1) {
      // Collection-level listen
      subscribeParams = { 
        type: "StoreSubscribe", 
        namespace: this.conn.getStoreNamespace(),
        collection: segments[0] 
      };
      projection = { field: null, depth: 1 };
    } else {
      // depth-2+: subscribe to collection with id eq condition
      subscribeParams = {
        type: "StoreSubscribe",
        namespace: this.conn.getStoreNamespace(),
        collection: segments[0],
        conditions: [["id", 0, segments[1]]],
      };
      if (segments.length === 2) {
        projection = { field: null, depth: 2 };
      } else {
        // depth-3+: project specific field
        const fieldPath = segments.slice(2).join(".");
        projection = { field: fieldPath, depth: segments.length };
      }
    }

    // We need to send the subscribe and get back a subId.
    // listen() is synchronous (returns unlisten fn), but the subscribe is async.
    // We store a placeholder and update once the response arrives.
    let subId: number | null = null;
    let unlistenCalled = false;

    this.conn.dispatch({ ...subscribeParams }).then((ok) => {
      if (unlistenCalled) {
        if (ok.subId !== undefined) {
          this.conn.dispatch({ type: "StoreUnsubscribe", subId: ok.subId }).catch(() => {});
        }
        return;
      }

      subId = ok.subId ?? null;
      if (subId !== null) {
        this.tracker.register(subId, {
          params: subscribeParams,
          callbacks: [callback],
          projection,
        });

        // Feed initial snapshot if provided
        if (ok.value !== undefined) {
          const delta: StoreDelta = { type: "StoreDelta", subId, ops: [] };
          const collection = segments[0];
          if (Array.isArray(ok.value)) {
            for (const item of ok.value as any[]) {
              const id = item.id || segments[1]; // Use existing ID or from path
              delta.ops.push({ op: "set", path: [collection, id], value: item });
            }
          } else if (ok.value !== null) {
            const val = ok.value as any;
            const id = val.id || segments[1];
            delta.ops.push({ op: "set", path: [collection, id], value: val });
          }
          this.tracker.dispatch(delta);
        }
      }
    }).catch((err) => {
      this._emitError(err);
    });

    return () => {
      unlistenCalled = true;
      if (subId !== null) {
        this.tracker.unregister(subId);
        this.conn.dispatch({ type: "StoreUnsubscribe", subId }).catch(() => {});
        subId = null;
      }
    };
  }

  subscribe(
    collection: string,
    options: QueryOptions,
    callback: (results: any[]) => void
  ): SubscriptionHandle {
    const encoded = encodeQueryOptions(options);
    const subscribeParams: Omit<StoreSubscribe, "id"> = {
      type: "StoreSubscribe",
      namespace: this.conn.getStoreNamespace(),
      collection,
      ...encoded,
    };

    let subId: number | null = null;
    let nextCursor: string | null = null;
    let hasMore = false;
    let unsubscribeCalled = false;

    this.conn.dispatch({ ...subscribeParams }).then((ok) => {
      if (unsubscribeCalled) {
        if (ok.subId !== undefined) {
          this.conn.dispatch({ type: "StoreUnsubscribe", subId: ok.subId }).catch(() => {});
        }
        return;
      }
      subId = ok.subId ?? null;
      nextCursor = ok.nextCursor ?? null;
      hasMore = ok.hasMore ?? false;
      handle.hasMore = hasMore;

      if (subId !== null) {
        this.tracker.register(subId, {
          params: subscribeParams,
          callbacks: [callback],
          projection: null,
        });
      }
    }).catch(() => {});

    const handle: SubscriptionHandle = {
      hasMore: false,
      unsubscribe: () => {
        unsubscribeCalled = true;
        if (subId !== null) {
          this.tracker.unregister(subId);
          this.conn.dispatch({ type: "StoreUnsubscribe", subId }).catch(() => {});
          subId = null;
        }
      },
      loadMore: (): Promise<void> => {
        if (subId === null || nextCursor === null) {
          return Promise.resolve();
        }
        const cursor = nextCursor;
        return this.conn.dispatch({
          type: "StoreLoadMore",
          subId,
          nextCursor: cursor,
        }).then((ok) => {
          nextCursor = ok.nextCursor ?? null;
          hasMore = ok.hasMore ?? false;
          handle.hasMore = hasMore;
        });
      },
    };

    return handle;
  }

  // ─── Private helpers ───────────────────────────────────────────────────────

  private _emitError(err: unknown): void {
    if (err instanceof ZyncBaseError) {
      this.emitError(err);
    } else if (err instanceof Error) {
      this.emitError(new ZyncBaseError(err.message, {
        code: ErrorCodes.INTERNAL_ERROR,
        category: "server",
        retryable: true,
      }));
    }
  }
}
