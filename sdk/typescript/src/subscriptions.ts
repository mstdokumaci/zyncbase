// Subscription Tracker

import { unflatten } from "./store.js";
import type { JsonValue, StoreDelta, StoreSubscribe } from "./types.js";

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
	callbacks: Array<(value: JsonValue) => void>;
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
	async replayAll(
		send: (params: Omit<StoreSubscribe, "id">, subId: number) => Promise<void>,
	): Promise<void> {
		const promises: Promise<void>[] = [];
		for (const [subId, entry] of this.subscriptions.entries()) {
			promises.push(send(entry.params, subId));
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
		console.log(
			`[SDK] Dispatching delta to listener (subId=${delta.subId}):`,
			JSON.stringify(projected),
		);

		for (const cb of entry.callbacks) {
			cb(projected);
		}
	}

	/**
	 * Apply SDK-side field projection for store.listen registrations.
	 */
	private _project(
		delta: StoreDelta,
		projection: ListenProjection | null,
	): JsonValue {
		if (projection === null || projection.depth === 1) {
			// store.subscribe — deliver raw ops
			return delta.ops;
		}

		const record = this._reconstructRecord(delta.ops);

		if (projection.depth === 2 || projection.field === null) {
			// Document-level listen — return the unflattened record
			return record;
		}

		// depth 3+ — extract the specific nested field
		const field = this._getField(record, projection.field);
		return field !== undefined ? field : null;
	}

	private _reconstructRecord(ops: StoreDelta["ops"]): JsonValue {
		const flat: Record<string, JsonValue> = {};
		for (const op of ops) {
			// Relative path starting from the record root
			const relativePath = op.path.slice(2);

			if (relativePath.length === 0) {
				const rootResult = this._handleRootOp(op);
				if (rootResult !== undefined) return rootResult;
				continue;
			}

			const key = relativePath.join("__");
			flat[key] = op.op === "set" ? op.value : null;
		}

		// Unflatten to restore nested structure for the caller
		return unflatten(flat);
	}

	private _handleRootOp(op: StoreDelta["ops"][number]): JsonValue | undefined {
		if (op.op === "remove") return null;
		if (op.op === "set") {
			return op.value !== null &&
				typeof op.value === "object" &&
				!Array.isArray(op.value)
				? unflatten(op.value as Record<string, JsonValue>)
				: op.value;
		}
		return undefined;
	}

	private _getField(record: JsonValue, fieldPath: string): JsonValue | undefined {
		const parts = fieldPath.split(".");
		let value: JsonValue | undefined = record;
		for (const part of parts) {
			if (value == null || typeof value !== "object" || Array.isArray(value)) return undefined;
			value = (value as Record<string, JsonValue>)[part];
		}
		return value;
	}
}
