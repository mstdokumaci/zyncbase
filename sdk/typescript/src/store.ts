// Store API

import type { OutboundRequest } from "./connection_wire.js";
import { ErrorCodes, toZyncError, ZyncBaseError } from "./errors.js";
import { compileWhere } from "./filter_eval.js";
import { overlayOps, type PendingEntry } from "./optimistic.js";
import { flatten, getDeepProperty, splitFieldPath } from "./path.js";
import type { SchemaDictionary } from "./schema_dictionary.js";
import {
	buildBatch,
	buildCreate,
	buildGet,
	buildListen,
	buildLoadMore,
	buildQuery,
	buildRemove,
	buildSet,
	buildSubscribe,
	buildUnsubscribe,
	shapeGetResult,
	shapeQueryResult,
} from "./store_wire.js";
import {
	createCreatedAtComparator,
	createListenProjection,
	type DeliveryCallback,
	NO_PENDING,
	type SubscriptionEntry,
	type SubscriptionTracker,
} from "./subscriptions.js";
import type {
	BatchOperation,
	ConditionalWriteOptions,
	IncrementOptions,
	JsonValue,
	LifecycleEvent,
	ListenHandle,
	OkResponse,
	Path,
	QueryOptions,
	StoreSubscribe,
	SubscriptionHandle,
	WriteOptions,
} from "./types.js";
import { generateUUIDv7 } from "./uuid.js";
import { compareScalars } from "./value_order.js";

/** How long a keyed subscription outlives its last consumer before teardown. */
const GRACE_TEARDOWN_MS = 300;

/** Builds the invalid-message error for an ack without a subscription id. */
function missingSubIdError(kind: RegistrationKey["kind"]): ZyncBaseError {
	return new ZyncBaseError(
		kind === "listen"
			? "Listen response missing subId"
			: "Subscribe response missing subId",
		{
			code: ErrorCodes.INVALID_MESSAGE,
			category: "client",
			retryable: false,
		},
	);
}

/** The subset of ConnectionManager that StoreImpl depends on. */
export interface StoreConnection {
	dispatch(
		msg: OutboundRequest,
		responseTableIndex?: number,
	): Promise<OkResponse>;
	dispatchWrite(msg: OutboundRequest): Promise<void>;
	on(event: LifecycleEvent, handler: (...args: unknown[]) => void): void;
	readonly schemaDictionary: SchemaDictionary;
	/** The connection's internal user id; owner of the rows it creates. */
	readonly userId: string | null;
}

/**
 * One keyed server subscription: shared by every consumer of the same
 * canonical message, ref-counted through `callbacks`.
 */
interface RegistrationKey {
	/**
	 * Canonical key — kind prefix + registration identity.
	 *
	 * Listen keys use the full normalized path because the wire message omits
	 * the projected field. Subscribe keys use the serialized wire message,
	 * which is safe because buildSubscribe builds it in fixed literal order
	 * from normalized inputs. Do not spread caller objects into the message:
	 * it would silently break dedup.
	 */
	key: string;
	kind: "listen" | "subscribe";
	/** Original subscribe message; dispatched once per key. */
	message: Omit<StoreSubscribe, "id">;
	/** Listen path segments (listen only). */
	segments: string[] | null;
	/** Collection name for comparator / loadMore (subscribe only). */
	collection: string | null;
	/** Query options for the comparator (subscribe only). */
	options: QueryOptions | null;
	/** Shared consumer callbacks — the tracker entry holds this same array. */
	callbacks: DeliveryCallback[];
	/** Server subId once accepted; null while queued or establishing. */
	subId: number | null;
	/** Establishment promise; null once settled (accepted or dropped). */
	establishing: Promise<void> | null;
	/** Shared pagination cursor (subscribe only). */
	nextCursor: string | null;
	hasMore: boolean;
	inFlight: Promise<void> | null;
	/** Pending grace-window teardown timer. */
	graceTimer: ReturnType<typeof setTimeout> | null;
	closed: boolean;
}

/** A registration whose promise has not settled yet. */
interface PendingConsumer {
	state: RegistrationKey;
	callback: DeliveryCallback;
	settled: boolean;
	reject: (err: unknown) => void;
}

