// Subscription Tracker

import { joinFieldPath, unflatten } from "./path.js";
import type { JsonValue, StoreDelta, StoreSubscribe } from "./types.js";

// ─── Types ────────────────────────────────────────────────────────────────────

/** Projection info for store.listen registrations. */
export interface ListenProjection {
	/** The specific field to project from the record-level delta (e.g. "name" for "users.u1.name"). */
	field: string | null;
	/** Path depth of the original listen call (1 = collection, 2 = document, 3+ = field). */
	depth: number;
}

/** Client-side materialized view for store.subscribe() registrations. */
export interface MaterializedView {
	/** Current records keyed by document id. Values are unflattened. */
	records: Map<string, JsonValue>;
	/** Total-order comparator applied to every snapshot. Never null. */
	comparator: (a: JsonValue, b: JsonValue) => number;
}

/** A single registered subscription entry. */
export interface SubscriptionEntry {
	/** Original StoreSubscribe params — used for replay on reconnect. */
	params: Omit<StoreSubscribe, "id">;
	/** Registered callbacks to invoke when a delta arrives. */
	callbacks: Array<(value: JsonValue) => void>;
	/** Projection info; null for store.subscribe (collection-level) registrations. */
	projection: ListenProjection | null;
	/** Optional materialized view for collection-level subscriptions. */
	materializedView?: MaterializedView;
}

// ─── SubscriptionTracker ─────────────────────────────────────────────────────

export class SubscriptionTracker {
	private readonly subscriptions = new Map<number, SubscriptionEntry>();
	private readonly deltaQueue: StoreDelta[] = [];
	private pendingDeltas: StoreDelta[] = [];
	private flushScheduled = false;
	private connected = true;
	private debug = false;

	setDebug(debug: boolean): void {
		this.debug = debug;
	}

	/**
	 * Register a new subscription entry keyed by the server-assigned subId.
	 */
	register(subId: number, entry: SubscriptionEntry): void {
		this.subscriptions.set(subId, entry);
	}

	registerListen(
		subId: number,
		params: Omit<StoreSubscribe, "id">,
		callback: (value: JsonValue) => void,
		segments: string[],
	): void {
		this.register(subId, {
			params,
			callbacks: [callback],
			projection: createListenProjection(segments),
		});
	}

