// Subscription Tracker

import { unflatten } from "./store.js";
import type { StoreDelta, StoreSubscribe } from "./types.js";

// ─── Types ────────────────────────────────────────────────────────────────────

/** Projection info for store.listen registrations. */
export interface ListenProjection {
  /** The specific field to project from the record-level delta (e.g. "name" for "users.u1.name"). */
  field: string | null;
  /** Path depth of the original listen call (1 = collection, 2 = document, 3+ = field). */
  depth: number;
}

/** A single registered subscription entry. */
export interface SubscriptionEntry {
  /** Original StoreSubscribe params — used for replay on reconnect. */
  params: Omit<StoreSubscribe, "id">;
  /** Registered callbacks to invoke when a delta arrives. */
  callbacks: Array<(value: any) => void>;
  /** Projection info; null for store.subscribe (collection-level) registrations. */
  projection: ListenProjection | null;
}

// ─── SubscriptionTracker ─────────────────────────────────────────────────────

export class SubscriptionTracker {
  private readonly subscriptions = new Map<number, SubscriptionEntry>();
  private readonly deltaQueue: StoreDelta[] = [];
  private connected = true;

  /**
   * Register a new subscription entry keyed by the server-assigned subId.
   */
  register(subId: number, entry: SubscriptionEntry): void {
    this.subscriptions.set(subId, entry);
  }

  /**
   * Remove a subscription entry by subId.
   */
  unregister(subId: number): void {
    this.subscriptions.delete(subId);
  }

  /**
   * Look up a subscription entry by subId.
   */
  get(subId: number): SubscriptionEntry | undefined {
    return this.subscriptions.get(subId);
  }

  /**
   * Returns all active subIds (for replay / unsubscribe on disconnect).
   */
  allSubIds(): number[] {
    return Array.from(this.subscriptions.keys());
  }

  /**
   * Mark the tracker as disconnected — incoming deltas will be queued.
   */
  setDisconnected(): void {
    this.connected = false;
  }

  /**
   * Dispatch a StoreDelta to the appropriate subscription callbacks.
   * If disconnected, the delta is queued for later delivery.
   */
  dispatch(delta: StoreDelta): void {
    if (!this.connected) {
      this.deltaQueue.push(delta);
      return;
    }
    this._dispatchDelta(delta);
  }

  /**
   * Re-send all active StoreSubscribe messages via the provided send function.
   * Called on reconnect. The send function receives the params (without id —
   * the caller is responsible for assigning a fresh msg_id).
   */
  async replayAll(send: (params: Omit<StoreSubscribe, "id">) => Promise<void>): Promise<void> {
    const promises: Promise<void>[] = [];
    for (const entry of this.subscriptions.values()) {
      promises.push(send(entry.params));
    }
    await Promise.all(promises);
  }

  /**
   * Mark the tracker as reconnected, update subId mappings from the replay
   * responses, then drain any queued deltas in order.
   *
   * @param oldToNew - Map from old subId → new server-assigned subId after replay.
   */
  reconnect(oldToNew: Map<number, number>): void {
    // Remap entries to new subIds
    const remapped = new Map<number, SubscriptionEntry>();
    for (const [oldId, entry] of this.subscriptions.entries()) {
      const newId = oldToNew.get(oldId);
      if (newId !== undefined) {
        remapped.set(newId, entry);
      } else {
        // Keep old entry if no new mapping provided (shouldn't happen in normal flow)
        remapped.set(oldId, entry);
      }
    }
    this.subscriptions.clear();
    for (const [id, entry] of remapped.entries()) {
      this.subscriptions.set(id, entry);
    }

    this.connected = true;

    // Drain queued deltas
    const queued = this.deltaQueue.splice(0);
    for (const delta of queued) {
      this._dispatchDelta(delta);
    }
  }

  // ─── Private helpers ────────────────────────────────────────────────────────

  private _dispatchDelta(delta: StoreDelta): void {
    const entry = this.subscriptions.get(delta.subId);
    if (!entry) {
      console.warn(`[SDK] Received delta for unknown subId: ${delta.subId}`);
      return;
    }

    const projected = this._project(delta, entry.projection);
    console.log(`[SDK] Dispatching delta to listener (subId=${delta.subId}):`, JSON.stringify(projected));

    for (const cb of entry.callbacks) {
      cb(projected);
    }
  }

  /**
   * Apply SDK-side field projection for store.listen registrations.
   *
   * Delta op paths from the server are wire-encoded: the field segment is a
   * single "__"-joined string (e.g. ["address__city"]). We reconstruct a flat
   * record from those keys, then unflatten it before returning to the caller.
   *
   * - depth 1 (collection): pass the full ops array as-is.
   * - depth 2 (document): reconstruct + unflatten the record.
   * - depth 3+ (field): reconstruct + unflatten, then extract the specific field.
   *
   * For store.subscribe (projection === null): pass the full ops array as-is.
   */
  private _project(delta: StoreDelta, projection: ListenProjection | null): any {
    if (projection === null) {
      // store.subscribe — deliver raw ops
      return delta.ops;
    }

    const { depth, field } = projection;

    if (depth === 1) {
      // Collection-level listen — deliver raw ops
      return delta.ops;
    }

    // depth 2+ — reconstruct record state from delta ops.
    // Server sends full paths: ["table", "doc_id", "field", "subfield"].
    // We need to slice off the first two segments to get the record-relative path.
    const flat: Record<string, any> = {};
    for (const op of delta.ops) {
      // Relative path starting from the record root
      const relativePath = op.path.slice(2);
      
      if (relativePath.length === 0) {
        // Whole document update
        if (op.op === "set") {
          return (op.value !== null && typeof op.value === "object" && !Array.isArray(op.value))
            ? unflatten(op.value)
            : op.value;
        }
        if (op.op === "remove") return null;
      }

      const key = relativePath.join("__");
      if (op.op === "set") {
        flat[key] = op.value;
      } else if (op.op === "remove") {
        flat[key] = undefined;
      }
    }

    // Unflatten to restore nested structure for the caller
    const record = unflatten(flat);

    if (depth === 2 || field === null) {
      // Document-level listen — return the unflattened record
      return record;
    }

    // depth 3+ — extract the specific nested field
    // `field` is the dot-notation field path from the original listen call (e.g. "address.city")
    const fieldParts = field.split(".");
    let value: any = record;
    for (const part of fieldParts) {
      if (value == null || typeof value !== "object") return undefined;
      value = value[part];
    }
    return value;
  }
}