interface SortEntry {
	parts: string[];
	desc: boolean;
	docId: boolean;
}

export class StoreImpl {
	/** Keyed shared subscriptions, canonical key → live state. */
	private readonly keys = new Map<string, RegistrationKey>();
	/** Registrations whose promises have not settled yet. */
	private readonly unsettled = new Set<PendingConsumer>();
	/** Establishments waiting for the next readiness cycle. */
	private readonly readyWaiters: Array<() => void> = [];
	private sessionReady = false;
	/** Bumped on every drop/switch so in-flight establishment acks go stale. */
	private scopeGen = 0;
	/** >0 while a namespace switch is in flight; gates new establishments. */
	private switchPending = 0;

	constructor(
		private readonly conn: StoreConnection,
		private readonly tracker: SubscriptionTracker,
		private readonly emitError: (err: ZyncBaseError) => void = () => {},
	) {
		this.conn.on("disconnected", () => this.markNotReady());
	}

	set(
		path: Path,
		value: JsonValue,
		options?: ConditionalWriteOptions,
	): Promise<void> {
		return this.write(
			() => buildSet(path, value, options).message,
			"Set failed",
			options,
		);
	}

	remove(path: Path, options?: ConditionalWriteOptions): Promise<void> {
		return this.write(
			() => buildRemove(path, options).message,
			"Remove failed",
			options,
		);
	}

	increment(path: Path, by: number, options?: IncrementOptions): Promise<void> {
		return this.write(
			() =>
				buildBatch([
					{
						op: "increment",
						path,
						by,
						...(options?.if ? { if: options.if } : {}),
					},
				]),
			"Increment failed",
			options,
		);
	}

	create(
		collection: string,
		value: JsonValue,
		options?: WriteOptions,
	): Promise<string> {
		const id = generateUUIDv7();
		const result = this.write(
			() => {
				this.validateRequiredFields(collection, value);
				return buildCreate(collection, value, id).message;
			},
			"Create failed",
			options,
			true,
		).then(() => id);
		result.catch(() => {}); // see write()
		return result;
	}

	async get(path: Path): Promise<JsonValue | null | undefined> {
		const command = buildGet(path);
		try {
			const ok = await this.conn.dispatch(command.message);
			return shapeGetResult(command.segments, (ok.value ?? []) as JsonValue[]);
		} catch (err) {
			this.emitAndThrow(err, "Get failed");
		}
	}

	async query(
		collection: string,
		options?: QueryOptions,
	): Promise<JsonValue[] & { nextCursor: string | null }> {
		const command = buildQuery(collection, options);
		try {
			const ok = await this.conn.dispatch(command.message);
			return shapeQueryResult(ok);
		} catch (err) {
			this.emitAndThrow(err, "Query failed");
		}
	}

	batch(operations: BatchOperation[], options?: WriteOptions): Promise<void> {
		return this.write(() => buildBatch(operations), "Batch failed", options);
	}

	listen(
		path: Path,
		callback: (value: JsonValue, meta: { pending: boolean }) => void,
	): Promise<ListenHandle> {
		const command = buildListen(path);
		const state = this.acquireKey(`l:${JSON.stringify(command.segments)}`, {
			kind: "listen",
			message: command.message,
			segments: command.segments,
			collection: null,
			options: null,
		});
		const deliver = callback as DeliveryCallback;
		const pending = () => this.pendingOf(state);
		return this.attach(state, deliver, () => {
			let released = false;
			return {
				unlisten: () => {
					if (released) return Promise.resolve();
					released = true;
					return this.release(state, deliver);
				},
				getSnapshot: () => this.snapshotOf(state),
				get isPending() {
					return pending() === true;
				},
			};
		});
	}