	registerCollection(
		subId: number,
		params: Omit<StoreSubscribe, "id">,
		callback: (results: JsonValue[]) => void,
		comparator?: (a: JsonValue, b: JsonValue) => number,
	): void {
		this.register(subId, {
			params,
			callbacks: [callback as (value: JsonValue) => void],
			projection: null,
			materializedView: {
				records: new Map(),
				comparator: comparator ?? createCreatedAtComparator(),
			},
		});
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
	 *
	 * Materialized-view (store.subscribe) deltas batch: ops apply to the
	 * pending buffer, callbacks fire once per event-loop tick with the current
	 * snapshot. Projection (store.listen) deltas dispatch synchronously.
	 */
	dispatch(delta: StoreDelta): void {
		if (!this.connected) {
			this.deltaQueue.push(delta);
			return;
		}
		const entry = this.subscriptions.get(delta.subId);
		if (entry?.materializedView) {
			this.pendingDeltas.push(delta);
			this.scheduleFlush();
			return;
		}
		this._dispatchDelta(delta);
	}

	/**
	 * Schedule one flush on the next event-loop tick; a burst of deltas
	 * within a tick shares one callback per subscription.
	 */
	private scheduleFlush(): void {
		if (this.flushScheduled) return;
		this.flushScheduled = true;
		setTimeout(() => {
			this.flushScheduled = false;
			this._flushPending();
		}, 0);
	}

	/**
	 * Apply all pending deltas (per subscription, in arrival order) and
	 * invoke each subscription's callbacks once with the current snapshot.
	 */
	private _flushPending(): void {
		const pending = this.pendingDeltas;
		this.pendingDeltas = [];
		if (pending.length === 0) return;

		if (this.debug) {
			console.log(`[SDK] Flushing ${pending.length} pending delta(s)`);
		}

		const bySub = new Map<number, StoreDelta[]>();
		for (const delta of pending) {
			const list = bySub.get(delta.subId);
			if (list) {
				list.push(delta);
			} else {
				bySub.set(delta.subId, [delta]);
			}
		}

		for (const [subId, deltas] of bySub) {
			const entry = this.subscriptions.get(subId);
			if (entry) {
				this._applyToSubscription(entry, deltas);
			}
		}
	}

	private _applyToSubscription(
		entry: SubscriptionEntry,
		deltas: StoreDelta[],
	): void {
		if (!entry.materializedView) return;
		for (const delta of deltas) {
			this._applyOpsToView(entry.materializedView, delta.ops);
		}
		const value = this._snapshotView(entry.materializedView);
		for (const cb of entry.callbacks) {
			try {
				cb(value);
			} catch (err) {
				console.error("[SDK] Subscription callback threw:", err);
			}
		}
	}

	dispatchInitialSnapshot(
		subId: number,
		segments: string[],
		value: JsonValue,
	): void {
		const delta = createInitialSnapshotDelta(subId, segments, value);
		if (delta.ops.length > 0) {
			this.dispatch(delta);
		}
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
	 * @param beforeDrain - Optional callback to run after remapping but before draining deltas.
	 */
	reconnect(
		oldToNew: Map<number, number>,
		beforeDrain?: (oldToNew: Map<number, number>) => void,
	): void {
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

		// Drop pre-reconnect deltas still in the pending buffer: an already
		// armed flush timer would otherwise apply them after the view clear.
		this.pendingDeltas = [];
		// Clear materialized views — they'll be re-populated from fresh snapshots
		this.clearMaterializedViews();

		this.connected = true;

		if (beforeDrain) {
			beforeDrain(oldToNew);
		}

		// Drain queued deltas — routed through dispatch so materialized views
		// batch them under the same per-tick flush semantics.
		const queued = this.deltaQueue.splice(0);
		for (const delta of queued) {
			this.dispatch(delta);
		}
	}

	/**
	 * Clear all materialized view records.
	 * Called before reconnect to prevent stale data.
	 */
	clearMaterializedViews(): void {
		for (const entry of this.subscriptions.values()) {
			if (entry.materializedView) {
				entry.materializedView.records.clear();
			}
		}
	}

	// ─── Private helpers ────────────────────────────────────────────────────────

	private _dispatchDelta(delta: StoreDelta): void {
		const entry = this.subscriptions.get(delta.subId);
		if (!entry) {
			console.warn(`[SDK] Received delta for unknown subId: ${delta.subId}`);
			return;
		}

		let value: JsonValue;

		if (entry.materializedView) {
			this._applyOpsToView(entry.materializedView, delta.ops);
			value = this._snapshotView(entry.materializedView);
		} else {
			value = this._project(delta, entry.projection);
		}

		if (this.debug) {
			console.log(
				`[SDK] Dispatching delta to listener (subId=${delta.subId}):`,
				JSON.stringify(value),
			);
		}

		for (const cb of entry.callbacks) {
			try {
				cb(value);
			} catch (err) {
				console.error("[SDK] Subscription callback threw:", err);
			}
		}
	}

	/**
	 * Apply SDK-side field projection for store.listen registrations.
	 */
	private _project(
		delta: StoreDelta,
		projection: ListenProjection | null,
	): JsonValue {
		if (projection === null) {
			// Fallback — should not normally be reached with materialized view in place
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
			const relativePath = op.path.slice(2);
			if (relativePath.length === 0) {
				const rootResult = this._handleRootOp(op);
				if (rootResult !== undefined) return rootResult;
				continue;
			}
			this._processRecordOp(op, flat, relativePath);
		}
		return unflatten(flat);
	}

	private _processRecordOp(
		op: StoreDelta["ops"][number],
		flat: Record<string, JsonValue>,
		relativePath: string[],
	): void {
		const key = joinFieldPath(...relativePath);
		flat[key] = op.op === "set" ? op.value : null;
	}

	private _handleRootOp(op: StoreDelta["ops"][number]): JsonValue | undefined {
		if (op.op === "remove") return null;
		if (op.op === "set") return op.value;
		return undefined;
	}

	private _getField(
		record: JsonValue,
		fieldPath: string,
	): JsonValue | undefined {
		const parts = fieldPath.split(".");
		let value: JsonValue | undefined = record;
		for (const part of parts) {
			if (value == null || typeof value !== "object" || Array.isArray(value))
				return undefined;
			value = (value as Record<string, JsonValue>)[part];
		}
		return value;
	}

	/**
	 * Apply delta ops to a materialized view.
	 * Root values arrive as fully decoded records ready for storage.
	 */
	private _applyOpsToView(
		view: MaterializedView,
		ops: StoreDelta["ops"],
	): void {
		for (const op of ops) {
			this._applyOpToView(view, op);
		}
	}

	private _applyOpToView(
		view: MaterializedView,
		op: StoreDelta["ops"][number],
	): void {
		const id = op.path[1] as string;

		if (op.op === "set") {
			this._handleSetOp(view, id, op);
		} else if (op.op === "remove") {
			this._handleRemoveOp(view, id);
		}
	}

	private _handleSetOp(
		view: MaterializedView,
		id: string,
		op: Extract<StoreDelta["ops"][number], { op: "set" }>,
	): void {
		// Map.set keeps insertion position for existing keys; ordered
		// queries sort at snapshot.
		view.records.set(id, op.value);
	}

	private _handleRemoveOp(view: MaterializedView, id: string): void {
		view.records.delete(id);
	}

	/**
	 * Snapshot array from the view; always sorted by the view's comparator.
	 */
	private _snapshotView(view: MaterializedView): JsonValue[] {
		const records = Array.from(view.records.values());
		records.sort(view.comparator);
		return records;
	}
}

/**
 * Default total order: numeric `created_at` ascending.
 */
export function createCreatedAtComparator(): (
	a: JsonValue,
	b: JsonValue,
) => number {
	return (a: JsonValue, b: JsonValue): number => {
		const ta = (a as Record<string, JsonValue>)?.created_at;
		const tb = (b as Record<string, JsonValue>)?.created_at;
		if (typeof ta === "number" && typeof tb === "number") {
			return ta < tb ? -1 : ta > tb ? 1 : 0;
		}
		return 0;
	};
}

export function createListenProjection(segments: string[]): ListenProjection {
	return {
		field: segments.length === 2 ? null : segments.slice(2).join("."),
		depth: segments.length,
	};
}

export function createInitialSnapshotDelta(
	subId: number,
	segments: string[],
	value: JsonValue,
): StoreDelta {
	const delta: StoreDelta = { type: "StoreDelta", subId, ops: [] };
	const collection = segments[0];

	if (Array.isArray(value)) {
		for (const item of value) {
			const op = createInitialSnapshotOp(collection, segments, item);
			if (op) delta.ops.push(op);
		}
	} else if (value !== null) {
		const op = createInitialSnapshotOp(collection, segments, value);
		if (op) delta.ops.push(op);
	}

	return delta;
}

function createInitialSnapshotOp(
	collection: string,
	segments: string[],
	item: JsonValue,
): { op: "set"; path: string[]; value: JsonValue } | null {
	if (item === null || typeof item !== "object" || Array.isArray(item)) {
		return null;
	}

	const value = item as Record<string, JsonValue>;
	const id =
		(value.id as string) || (segments.length > 1 ? segments[1] : undefined);
	if (!id) return null;

	return {
		op: "set",
		path: [collection, id],
		value,
	};
}
