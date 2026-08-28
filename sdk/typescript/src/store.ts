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
import type { SubscriptionTracker } from "./subscriptions.js";
import type {
	BatchOperation,
	InboundMessage,
	JsonValue,
	LifecycleEvent,
	OkResponse,
	Path,
	QueryOptions,
	SubscriptionHandle,
	WriteOptions,
} from "./types.js";
import { generateUUIDv7 } from "./uuid.js";

/** The subset of ConnectionManager that StoreImpl depends on. */
export interface StoreConnection {
	dispatch(msg: OutboundRequest): Promise<OkResponse>;
	onMessage(handler: (msg: InboundMessage) => void): void;
	on(event: LifecycleEvent, handler: (...args: unknown[]) => void): void;
	isSchemaReady(): boolean;
	readonly schemaDictionary: SchemaDictionary;
}

interface SubscribeState {
	subId: number | null;
	nextCursor: string | null;
	hasMore: boolean;
	closed: boolean;
	inFlight: Promise<void> | null;
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

	constructor(
		private readonly conn: StoreConnection,
		private readonly tracker: SubscriptionTracker,
		private readonly emitError: (err: ZyncBaseError) => void = () => {},
	) {
		this.conn.onMessage((msg) => this.handleInboundMessage(msg));
		this.conn.on("disconnected", () => this.rejectAllInFlight());
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

	listen(path: Path, callback: (value: JsonValue) => void): () => void {
		const command = buildListen(path);
		const state = {
			closed: false,
			subId: null as number | null,
		};

		this.conn
			.dispatch(command.message)
			.then((ok) => {
				if (state.closed) {
					if (ok.subId !== undefined) {
						this.dispatchUnsubscribe(ok.subId);
					}
					return;
				}

				state.subId = ok.subId ?? null;
				if (state.subId === null) return;

				this.tracker.registerListen(
					state.subId,
					command.message,
					callback,
					command.segments,
				);
				if (ok.value !== undefined) {
					this.tracker.dispatchInitialSnapshot(
						state.subId,
						command.segments,
						ok.value as JsonValue,
					);
				}
			})
			.catch((err) => this.emitOnly(err, "Listen failed"));

		return () => {
			state.closed = true;
			if (state.subId === null) return;
			this.tracker.unregister(state.subId);
			this.dispatchUnsubscribe(state.subId);
			state.subId = null;
		};
	}

	subscribe(
		collection: string,
		options: QueryOptions,
		callback: (results: JsonValue[]) => void,
	): SubscriptionHandle {
		const state: SubscribeState = {
			subId: null,
			nextCursor: null,
			hasMore: false,
			closed: false,
			inFlight: null,
		};

		const handle: SubscriptionHandle = {
			hasMore: false,
			unsubscribe: () => {
				state.closed = true;
				if (state.subId === null) return;
				this.tracker.unregister(state.subId);
				this.dispatchUnsubscribe(state.subId);
				state.subId = null;
			},
			loadMore: async () => {
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
					const ok = await this.conn.dispatch(buildLoadMore(subId, nextCursor));
					const decoded = this.decodeLoadMoreRows(
						ok.value as JsonValue,
						collection,
					);
					state.nextCursor = ok.nextCursor ?? null;
					state.hasMore = ok.hasMore ?? false;
					handle.hasMore = state.hasMore;
					if (state.subId !== null && decoded !== undefined) {
						this.tracker.dispatchInitialSnapshot(
							state.subId,
							[collection],
							decoded,
						);
					}
				})();
				state.inFlight = promise;
				try {
					await promise;
				} finally {
					state.inFlight = null;
				}
			},
		};

		if (!this.conn.isSchemaReady()) {
			this.emitOnly(
				new ZyncBaseError(
					"Schema is not ready; await client.connect() before subscribing",
					{
						code: ErrorCodes.SESSION_NOT_READY,
						category: "state",
						retryable: false,
					},
				),
				"Subscribe failed",
			);
			return handle;
		}

		const command = buildSubscribe(collection, options);
		const comparator = this.buildCollectionComparator(collection, options);

		this.conn
			.dispatch(command.message)
			.then((ok) =>
				this.handleSubscribeSuccess(
					ok,
					state,
					handle,
					command.message,
					collection,
					comparator,
					callback,
				),
			)
			.catch((err) => this.emitOnly(err, "Subscribe failed"));

		return handle;
	}

	private handleSubscribeSuccess(
		ok: OkResponse,
		state: SubscribeState,
		handle: SubscriptionHandle,
		params: Parameters<SubscriptionTracker["registerCollection"]>[1],
		collection: string,
		comparator: (a: JsonValue, b: JsonValue) => number,
		callback: (results: JsonValue[]) => void,
	): void {
		if (this.unsubscribeRemoteIfClosed(state.closed, ok.subId)) return;

		state.subId = ok.subId ?? null;
		state.nextCursor = ok.nextCursor ?? null;
		state.hasMore = ok.hasMore ?? false;
		handle.hasMore = state.hasMore;
		if (state.subId === null) return;

		this.tracker.registerCollection(state.subId, params, callback, comparator);
		if (ok.value !== undefined) {
			this.tracker.dispatchInitialSnapshot(
				state.subId,
				[collection],
				ok.value as JsonValue,
			);
		}
	}

	/**
	 * Builds the schema-aware materialized-view comparator for a subscription.
	 * Mirrors the server's canonical order: public dot-path clauses in order,
	 * nulls always last, packed DocId order for reference fields, UTF-8 byte
	 * order for text, plus the hidden `id ASC` tie-breaker unless `id` is
	 * already the final explicit clause.
	 */
	private buildCollectionComparator(
		collection: string,
		options: QueryOptions,
	): (a: JsonValue, b: JsonValue) => number {
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

		const hasExplicitId = entries.some(
			(entry) => entry.parts.length === 1 && entry.parts[0] === "id",
		);
		if (!hasExplicitId) {
			entries.push({ parts: ["id"], desc: false, docId: true });
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

	private decodeLoadMoreRows(value: JsonValue, collection: string): JsonValue {
		if (
			!Array.isArray(value) ||
			value.length === 0 ||
			!Array.isArray(value[0])
		) {
			return value;
		}
		const isValid = (value as Array<unknown>).every(
			(row) =>
				Array.isArray(row) &&
				row.length > 0 &&
				(row as Array<unknown>).every(
					(t) => Array.isArray(t) && t.length === 2 && typeof t[0] === "number",
				),
		);
		if (!isValid) return value;
		const tableIndex = this.conn.schemaDictionary.getTableIndex(collection);
		return (value as Array<Array<[number, unknown]>>).map((row) =>
			this.conn.schemaDictionary.decodeValue(tableIndex, row),
		) as JsonValue;
	}

	private dispatchUnsubscribe(subId: number): void {
		this.conn.dispatch(buildUnsubscribe(subId)).catch(() => {});
	}

	private unsubscribeRemoteIfClosed(closed: boolean, subId?: number): boolean {
		if (!closed) return false;
		if (subId !== undefined) {
			this.dispatchUnsubscribe(subId);
		}
		return true;
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

	private emitOnly(err: unknown, fallbackMessage: string): void {
		this.emitError(this.normalizeError(err, fallbackMessage));
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