	subscribe(
		collection: string,
		options: QueryOptions,
		callback: (
			results: JsonValue[],
			meta: { pending: ReadonlySet<string> },
		) => void,
	): Promise<SubscriptionHandle> {
		const command = buildSubscribe(collection, options);
		const state = this.acquireKey(`s:${JSON.stringify(command.message)}`, {
			kind: "subscribe",
			message: command.message,
			segments: null,
			collection,
			// The wire message froze the options at call time — the comparator
			// reads only `orderBy`, so copy just that and never `structuredClone`
			// (which throws `DataCloneError` on non-cloneable user values).
			options: { orderBy: options.orderBy?.map((clause) => ({ ...clause })) },
		});
		const deliver = callback as DeliveryCallback;
		const pending = () => this.pendingOf(state);
		return this.attach(state, deliver, () => {
			let released = false;
			return {
				get hasMore() {
					return state.hasMore;
				},
				loadMore: () => this.loadMore(state),
				unsubscribe: () => {
					if (released) return Promise.resolve();
					released = true;
					return this.release(state, deliver);
				},
				// A subscribe key's materialized view always snapshots to rows.
				getSnapshot: () =>
					(this.snapshotOf(state) as JsonValue[] | undefined) ?? [],
				get pendingIds() {
					const ids = pending();
					return ids instanceof Set ? ids : NO_PENDING;
				},
			};
		});
	}

	// ─── Subscription registry ──────────────────────────────────────────────

	/** Finds or creates the keyed shared subscription for a registration. */
	private acquireKey(
		key: string,
		def: {
			kind: RegistrationKey["kind"];
			message: Omit<StoreSubscribe, "id">;
			segments: string[] | null;
			collection: string | null;
			options: QueryOptions | null;
		},
	): RegistrationKey {
		const existing = this.keys.get(key);
		if (existing) {
			// Re-attach inside the grace window cancels the pending teardown.
			if (existing.graceTimer) {
				clearTimeout(existing.graceTimer);
				existing.graceTimer = null;
			}
			return existing;
		}
		const state: RegistrationKey = {
			key,
			...def,
			callbacks: [],
			subId: null,
			establishing: null,
			nextCursor: null,
			hasMore: false,
			inFlight: null,
			graceTimer: null,
			closed: false,
		};
		this.keys.set(key, state);
		return state;
	}

	/**
	 * Registers one consumer against a key: resolves immediately when the
	 * key is already established (firing the retained snapshot), otherwise
	 * settles together with the key's establishment.
	 */
	private attach<H>(
		state: RegistrationKey,
		callback: DeliveryCallback,
		makeHandle: () => H,
	): Promise<H> {
		const request = new Promise<H>((resolve, reject) => {
			const consumer: PendingConsumer = {
				state,
				callback,
				settled: false,
				reject,
			};
			this.unsettled.add(consumer);
			const settle = (run: () => void): void => {
				if (consumer.settled) return;
				consumer.settled = true;
				this.unsettled.delete(consumer);
				run();
			};
			state.callbacks.push(callback);

			const entry =
				state.subId !== null ? this.tracker.get(state.subId) : undefined;
			if (entry) {
				settle(() => {
					resolve(makeHandle());
					if (entry.deliveredValue === undefined) return;
					const value = entry.deliveredValue;
					const pending =
						entry.deliveredPending ??
						(state.kind === "listen" ? false : NO_PENDING);
					// Fire on a microtask: a caller's synchronous tail
					// (storing the handle) must run first, or a delivery
					// guard keyed on that store drops the snapshot.
					queueMicrotask(() => {
						if (!state.callbacks.includes(callback)) return;
						try {
							callback(value, { pending });
						} catch (err) {
							console.error("[SDK] Subscription callback threw:", err);
						}
					});
				});
				return;
			}

			const establishment =
				state.establishing ?? this.ensureEstablishing(state);
			establishment.then(
				() => settle(() => resolve(makeHandle())),
				(err) =>
					settle(() => {
						const error = toZyncError(
							err,
							state.kind === "listen" ? "Listen failed" : "Subscribe failed",
						);
						this.emitError(error);
						reject(error);
					}),
			);
		});
		request.catch(() => {});
		return request;
	}

	private ensureEstablishing(state: RegistrationKey): Promise<void> {
		if (state.establishing) return state.establishing;
		const loop = this.establishLoop(state);
		state.establishing = loop;
		const done = (): void => {
			if (state.establishing === loop) state.establishing = null;
		};
		loop.then(done, done);
		return loop;
	}

