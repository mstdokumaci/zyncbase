// Subscription Tracker

import { unflatten } from "./path.js";
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
	/** Source of truth for sorted order. Kept in sync with records Map. */
	sortedList: JsonValue[];
	/** Collection name — needed to extract id from delta op paths. */
	collection: string;
	/** Comparator for maintaining orderBy sort. Null = no ordering. */
	comparator: ((a: JsonValue, b: JsonValue) => number) | null;
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

		// Clear materialized views — they'll be re-populated from fresh snapshots
		this.clearMaterializedViews();

		this.connected = true;

		if (beforeDrain) {
			beforeDrain(oldToNew);
		}

		// Drain queued deltas
		const queued = this.deltaQueue.splice(0);
		for (const delta of queued) {
			this._dispatchDelta(delta);
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
				entry.materializedView.sortedList.length = 0;
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
			cb(value);
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
		const key = relativePath.join("__");
		flat[key] = op.op === "set" ? op.value : null;
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
	 * Values arrive as flat string-keyed maps (e.g. { "address__city": "NYC" })
	 * and are unflattened before storage.
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
		const record =
			op.value !== null &&
			typeof op.value === "object" &&
			!Array.isArray(op.value)
				? unflatten(op.value as Record<string, JsonValue>)
				: op.value;

		if (record && typeof record === "object" && !Array.isArray(record)) {
			(record as Record<string, JsonValue>).id = id;
		}

		const oldRecord = view.records.get(id);

		if (view.comparator === null) {
			this._updateSortedListNoOrder(view, record, oldRecord);
		} else {
			this._updateSortedListWithOrder(view, record, oldRecord, view.comparator);
		}

		view.records.set(id, record);
	}

	private _updateSortedListNoOrder(
		view: MaterializedView,
		record: JsonValue,
		oldRecord: JsonValue | undefined,
	): void {
		if (oldRecord !== undefined) {
			const idx = view.sortedList.indexOf(oldRecord);
			if (idx !== -1) {
				view.sortedList.splice(idx, 1, record);
				return;
			}
		}
		view.sortedList.push(record);
	}

	private _updateSortedListWithOrder(
		view: MaterializedView,
		record: JsonValue,
		oldRecord: JsonValue | undefined,
		comparator: (a: JsonValue, b: JsonValue) => number,
	): void {
		if (oldRecord !== undefined) {
			const oldIdx = view.sortedList.indexOf(oldRecord);
			if (oldIdx !== -1) view.sortedList.splice(oldIdx, 1);
		}
		const newIdx = this._binarySearchInsertIndex(
			view.sortedList,
			record,
			comparator,
		);
		view.sortedList.splice(newIdx, 0, record);
	}

	private _handleRemoveOp(view: MaterializedView, id: string): void {
		const oldRecord = view.records.get(id);
		if (oldRecord !== undefined) {
			const idx = view.sortedList.indexOf(oldRecord);
			if (idx !== -1) view.sortedList.splice(idx, 1);
		}
		view.records.delete(id);
	}

	/**
	 * Create a sorted snapshot array from the materialized view.
	 */
	private _snapshotView(view: MaterializedView): JsonValue[] {
		return [...view.sortedList];
	}

	/**
	 * Find insertion index for stable sort (O(log N)).
	 */
	private _binarySearchInsertIndex(
		list: JsonValue[],
		item: JsonValue,
		comparator: (a: JsonValue, b: JsonValue) => number,
	): number {
		let low = 0;
		let high = list.length;
		while (low < high) {
			const mid = (low + high) >>> 1;
			// <= 0 ensures we insert AFTER equal elements (Stable Sort)
			if (comparator(list[mid], item) <= 0) {
				low = mid + 1;
			} else {
				high = mid;
			}
		}
		return low;
	}
}

/**
 * Build a sort comparator from QueryOptions.orderBy.
 * Returns null if no ordering is specified.
 */
export function buildComparator(
	orderBy?: Record<string, "asc" | "desc">,
): ((a: JsonValue, b: JsonValue) => number) | null {
	if (!orderBy) return null;
	const entries = Object.entries(orderBy);
	if (entries.length === 0) return null;

	return (a: JsonValue, b: JsonValue): number => {
		for (const [field, dir] of entries) {
			const diff = compareFields(a, b, field, dir);
			if (diff !== 0) return diff;
		}
		return 0;
	};
}

function compareFields(
	a: JsonValue,
	b: JsonValue,
	field: string,
	dir: "asc" | "desc",
): number {
	const mult = dir === "desc" ? -1 : 1;
	const va = getNestedValue(a, field);
	const vb = getNestedValue(b, field);

	if (va === vb) return 0;
	if (va == null) return 1;
	if (vb == null) return -1;
	if (va < vb) return -1 * mult;
	if (va > vb) return 1 * mult;
	return 0;
}

function getNestedValue(obj: JsonValue, path: string): JsonValue | undefined {
	const parts = path.split(".");
	let current: JsonValue | undefined = obj;
	for (const part of parts) {
		if (
			current == null ||
			typeof current !== "object" ||
			Array.isArray(current)
		)
			return undefined;
		current = (current as Record<string, JsonValue>)[part];
	}
	return current;
}
