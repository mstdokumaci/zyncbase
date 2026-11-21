import type { RecordMatcher } from "./filter_eval.js";
import { type OverlayKeys, PendingWrites } from "./optimistic.js";
import { fieldPathToFlat, getDeepProperty, unflatten } from "./path.js";
import type { JsonValue, StoreDelta, StoreSubscribe } from "./types.js";

// ─── Types ────────────────────────────────────────────────────────────────────

/** Projection info for store.listen registrations. */
export interface ListenProjection {
	/** The specific field to project from the record-level delta (e.g. "name" for "users.u1.name"). */
	field: string | null;
}

/** Client-side materialized view for store.subscribe() registrations. */
export interface MaterializedView {
	/** Server records keyed by document id. Values are unflattened. */
	records: Map<string, JsonValue>;
	/** Total-order comparator applied to every snapshot. Never null. */
	comparator: (a: JsonValue, b: JsonValue) => number;
	/** The view's `where`; decides membership of locally overlaid records. */
	matches: RecordMatcher;
}

/** Second argument of every subscription and listen callback. */
export interface DeliveryMeta {
	/** Views: ids of delivered rows with a pending local write. Listens: whether the document has one. */
	pending: ReadonlySet<string> | boolean;
}

export type DeliveryCallback = (value: JsonValue, meta: DeliveryMeta) => void;

/** A single registered subscription entry. */
export interface SubscriptionEntry {
	/** Original StoreSubscribe params — used for replay on reconnect. */
	params: Omit<StoreSubscribe, "id">;
	/** Collection the entry reads. */
	collection: string;
	/** Registered callbacks to invoke when a delta arrives. */
	callbacks: DeliveryCallback[];
	/** Projection info; null for store.subscribe (collection-level) registrations. */
	projection: ListenProjection | null;
	/** Optional materialized view for collection-level subscriptions. */
	materializedView?: MaterializedView;
	/** Listen only: the watched document id. */
	docId?: string;
	/** Listen only: the latest server record; null when the document is absent. */
	serverRecord?: JsonValue;
	/** Updates the caller's handle when a reconnect remaps the server subId. */
	onRemap?: (newSubId: number) => void;
	/** Private suppression baseline: an isolated copy of the last value. */
	lastValue?: JsonValue;
	/** Last value delivered to callbacks — what `getSnapshot()` returns. */
	deliveredValue?: JsonValue;
	/** Pending marker delivered with `deliveredValue`. */
	deliveredPending?: ReadonlySet<string> | boolean;
	/** Bumped by each delivery so a nested one supersedes an outer loop. */
	deliveryRevision?: number;
}

export const NO_PENDING: ReadonlySet<string> = new Set();

// ─── SubscriptionTracker ─────────────────────────────────────────────────────