	/**
	 * Waits for readiness, dispatches the key's subscribe message, and
	 * retries across connection gaps and scope switches until the
	 * subscription is accepted or the key fails for good.
	 */
	private async establishLoop(state: RegistrationKey): Promise<void> {
		while (!state.closed) {
			// Keep this check synchronous: an already-ready session must dispatch
			// in the caller's tick, not one microtask later.
			if (!this.sessionReady || this.switchPending > 0) {
				await this.readySignal();
				continue;
			}
			const gen = this.scopeGen;
			try {
				const retry = await this.attemptEstablish(state, gen);
				if (!retry) return;
			} catch (err) {
				if (!this.afterEstablishFailure(err, state, gen)) return;
			}
		}
	}

	/** Retries when the failure can outlive a scope switch; false gives up. */
	private afterEstablishFailure(
		err: unknown,
		state: RegistrationKey,
		gen: number,
	): boolean {
		if (state.closed) return false;
		if (state.callbacks.length === 0) {
			this.dropKey(state);
			return false;
		}
		if (gen !== this.scopeGen || !this.sessionReady || this.switchPending > 0) {
			return true;
		}
		this.dropKey(state);
		throw err;
	}

	/** Returns true when the ack went stale and the loop should retry. */
	private async attemptEstablish(
		state: RegistrationKey,
		gen: number,
	): Promise<boolean> {
		this.tracker.beginEstablish();
		try {
			return await this.establishOnce(state, gen);
		} finally {
			this.tracker.endEstablish();
		}
	}

	private async establishOnce(
		state: RegistrationKey,
		gen: number,
	): Promise<boolean> {
		const ok = await this.conn.dispatch(state.message);
		const subId = ok.subId;
		if (subId === undefined) throw missingSubIdError(state.kind);
		if (state.closed || this.keys.get(state.key) !== state) {
			// Everyone left (or the client shut down) while the ack was in
			// flight — free the server subscription when the socket is live.
			if (this.sessionReady && gen === this.scopeGen) {
				this.dispatchUnsubscribe(subId).catch(() => {});
			}
			return false;
		}
		if (gen !== this.scopeGen) {
			// The scope was committed away (accepted switch) or the connection
			// dropped under us — the server has invalidated these
			// subscriptions, so the ack is stale.
			return true;
		}
		if (state.callbacks.length === 0) {
			this.dropKey(state);
			if (this.sessionReady) this.dispatchUnsubscribe(subId).catch(() => {});
			return false;
		}
		this.acceptAck(state, ok, subId);
		return false;
	}

	/** Adopts an accepted ack: subscription id, cursor, tracking and snapshot. */
	private acceptAck(
		state: RegistrationKey,
		ok: OkResponse,
		subId: number,
	): void {
		state.subId = subId;
		if (state.kind === "subscribe") {
			state.nextCursor = ok.nextCursor ?? null;
			state.hasMore = ok.hasMore ?? false;
		}
		this.tracker.register(subId, this.entryFor(state));
		if (ok.value !== undefined) {
			this.tracker.dispatchInitialSnapshot(
				subId,
				state.kind === "listen"
					? (state.segments as string[])
					: [state.collection as string],
				ok.value as JsonValue,
			);
		}
		this.tracker.replayEarlyDeltas(subId);
	}

	private entryFor(state: RegistrationKey): SubscriptionEntry {
		const onRemap = (newId: number): void => {
			state.subId = newId;
		};
		if (state.kind === "listen") {
			const segments = state.segments as string[];
			return {
				params: state.message,
				collection: segments[0],
				docId: segments[1],
				callbacks: state.callbacks,
				projection: createListenProjection(segments),
				onRemap,
			};
		}
		const collection = state.collection as string;
		const schema = this.conn.schemaDictionary;
		return {
			params: state.message,
			collection,
			callbacks: state.callbacks,
			projection: null,
			materializedView: {
				records: new Map(),
				comparator: this.buildCollectionComparator(
					collection,
					state.options as QueryOptions,
				),
				matches: compileWhere(state.message, (field) => {
					const tableIndex = schema.getTableIndex(collection);
					return schema.isDocIdField(
						tableIndex,
						schema.getFieldIndex(tableIndex, field),
					);
				}),
			},
			onRemap,
		};
	}

