// Store API

import type { OutboundRequest } from "./connection_wire.js";
import { compareDocIds } from "./doc_id.js";
import { ErrorCodes, ZyncBaseError } from "./errors.js";
import { flatten, splitFieldPath } from "./path.js";
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
	type SubscriptionEntry,
	type SubscriptionTracker,
} from "./subscriptions.js";
import type {
	BatchOperation,
	InboundMessage,
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

/** How long a keyed subscription outlives its last consumer before teardown. */
const GRACE_TEARDOWN_MS = 300;

/** The subset of ConnectionManager that StoreImpl depends on. */
export interface StoreConnection {
	dispatch(
		msg: OutboundRequest,
		responseTableIndex?: number,
	): Promise<OkResponse>;
	onMessage(handler: (msg: InboundMessage) => void): void;
	on(event: LifecycleEvent, handler: (...args: unknown[]) => void): void;
	isSchemaReady(): boolean;
	readonly schemaDictionary: SchemaDictionary;
}

/**
 * One keyed server subscription: shared by every consumer of the same
 * canonical message, ref-counted through `callbacks`.
 */
interface RegistrationKey {
	/**
	 * Canonical key — kind prefix + serialized wire message.
	 *
	 * This is wire-byte identity: safe because buildListen/buildSubscribe
	 * construct the message in fixed literal order from normalized inputs —
	 * never user input, so key insertion order can't vary. Do not spread
	 * caller objects into the message: it would silently break dedup.
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
	callbacks: Array<(value: JsonValue) => void>;
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
	callback: (value: JsonValue) => void;
	settled: boolean;
	reject: (err: unknown) => void;
}

interface SortEntry {
	parts: string[];
	desc: boolean;
	docId: boolean;
}

export class StoreImpl {
	private readonly inFlightWrites = new Map<
		string,
		{ resolve: () => void; reject: (err: Error) => void }
	>();
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
		this.conn.onMessage((msg) => this.handleInboundMessage(msg));
		this.conn.on("disconnected", () => {
			this.markNotReady();
			this.rejectAllInFlight();
		});
		this.conn.on("reconnecting", () => this.rejectAllInFlight());
	}

	async set(
		path: Path,
		value: JsonValue,
		options?: WriteOptions,
	): Promise<void> {
		const command = buildSet(path, value, options);
		await this.dispatchWrite(
			command.message,
			command.message.writeId,
			options,
			"Set failed",
		);
	}

	async remove(path: Path, options?: WriteOptions): Promise<void> {
		const command = buildRemove(path, options);
		await this.dispatchWrite(
			command.message,
			command.message.writeId,
			options,
			"Remove failed",
		);
	}

	async create(
		collection: string,
		value: JsonValue,
		options?: WriteOptions,
	): Promise<string> {
		this.validateRequiredFields(collection, value);
		const id = generateUUIDv7();
		const command = buildCreate(collection, value, id, options);
		await this.dispatchWrite(
			command.message,
			command.message.writeId,
			options,
			"Create failed",
		);
		return id;
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

	async batch(
		operations: BatchOperation[],
		options?: WriteOptions,
	): Promise<void> {
		const message = buildBatch(operations, options);
		await this.dispatchWrite(message, message.writeId, options, "Batch failed");
	}

	listen(
		path: Path,
		callback: (value: JsonValue) => void,
	): Promise<ListenHandle> {
		const command = buildListen(path);
		const state = this.acquireKey(`l:${JSON.stringify(command.message)}`, {
			kind: "listen",
			message: command.message,
			segments: command.segments,
			collection: null,
			options: null,
		});
		return this.attach(state, callback, () => {
			let released = false;
			return {
				unlisten: () => {
					if (released) return Promise.resolve();
					released = true;
					return this.release(state, callback);
				},
				getSnapshot: () => this.snapshotOf(state),
			};
		});
	}

	subscribe(
		collection: string,
		options: QueryOptions,
		callback: (results: JsonValue[]) => void,
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
		return this.attach(state, callback as (value: JsonValue) => void, () => {
			let released = false;
			return {
				get hasMore() {
					return state.hasMore;
				},
				loadMore: () => this.loadMore(state),
				unsubscribe: () => {
					if (released) return Promise.resolve();
					released = true;
					return this.release(state, callback as (value: JsonValue) => void);
				},
				// A subscribe key's materialized view always snapshots to rows.
				getSnapshot: () =>
					(this.snapshotOf(state) as JsonValue[] | undefined) ?? [],
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
		callback: (value: JsonValue) => void,
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
					if (entry.lastValue === undefined) return;
					const value = entry.lastValue;
					// Fire on a microtask: a caller's synchronous tail
					// (storing the handle) must run first, or a delivery
					// guard keyed on that store drops the snapshot.
					queueMicrotask(() => {
						if (!state.callbacks.includes(callback)) return;
						try {
							callback(value);
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
						const error = this.normalizeError(
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
	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: readiness wait, dispatch, and failure handling are one retry story — splitting them obscures the retry conditions.
	private async establishLoop(state: RegistrationKey): Promise<void> {
		while (!state.closed) {
			if (!this.sessionReady || this.switchPending > 0) {
				await this.readySignal();
				continue;
			}
			const gen = this.scopeGen;
			try {
				const retry = await this.attemptEstablish(state, gen);
				if (!retry) return;
			} catch (err) {
				if (state.closed) return;
				if (state.callbacks.length === 0) {
					this.dropKey(state);
					return;
				}
				if (
					gen !== this.scopeGen ||
					!this.sessionReady ||
					this.switchPending > 0
				) {
					continue;
				}
				this.dropKey(state);
				throw err;
			}
		}
	}

	/** Returns true when the ack went stale and the loop should retry. */
	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: one dispatch-ack-validate path; guards would become hidden preconditions across helper boundaries.
	private async attemptEstablish(
		state: RegistrationKey,
		gen: number,
	): Promise<boolean> {
		const ok = await this.conn.dispatch(state.message);
		if (ok.subId === undefined) {
			throw new ZyncBaseError(
				state.kind === "listen"
					? "Listen response missing subId"
					: "Subscribe response missing subId",
				{
					code: ErrorCodes.INVALID_MESSAGE,
					category: "client",
					retryable: false,
				},
			);
		}
		if (state.closed || this.keys.get(state.key) !== state) {
			// Everyone left (or the client shut down) while the ack was in
			// flight — free the server subscription when the socket is live.
			if (this.sessionReady && gen === this.scopeGen) {
				this.dispatchUnsubscribe(ok.subId).catch(() => {});
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
			if (this.sessionReady) {
				this.dispatchUnsubscribe(ok.subId).catch(() => {});
			}
			return false;
		}
		state.subId = ok.subId;
		if (state.kind === "subscribe") {
			state.nextCursor = ok.nextCursor ?? null;
			state.hasMore = ok.hasMore ?? false;
		}
		this.tracker.register(ok.subId, this.entryFor(state));
		if (ok.value !== undefined) {
			this.tracker.dispatchInitialSnapshot(
				ok.subId,
				state.kind === "listen"
					? (state.segments as string[])
					: [state.collection as string],
				ok.value as JsonValue,
			);
		}
		return false;
	}

	private entryFor(state: RegistrationKey): SubscriptionEntry {
		return {
			params: state.message,
			callbacks: state.callbacks,
			projection:
				state.kind === "listen"
					? createListenProjection(state.segments as string[])
					: null,
			materializedView:
				state.kind === "subscribe"
					? {
							records: new Map(),
							comparator: this.buildCollectionComparator(
								state.collection as string,
								state.options as QueryOptions,
							),
						}
					: undefined,
			onRemap: (newId) => {
				state.subId = newId;
			},
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
		callback: (value: JsonValue) => void,
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
		return this.tracker.get(state.subId)?.lastValue;
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
		for (const clause of options.orderBy ?? []) {
			const field = Object.keys(clause)[0];
			if (field === undefined) continue;
			const encodedField = field.split(".").join("__");
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

	private async dispatchWrite(
		message: OutboundRequest,
		writeId: string | undefined,
		options: WriteOptions | undefined,
		fallbackMessage: string,
	): Promise<void> {
		if (options?.confirm === "committed") {
			if (!writeId) {
				throw new ZyncBaseError(
					"writeId is required for committed confirmation",
					{
						code: ErrorCodes.INVALID_MESSAGE,
						category: "client",
						retryable: false,
					},
				);
			}
			let commitResolve: () => void = () => {};
			let commitReject: (err: Error) => void = () => {};
			const commitPromise = new Promise<void>((resolve, reject) => {
				commitResolve = resolve;
				commitReject = reject;
			});
			this.inFlightWrites.set(writeId, {
				resolve: commitResolve,
				reject: commitReject,
			});
			try {
				await this.conn.dispatch(message);
			} catch (err) {
				this.inFlightWrites.delete(writeId);
				this.emitAndThrow(err, fallbackMessage);
			}
			try {
				await commitPromise;
			} catch (err) {
				this.emitAndThrow(err, fallbackMessage);
			}
		} else {
			await this.dispatchVoid(message, fallbackMessage);
		}
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
		try {
			await this.conn.dispatch(buildUnsubscribe(subId));
		} catch (err) {
			this.emitAndThrow(err, "Unsubscribe failed");
		}
	}

	private rejectAllInFlight(): void {
		if (this.inFlightWrites.size === 0) return;
		const err = new ZyncBaseError(
			"Connection closed before write was confirmed",
			{
				code: ErrorCodes.CONNECTION_FAILED,
				category: "network",
				retryable: true,
			},
		);
		for (const pending of this.inFlightWrites.values()) {
			pending.reject(err);
		}
		this.inFlightWrites.clear();
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

	private handleInboundMessage(msg: InboundMessage): void {
		if (msg.type === "WriteCommitted") {
			const pending = this.inFlightWrites.get(msg.writeId);
			if (pending) {
				pending.resolve();
				this.inFlightWrites.delete(msg.writeId);
			}
		} else if (msg.type === "WriteError") {
			const pending = this.inFlightWrites.get(msg.writeId);
			if (pending) {
				const details: Record<string, string | number> = {
					phase: msg.phase ?? "write",
				};
				if (msg.batchIndex !== undefined) details.batchIndex = msg.batchIndex;
				const error = ZyncBaseError.fromServerResponse({
					code: msg.code,
					message: msg.message,
					details,
				});
				pending.reject(error);
				this.inFlightWrites.delete(msg.writeId);
			}
		}
	}

	private emitAndThrow(err: unknown, fallbackMessage: string): never {
		const error = this.normalizeError(err, fallbackMessage);
		this.emitError(error);
		throw error;
	}

	private normalizeError(err: unknown, fallbackMessage: string): ZyncBaseError {
		if (err instanceof ZyncBaseError) return err;
		return new ZyncBaseError(
			err instanceof Error ? err.message : fallbackMessage,
			{
				code: ErrorCodes.INTERNAL_ERROR,
				category: "server",
				retryable: true,
			},
		);
	}
}

function getNestedValue(
	obj: JsonValue,
	parts: string[],
): JsonValue | undefined {
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
	const va = getNestedValue(a, entry.parts);
	const vb = getNestedValue(b, entry.parts);

	// Missing and null sort identically and are always last.
	if (va == null) return vb == null ? 0 : 1;
	if (vb == null) return -1;

	const result =
		entry.docId && typeof va === "string" && typeof vb === "string"
			? compareDocIds(va, vb)
			: compareNonNullValues(va, vb);
	return entry.desc ? -result : result;
}

function compareNonNullValues(a: JsonValue, b: JsonValue): number {
	if (typeof a !== typeof b) return 0;
	switch (typeof a) {
		case "number":
			return compareNumbers(a, b as number);
		case "boolean":
			return compareBooleans(a, b as boolean);
		case "string":
			return compareUtf8(a, b as string);
		default:
			return 0;
	}
}

function compareNumbers(a: number, b: number): number {
	return a < b ? -1 : a > b ? 1 : 0;
}

function compareBooleans(a: boolean, b: boolean): number {
	return a === b ? 0 : a ? 1 : -1;
}

const textEncoder = new TextEncoder();

/** Compares strings by the exact UTF-8 bytes used by SQLite BINARY ordering. */
function compareUtf8(a: string, b: string): number {
	if (isUtf8LexicalFastPath(a) && isUtf8LexicalFastPath(b)) {
		return compareLexically(a, b);
	}
	return compareUtf8Bytes(a, b);
}

function compareUtf8Bytes(a: string, b: string): number {
	const ba = textEncoder.encode(a);
	const bb = textEncoder.encode(b);
	const length = Math.min(ba.length, bb.length);
	for (let i = 0; i < length; i++) {
		if (ba[i] !== bb[i]) return ba[i] < bb[i] ? -1 : 1;
	}
	return ba.length < bb.length ? -1 : ba.length > bb.length ? 1 : 0;
}

function compareLexically(a: string, b: string): number {
	return a < b ? -1 : a > b ? 1 : 0;
}

function isUtf8LexicalFastPath(value: string): boolean {
	for (let i = 0; i < value.length; i += 1) {
		if (value.charCodeAt(i) >= 0x800) return false;
	}
	return true;
}