export class SubscriptionTracker {
	/** Local writes shown before they commit. */
	readonly pending = new PendingWrites();
	private readonly subscriptions = new Map<number, SubscriptionEntry>();
	private readonly deltaQueue: StoreDelta[] = [];
	private pendingDeltas: StoreDelta[] = [];
	/** Subscribes awaiting their ack; their subIds are not known yet. */
	private establishing = 0;
	/** Deltas for unknown subIds that arrived while a subscribe was in flight. */
	private earlyDeltas: StoreDelta[] = [];
	private flushScheduled = false;
	private connected = true;
	private debug = false;
	/** Latest `updated_at` seen or issued, in microseconds. */
	private clock = 0;

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
	 * Whether there are any active subscriptions.
	 */
	hasSubscriptions(): boolean {
		return this.subscriptions.size > 0;
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
	 * A timestamp for a local write: after every server timestamp seen, so a
	 * local create sorts last in the default order, as it will on the server.
	 */
	provisionalTime(): number {
		this.clock = Math.max(Date.now() * 1000, this.clock + 1);
		return this.clock;
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
		if (!entry && this.establishing > 0) {
			// The server registers a subscription before acking it, so its
			// first deltas can precede the ack that reveals the subId.
			this.earlyDeltas.push(delta);
			return;
		}
		if (entry?.materializedView) {
			this.pendingDeltas.push(delta);
			this.scheduleFlush();
			return;
		}
		this._dispatchDelta(delta);
	}

	/** A subscribe is in flight; hold deltas for subIds not registered yet. */
	beginEstablish(): void {
		this.establishing++;
	}

	/** A subscribe settled; with none left in flight, unclaimed deltas are stale. */
	endEstablish(): void {
		this.establishing--;
		if (this.establishing === 0) this.earlyDeltas = [];
	}

	/**
	 * Apply the deltas `subId` received before its ack, in arrival order,
	 * after its initial snapshot. Deltas carry whole records, so replaying one
	 * the snapshot already contains converges.
	 */
	replayEarlyDeltas(subId: number): void {
		const early = this.earlyDeltas.filter((delta) => delta.subId === subId);
		if (early.length === 0) return;
		this.earlyDeltas = this.earlyDeltas.filter(
			(delta) => delta.subId !== subId,
		);
		for (const delta of early) this.dispatch(delta);
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
	 * Deliver pending deltas now instead of on the next tick. A resolved
	 * write calls this so its deltas, which arrive first, are already visible.
	 */
	flushNow(): void {
		this._flushPending();
	}

	/**
	 * Re-deliver the views and listens that show any of `keys` after a local
	 * write is added or settles. Views update incrementally: only the
	 * changed rows move, by binary insertion.
	 */
	refresh(keys: OverlayKeys): void {
		for (const entry of this.subscriptions.values()) {
			const ids = keys.get(entry.collection);
			if (ids === undefined) continue;
			if (entry.materializedView) {
				this._refreshView(entry, ids);
			} else if (entry.docId !== undefined && ids.has(entry.docId)) {
				this._refreshListen(entry);
			}
		}
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
		let changed = false;
		for (const delta of deltas) {
			changed =
				this._applyOpsToView(entry.materializedView, delta.ops) || changed;
		}
		if (changed) this._deliverSnapshot(entry);
	}

	dispatchInitialSnapshot(
		subId: number,
		segments: string[],
		value: JsonValue,
	): void {
		const delta = createInitialSnapshotDelta(subId, segments, value);
		if (delta.ops.length > 0) {
			this.dispatch(delta);
			return;
		}
		const entry = this.subscriptions.get(subId);
		if (entry === undefined) return;
		if (!entry.materializedView) {
			// The listened document does not exist; a local create can still show.
			entry.serverRecord = null;
			this._refreshListen(entry);
			return;
		}
		// An acknowledged empty collection (value: []) produces no ops. Deliver
		// the empty snapshot so subscribers leave their loading state; the
		// deliveredValue guard keeps an empty loadMore page from re-delivering
		// an existing view.
		if (entry.deliveredValue === undefined) this._deliverSnapshot(entry);
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
				// Keep each caller's handle pointing at the live server subId.
				entry.onRemap?.(newId);
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
	private clearMaterializedViews(): void {
		for (const entry of this.subscriptions.values()) {
			if (entry.materializedView) {
				entry.materializedView.records.clear();
				// The replay that follows is a fresh snapshot: clear the delivered
				// baseline so an empty replay reaches subscribers instead of being
				// suppressed like a duplicate empty loadMore page.
				entry.lastValue = undefined;
				entry.deliveredValue = undefined;
				entry.deliveredPending = undefined;
			}
		}
	}

	// ─── Private helpers ────────────────────────────────────────────────────────

	/** Listen deltas: the latest server record, with local writes applied. */
	private _dispatchDelta(delta: StoreDelta): void {
		const entry = this.subscriptions.get(delta.subId);
		if (!entry) {
			console.warn(`[SDK] Received delta for unknown subId: ${delta.subId}`);
			return;
		}

		entry.serverRecord = this._reconstructRecord(delta.ops);
		this._observeTime(entry.serverRecord);
		const pending = this._listenPending(entry);
		const value = this._listenValue(entry, pending);

		// Field projections extract one value out of each whole pushed record;
		// sibling or system-field writes must not re-fire them. Scalars compare
		// by identity, objects by content. Document-level listens keep baseline
		// semantics: an updated record is delivered.
		if (
			entry.projection?.field != null &&
			entry.lastValue !== undefined &&
			pending === entry.deliveredPending &&
			valuesEqual(value, entry.lastValue)
		) {
			return;
		}

		if (this.debug) {
			console.log(
				`[SDK] Dispatching delta to listener (subId=${delta.subId}):`,
				JSON.stringify(value),
			);
		}
		this._deliver(entry, value, pending);
	}

	private _refreshListen(entry: SubscriptionEntry): void {
		if (entry.serverRecord === undefined) return;
		const pending = this._listenPending(entry);
		const value = this._listenValue(entry, pending);
		const unchanged =
			entry.deliveredValue !== undefined &&
			pending === entry.deliveredPending &&
			valuesEqual(value, entry.lastValue as JsonValue);
		if (!unchanged) this._deliver(entry, value, pending);
	}

	private _listenPending(entry: SubscriptionEntry): boolean {
		return (
			entry.docId !== undefined &&
			this.pending.has(entry.collection, entry.docId)
		);
	}

	private _listenValue(entry: SubscriptionEntry, pending: boolean): JsonValue {
		const server = entry.serverRecord ?? null;
		const record = pending
			? this.pending.apply(entry.collection, entry.docId as string, server)
			: server;
		const field = entry.projection?.field;
		if (field == null) return record;
		return getDeepProperty(record, field.split(".")) ?? null;
	}

	private _deliverSnapshot(entry: SubscriptionEntry): void {
		const { rows, pending } = this._snapshotView(entry);
		this._deliver(entry, rows, pending);
	}

	/** Deliver `value` with its pending marker to every callback of `entry`. */
	private _deliver(
		entry: SubscriptionEntry,
		value: JsonValue,
		pending: ReadonlySet<string> | boolean,
	): void {
		// Suppression compares against lastValue; keep an isolated copy so a
		// callback mutating the delivered value cannot corrupt the baseline.
		const revision = (entry.deliveryRevision ?? 0) + 1;
		entry.deliveryRevision = revision;
		entry.lastValue =
			entry.projection?.field != null ? cloneValue(value) : value;
		entry.deliveredValue = value;
		entry.deliveredPending = pending;
		const meta: DeliveryMeta = { pending };
		for (const cb of entry.callbacks) {
			try {
				cb(value, meta);
			} catch (err) {
				console.error("[SDK] Subscription callback threw:", err);
			}
			if (entry.deliveryRevision !== revision) return;
		}
	}

	private _applyRecordOp(
		flat: Record<string, JsonValue>,
		op: StoreDelta["ops"][number],
	): { returned: boolean; value?: JsonValue } {
		const relativeField = op.path.length === 3 ? op.path[2] : undefined;
		if (relativeField === undefined) {
			if (op.op === "remove") return { returned: true, value: null };
			if (op.op === "set") return { returned: true, value: op.value };
			return { returned: false };
		}
		flat[fieldPathToFlat(relativeField)] = op.op === "set" ? op.value : null;
		return { returned: false };
	}

	private _reconstructRecord(ops: StoreDelta["ops"]): JsonValue {
		const flat: Record<string, JsonValue> = {};
		for (const op of ops) {
			const result = this._applyRecordOp(flat, op);
			if (result.returned) return result.value as JsonValue;
		}
		return unflatten(flat);
	}

	/**
	 * Apply delta ops to a materialized view.
	 * Root values arrive as fully decoded records ready for storage.
	 * Returns false when the ops changed nothing.
	 */
	private _applyOpsToView(
		view: MaterializedView,
		ops: StoreDelta["ops"],
	): boolean {
		let changed = false;
		for (const op of ops) {
			const id = op.path[1] as string;
			if (op.op === "set") {
				view.records.set(id, op.value);
				this._observeTime(op.value);
				changed = true;
			} else if (view.records.delete(id)) {
				changed = true;
			}
		}
		return changed;
	}

	private _observeTime(record: JsonValue | undefined): void {
		const time = isPlainRecord(record) ? record.updated_at : undefined;
		if (typeof time === "number" && time > this.clock) this.clock = time;
	}

	/**
	 * Every row of the view, local writes applied, sorted by its comparator,
	 * with the ids of rows that have a pending local write.
	 */
	private _snapshotView(entry: SubscriptionEntry): {
		rows: JsonValue[];
		pending: ReadonlySet<string>;
	} {
		const view = entry.materializedView as MaterializedView;
		if (!this.pending.touches(entry.collection)) {
			const rows = Array.from(view.records.values());
			rows.sort(view.comparator);
			return { rows, pending: NO_PENDING };
		}
		const rows: JsonValue[] = [];
		const pending = new Set<string>();
		const add = (id: string, row: JsonValue | null): void => {
			if (row === null) return;
			rows.push(row);
			if (this.pending.has(entry.collection, id)) pending.add(id);
		};
		for (const [id, record] of view.records) {
			add(
				id,
				this.pending.has(entry.collection, id)
					? this._viewRow(entry, id)
					: record,
			);
		}
		for (const id of this.pending.ids(entry.collection)) {
			if (!view.records.has(id)) add(id, this._viewRow(entry, id));
		}
		rows.sort(view.comparator);
		return { rows, pending: pending.size === 0 ? NO_PENDING : pending };
	}

	/** Incremental local update: move only the rows of `ids`. */
	private _refreshView(
		entry: SubscriptionEntry,
		ids: ReadonlySet<string>,
	): void {
		const view = entry.materializedView as MaterializedView;
		const current = entry.deliveredValue as JsonValue[] | undefined;
		if (current === undefined) return;
		const before = (entry.deliveredPending ??
			NO_PENDING) as ReadonlySet<string>;
		let rows: JsonValue[] | null = null;
		let pending: Set<string> | null = null;
		for (const id of ids) {
			const next = this._viewRow(entry, id);
			rows = withRow(current, rows, view.comparator, id, next);
			const isPending = next !== null && this.pending.has(entry.collection, id);
			if (isPending !== before.has(id)) {
				pending = toggle(pending ?? new Set(before), id, isPending);
			}
		}
		if (rows !== null || pending !== null) {
			this._deliver(entry, rows ?? current, pending ?? before);
		}
	}

	/**
	 * The row `id` shows in a view, or null when it shows none: the server
	 * record, or with pending local writes the overlaid record if it still
	 * matches the view's `where`.
	 */
	private _viewRow(entry: SubscriptionEntry, id: string): JsonValue | null {
		const view = entry.materializedView as MaterializedView;
		const record = view.records.get(id);
		if (!this.pending.has(entry.collection, id)) return record ?? null;
		const base = record ?? this._serverRecord(entry.collection, id);
		const value = this.pending.apply(entry.collection, id, base);
		return value !== null && view.matches(value) ? value : null;
	}

	/** The server record of a document any view or listen holds, else null. */
	private _serverRecord(collection: string, id: string): JsonValue | null {
		for (const entry of this.subscriptions.values()) {
			if (entry.collection !== collection) continue;
			const record = entry.materializedView
				? entry.materializedView.records.get(id)
				: entry.docId === id
					? entry.serverRecord
					: undefined;
			if (record != null) return record;
		}
		return null;
	}
}

/**
 * The delivered rows with the row of `id` set to `next` (null: none). The
 * first change copies `current`, which consumers already hold; `rows` is
 * that copy, or null while nothing changed.
 */
function withRow(
	current: JsonValue[],
	rows: JsonValue[] | null,
	comparator: (a: JsonValue, b: JsonValue) => number,
	id: string,
	next: JsonValue | null,
): JsonValue[] | null {
	const list = rows ?? current;
	const at = indexOfId(list, id);
	if ((at === -1 ? null : list[at]) === next) return rows;
	const copy = rows ?? current.slice();
	placeRow(copy, comparator, at, next);
	return copy;
}

function indexOfId(rows: JsonValue[], id: string): number {
	for (let i = 0; i < rows.length; i += 1) {
		if ((rows[i] as Record<string, JsonValue>).id === id) return i;
	}
	return -1;
}

/** Replace, remove or binary-insert the row at `at` (-1: none) in sorted `rows`. */
function placeRow(
	rows: JsonValue[],
	comparator: (a: JsonValue, b: JsonValue) => number,
	at: number,
	next: JsonValue | null,
): void {
	if (at !== -1) {
		if (next !== null && comparator(rows[at], next) === 0) {
			rows[at] = next;
			return;
		}
		rows.splice(at, 1);
	}
	if (next === null) return;
	let low = 0;
	let high = rows.length;
	while (low < high) {
		const mid = (low + high) >>> 1;
		if (comparator(rows[mid], next) > 0) high = mid;
		else low = mid + 1;
	}
	rows.splice(low, 0, next);
}

function toggle(set: Set<string>, id: string, on: boolean): Set<string> {
	if (on) set.add(id);
	else set.delete(id);
	return set;
}

/** Deep equality where arrays and bytes are whole values. */
function valuesEqual(a: JsonValue, b: JsonValue): boolean {
	if (a === b) return true;
	if (typeof a !== typeof b || a === null || b === null) return false;
	if (a instanceof Uint8Array) return bytesEqual(a, b);
	if (Array.isArray(a)) return arraysEqual(a, b);
	if (!isPlainRecord(a) || !isPlainRecord(b)) return false;
	return recordsEqual(a, b);
}

/** Isolated copy for the suppression baseline; primitives return as-is. */
function cloneValue(value: JsonValue): JsonValue {
	if (Array.isArray(value)) {
		const copy: JsonValue[] = new Array(value.length);
		for (let i = 0; i < value.length; i += 1) copy[i] = cloneValue(value[i]);
		return copy;
	}
	if (value instanceof Uint8Array) return value.slice();
	if (isPlainRecord(value)) {
		// Null prototype keeps an own `__proto__` field an ordinary key
		// instead of tripping the Object.prototype setter.
		const copy = Object.create(null) as Record<string, JsonValue>;
		for (const key of Object.keys(value)) copy[key] = cloneValue(value[key]);
		return copy;
	}
	return value;
}

function bytesEqual(a: Uint8Array, b: JsonValue): boolean {
	if (!(b instanceof Uint8Array) || a.length !== b.length) return false;
	for (let i = 0; i < a.length; i += 1) {
		if (a[i] !== b[i]) return false;
	}
	return true;
}

function arraysEqual(a: JsonValue[], b: JsonValue): boolean {
	if (!Array.isArray(b) || a.length !== b.length) return false;
	for (let i = 0; i < a.length; i += 1) {
		if (!valuesEqual(a[i], b[i])) return false;
	}
	return true;
}

function recordsEqual(a: Record<string, JsonValue>, b: JsonValue): boolean {
	if (!isPlainRecord(b)) return false;
	const keys = Object.keys(a);
	if (keys.length !== Object.keys(b).length) return false;
	for (const key of keys) {
		if (!Object.hasOwn(b, key) || !valuesEqual(a[key], b[key])) return false;
	}
	return true;
}

function isPlainRecord(
	value: JsonValue | undefined,
): value is Record<string, JsonValue> {
	return (
		value !== null &&
		typeof value === "object" &&
		!Array.isArray(value) &&
		!(value instanceof Uint8Array)
	);
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
		field: segments.length === 3 ? segments[2] : null,
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