	private dropKey(state: RegistrationKey): void {
		state.closed = true;
		if (this.keys.get(state.key) === state) this.keys.delete(state.key);
		if (state.graceTimer) {
			clearTimeout(state.graceTimer);
			state.graceTimer = null;
		}
	}

	/**
	 * Detaches one consumer. When the last consumer of a key leaves, the
	 * server-side unsubscribe is scheduled after the grace window.
	 */
	private release(
		state: RegistrationKey,
		callback: DeliveryCallback,
	): Promise<void> {
		const index = state.callbacks.indexOf(callback);
		if (index !== -1) state.callbacks.splice(index, 1);
		if (state.closed || state.callbacks.length > 0 || state.subId === null) {
			return Promise.resolve();
		}
		// Last consumer left — hold the server subscription briefly so an
		// immediate re-attach (viewport churn) costs zero round trips.
		state.graceTimer = setTimeout(() => {
			state.graceTimer = null;
			this.teardown(state);
		}, GRACE_TEARDOWN_MS);
		return Promise.resolve();
	}

	private teardown(state: RegistrationKey): void {
		this.dropKey(state);
		const subId = state.subId;
		state.subId = null;
		if (subId !== null) {
			this.tracker.unregister(subId);
			if (this.sessionReady) {
				this.dispatchUnsubscribe(subId).catch(() => {});
			}
		}
	}

	private async loadMore(state: RegistrationKey): Promise<void> {
		while (true) {
			if (state.subId === null || state.nextCursor === null) return;
			if (state.inFlight !== null) {
				await state.inFlight;
				continue;
			}
			break;
		}
		const subId = state.subId;
		const nextCursor = state.nextCursor;
		const promise = (async () => {
			const ok = await this.conn.dispatch(
				buildLoadMore(subId, nextCursor),
				this.conn.schemaDictionary.getTableIndex(state.collection as string),
			);
			// A reconnect remap or unsubscribe while this page was in flight
			// makes the response stale: it belongs to the old subscription.
			if (state.closed || state.subId !== subId) return;
			state.nextCursor = ok.nextCursor ?? null;
			state.hasMore = ok.hasMore ?? false;
			if (ok.value !== undefined) {
				this.tracker.dispatchInitialSnapshot(
					subId,
					[state.collection as string],
					ok.value,
				);
			}
		})();
		state.inFlight = promise;
		try {
			await promise;
		} finally {
			state.inFlight = null;
		}
	}

	private snapshotOf(state: RegistrationKey): JsonValue | undefined {
		if (state.subId === null) return undefined;
		return this.tracker.get(state.subId)?.deliveredValue;
	}

	private pendingOf(
		state: RegistrationKey,
	): ReadonlySet<string> | boolean | undefined {
		if (state.subId === null) return undefined;
		return this.tracker.get(state.subId)?.deliveredPending;
	}

	/**
	 * Internal: the client calls this once the session (schema + replay) is
	 * ready — it wakes queued establishments and waits for their acks.
	 */
	markSessionReady(): Promise<void> {
		this.sessionReady = true;
		this.wakeReady();
		const inFlight: Array<Promise<void>> = [];
		for (const state of this.keys.values()) {
			if (state.establishing) inFlight.push(state.establishing.catch(() => {}));
		}
		return Promise.all(inFlight).then(() => undefined);
	}

	/** Internal: connection dropped or scope about to change. */
	markNotReady(): void {
		this.sessionReady = false;
		this.scopeGen++;
		this.tracker.refresh(this.tracker.pending.clear());
	}

	/** Internal: a namespace switch is in flight — pause new establishments. */
	beginNamespaceSwitch(): void {
		this.switchPending++;
	}

	/** Internal: the switch was rejected — the old scope is still valid. */
	rollbackNamespaceSwitch(): void {
		this.switchPending--;
		this.wakeReady();
	}

	/** Internal: the switch landed — invalidate anything from the old scope. */
	commitNamespaceSwitch(): void {
		this.switchPending--;
		this.markNotReady();
	}

	/** Internal: `client.disconnect()` — discard queued registrations. */
	rejectPending(): void {
		const err = new ZyncBaseError(
			"Client disconnected before the registration was established",
			{
				code: ErrorCodes.CONNECTION_FAILED,
				category: "network",
				retryable: false,
			},
		);
		for (const consumer of this.unsettled) {
			if (consumer.settled) continue;
			consumer.settled = true;
			const index = consumer.state.callbacks.indexOf(consumer.callback);
			if (index !== -1) consumer.state.callbacks.splice(index, 1);
			consumer.reject(err);
		}
		this.unsettled.clear();
		const empties: RegistrationKey[] = [];
		for (const state of this.keys.values()) {
			if (state.callbacks.length === 0) empties.push(state);
		}
		for (const state of empties) this.teardown(state);
		// Wake establishments stuck on readySignal() so they observe `closed`
		// and exit instead of parking until the next readiness cycle.
		this.wakeReady();
	}

	private wakeReady(): void {
		const waiters = this.readyWaiters.splice(0);
		for (const wake of waiters) wake();
	}

	private readySignal(): Promise<void> {
		if (this.sessionReady && this.switchPending === 0) {
			return Promise.resolve();
		}
		return new Promise<void>((resolve) => this.readyWaiters.push(resolve));
	}

	/**
	 * Builds the schema-aware materialized-view comparator for a subscription.
	 * Mirrors the server's canonical order: public dot-path clauses in order,
	 * nulls always last, packed DocId order for reference fields, UTF-8 byte
	 * order for text, plus hidden `created_at ASC` unless the final explicit
	 * clause is already unique (`created_at` or `id`).
	 */
	private buildCollectionComparator(
		collection: string,
		options: QueryOptions,
	): (a: JsonValue, b: JsonValue) => number {
		if (!options.orderBy?.length) return createCreatedAtComparator();

		const schema = this.conn.schemaDictionary;
		const tableIndex = schema.getTableIndex(collection);

		const entries: SortEntry[] = [];
		for (const clause of options.orderBy) {
			const field = Object.keys(clause)[0];
			if (field === undefined) continue;
			const encodedField = field.replace(/\./g, "__");
			const parts = splitFieldPath(encodedField);
			const fieldIndex = schema.getFieldIndex(tableIndex, encodedField);
			entries.push({
				parts,
				desc: clause[field] === "desc",
				docId: schema.isDocIdField(tableIndex, fieldIndex),
			});
		}

		const finalEntry = entries[entries.length - 1];
		const finalField =
			finalEntry?.parts.length === 1 ? finalEntry.parts[0] : undefined;
		if (finalField !== "created_at" && finalField !== "id") {
			entries.push({ parts: ["created_at"], desc: false, docId: false });
		}

		return (a: JsonValue, b: JsonValue): number =>
			compareRecords(entries, a, b);
	}

	/**
	 * Build and send a write synchronously, so writes and reads issued
	 * back-to-back reach the server in call order. Unless opted out, the
	 * write then shows in subscriptions and listens before this returns. The
	 * server sends a write's deltas before its outcome, so subscriptions are
	 * flushed before the promise resolves. Failures revert the local write
	 * and emit on('error'); the returned promise is marked handled so
	 * un-awaited writes do not raise unhandled rejections.
	 */
	private write(
		build: () => OutboundRequest,
		fallbackMessage: string,
		options: WriteOptions | undefined,
		create = false,
	): Promise<void> {
		let message: OutboundRequest | null = null;
		let sent: Promise<void>;
		try {
			message = build();
			sent = this.conn.dispatchWrite(message);
		} catch (err) {
			sent = Promise.reject(err);
		}
		const entry =
			message !== null && options?.optimistic !== false
				? this.showLocally(message, create)
				: null;
		const result = sent.then(
			() => this.settle(entry, true),
			(err: unknown) => {
				this.settle(entry, false);
				this.emitAndThrow(err, fallbackMessage);
			},
		);
		result.catch(() => {});
		return result;
	}

	/**
	 * Adds a sent write to the overlay and delivers it. Skipped while the
	 * session is not ready (the write fails fast) or a namespace switch is
	 * in flight, and for writes the overlay cannot shape: those fail on the
	 * server, which rejects what the schema cannot describe.
	 */
	private showLocally(
		message: OutboundRequest,
		create: boolean,
	): PendingEntry | null {
		if (!this.sessionReady || this.switchPending > 0) return null;
		let ops: ReturnType<typeof overlayOps>;
		try {
			ops = overlayOps(message, create, {
				schema: this.conn.schemaDictionary,
				userId: this.conn.userId,
				time: this.tracker.provisionalTime(),
			});
		} catch {
			return null;
		}
		if (ops === null) return null;
		const entry = this.tracker.pending.add(ops);
		this.tracker.refresh(entry.keys);
		return entry;
	}

	/**
	 * Drops a settled write from the overlay. A commit's deltas arrive before
	 * it, so they are flushed after the drop and before the refresh: one
	 * delivery, with no frame showing the old server value.
	 */
	private settle(entry: PendingEntry | null, committed: boolean): void {
		const pending = this.tracker.pending;
		const keys =
			entry === null
				? null
				: committed
					? pending.commit(entry)
					: pending.fail(entry);
		if (committed) this.tracker.flushNow();
		if (keys !== null) this.tracker.refresh(keys);
	}

	private async dispatchVoid(
		message: OutboundRequest,
		fallbackMessage: string,
	): Promise<void> {
		try {
			await this.conn.dispatch(message);
		} catch (err) {
			this.emitAndThrow(err, fallbackMessage);
		}
	}

	private async dispatchUnsubscribe(subId: number): Promise<void> {
		await this.dispatchVoid(buildUnsubscribe(subId), "Unsubscribe failed");
	}

	private validateRequiredFields(collection: string, value: JsonValue): void {
		const schema = this.conn.schemaDictionary;
		if (!schema.isReady()) return;
		if (!this.isObjectRecord(value)) return;

		const tableIndex = schema.getTableIndex(collection);
		const fields = schema.getFields(tableIndex);
		const flatValue = flatten(value);

		const missingFields = this.findMissingRequiredFields(
			schema,
			tableIndex,
			fields,
			flatValue,
		);

		if (missingFields.length > 0) {
			throw new ZyncBaseError(
				`Missing required field(s): ${missingFields.join(", ")}`,
				{
					code: ErrorCodes.SCHEMA_VALIDATION_FAILED,
					category: "validation",
					retryable: false,
					details: { missingFields },
				},
			);
		}
	}

	private isObjectRecord(value: JsonValue): value is Record<string, JsonValue> {
		return value !== null && typeof value === "object" && !Array.isArray(value);
	}

	private findMissingRequiredFields(
		schema: SchemaDictionary,
		tableIndex: number,
		fields: string[],
		flatValue: Record<string, JsonValue>,
	): string[] {
		const missing: string[] = [];
		for (let fi = 0; fi < fields.length; fi++) {
			if (schema.isSystemField(tableIndex, fi)) continue;
			if (!schema.isRequiredField(tableIndex, fi)) continue;
			const fieldName = fields[fi];
			if (flatValue[fieldName] == null) {
				missing.push(splitFieldPath(fieldName).join("."));
			}
		}
		return missing;
	}

	private emitAndThrow(err: unknown, fallbackMessage: string): never {
		const error = toZyncError(err, fallbackMessage);
		this.emitError(error);
		throw error;
	}
}

function compareRecords(
	entries: SortEntry[],
	a: JsonValue,
	b: JsonValue,
): number {
	for (const entry of entries) {
		const result = compareSortEntry(entry, a, b);
		if (result !== 0) return result;
	}
	return 0;
}

function compareSortEntry(
	entry: SortEntry,
	a: JsonValue,
	b: JsonValue,
): number {
	const va = getDeepProperty(a, entry.parts);
	const vb = getDeepProperty(b, entry.parts);

	// Missing and null sort identically and are always last.
	if (va == null) return vb == null ? 0 : 1;
	if (vb == null) return -1;

	const result = compareScalars(va, vb, entry.docId);
	return entry.desc ? -result : result;
}
