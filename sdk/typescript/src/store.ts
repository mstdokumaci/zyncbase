// Store API

import type { ConnectionManager } from "./connection.js";
import { ErrorCodes, ZyncBaseError } from "./errors.js";
import { encodeWirePath, flatten, normalizePath, unflatten } from "./path.js";
import { buildComparator, type SubscriptionTracker } from "./subscriptions.js";
import type {
	BatchOperation,
	JsonValue,
	OkResponse,
	Path,
	QueryOptions,
	StoreDelta,
	StoreSubscribe,
	SubscriptionHandle,
} from "./types.js";
import { generateUUIDv7 } from "./uuid.js";

// ─── Operator codes ───────────────────────────────────────────────────────────

const OP_CODES: Record<string, number> = {
	eq: 0,
	ne: 1,
	gt: 2,
	lt: 3,
	gte: 4,
	lte: 5,
	contains: 6,
	startsWith: 7,
	endsWith: 8,
	in: 9,
	notIn: 10,
	isNull: 11,
	isNotNull: 12,
};

type WireCondition = [string, number] | [string, number, JsonValue];

/**
 * Encode a single condition object (e.g. { age: { gte: 18 } }) into wire tuples.
 * Nested field paths are flattened with `__`.
 */
function encodeOperatorObject(
	fieldKey: string,
	v: Record<string, JsonValue>,
	opKeys: string[],
): WireCondition[] {
	const conditions: WireCondition[] = [];
	for (const op of opKeys) {
		const code = OP_CODES[op];
		if (op === "isNull" || op === "isNotNull") {
			conditions.push([fieldKey, code]);
		} else {
			conditions.push([fieldKey, code, v[op] as JsonValue]);
		}
	}
	return conditions;
}

function encodeConditionObject(
	obj: Record<string, JsonValue | Record<string, JsonValue> | JsonValue[]>,
	prefix = "",
): WireCondition[] {
	const conditions: WireCondition[] = [];
	for (const [key, val] of Object.entries(obj)) {
		const fieldKey = prefix ? `${prefix}__${key}` : key;

		if (val === null || typeof val !== "object" || Array.isArray(val)) {
			// Direct equality
			conditions.push([fieldKey, OP_CODES.eq, val as JsonValue]);
			continue;
		}

		const v = val as Record<string, JsonValue>;
		// Check if this is an operator object (has known op keys)
		const opKeys = Object.keys(v).filter((k) => k in OP_CODES);
		if (opKeys.length > 0) {
			conditions.push(...encodeOperatorObject(fieldKey, v, opKeys));
		} else {
			// Nested field object — recurse
			conditions.push(
				...encodeConditionObject(
					v as Record<
						string,
						JsonValue | Record<string, JsonValue> | JsonValue[]
					>,
					fieldKey,
				),
			);
		}
	}
	return conditions;
}

/**
 * Encode SDK-side QueryOptions into wire-format fields for StoreQuery / StoreSubscribe.
 */
function extractOrConditions(
	or: Record<string, JsonValue | Record<string, JsonValue> | JsonValue[]>[],
): WireCondition[] {
	const orConditions: WireCondition[] = [];
	for (const clause of or) {
		orConditions.push(...encodeConditionObject(clause));
	}
	return orConditions;
}

function encodeWhereClause(
	where: Record<string, JsonValue | Record<string, JsonValue> | JsonValue[]>,
): {
	conditions?: WireCondition[];
	orConditions?: WireCondition[];
} {
	const { or, ...rest } = where;
	const result: {
		conditions?: WireCondition[];
		orConditions?: WireCondition[];
	} = {};
	const conditions = encodeConditionObject(rest);
	if (conditions.length > 0) result.conditions = conditions;
	if (Array.isArray(or)) {
		const orConditions = extractOrConditions(
			or as Record<
				string,
				JsonValue | Record<string, JsonValue> | JsonValue[]
			>[],
		);
		if (orConditions.length > 0) result.orConditions = orConditions;
	}
	return result;
}

function encodeOrderBy(
	orderBy: Record<string, "asc" | "desc">,
): [string, number] {
	const [field, dir] = Object.entries(orderBy)[0];
	return [field, dir === "desc" ? 1 : 0];
}

export function encodeQueryOptions(options: QueryOptions): {
	conditions?: WireCondition[];
	orConditions?: WireCondition[];
	orderBy?: [string, number];
	limit?: number;
	after?: string;
} {
	const result: ReturnType<typeof encodeQueryOptions> = {};

	if (options.where) {
		Object.assign(result, encodeWhereClause(options.where));
	}

	if (options.orderBy) {
		result.orderBy = encodeOrderBy(options.orderBy);
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

	async set(path: Path, value: JsonValue): Promise<void> {
		const segments = normalizePath(path);
		if (segments.length === 1) {
			throw new ZyncBaseError("store.set requires a path of depth 2 or more", {
				code: ErrorCodes.INVALID_PATH,
				category: "client",
				retryable: false,
			});
		}

		// Flatten object values for depth-2 writes
		let wireValue: JsonValue = value;
		if (
			segments.length === 2 &&
			value !== null &&
			typeof value === "object" &&
			!Array.isArray(value)
		) {
			wireValue = flatten(value as Record<string, JsonValue>);
		}
		const wirePath = encodeWirePath(segments);
		try {
			await this.conn.dispatch({
				type: "StoreSet",
				path: wirePath,
				value: wireValue,
			});
		} catch (err) {
			const e =
				err instanceof ZyncBaseError
					? err
					: new ZyncBaseError(
							err instanceof Error ? err.message : "Set failed",
							{
								code: ErrorCodes.INTERNAL_ERROR,
								category: "server",
								retryable: true,
							},
						);
			this.emitError?.(e);
			throw e;
		}
	}

	async remove(path: Path): Promise<void> {
		const segments = normalizePath(path);
		if (segments.length !== 2) {
			throw new ZyncBaseError(
				"store.remove requires a path of depth 2 (collection + document id)",
				{
					code: ErrorCodes.INVALID_PATH,
					category: "client",
					retryable: false,
				},
			);
		}

		const wirePath = encodeWirePath(segments);
		try {
			await this.conn.dispatch({ type: "StoreRemove", path: wirePath });
		} catch (err) {
			const e =
				err instanceof ZyncBaseError
					? err
					: new ZyncBaseError(
							err instanceof Error ? err.message : "Remove failed",
							{
								code: ErrorCodes.INTERNAL_ERROR,
								category: "server",
								retryable: true,
							},
						);
			this.emitError?.(e);
			throw e;
		}
	}

	// ─── Create ────────────────────────────────────────────────────────────────

	async create(collection: string, value: JsonValue): Promise<string> {
		const uuid = generateUUIDv7();
		const segments = [collection, uuid];
		let wireValue: JsonValue = value;
		if (value !== null && typeof value === "object" && !Array.isArray(value)) {
			wireValue = flatten(value as Record<string, JsonValue>);
		}
		const wirePath = encodeWirePath(segments);
		try {
			await this.conn.dispatch({
				type: "StoreSet",
				path: wirePath,
				value: wireValue,
			});
		} catch (err) {
			const e =
				err instanceof ZyncBaseError
					? err
					: new ZyncBaseError(
							err instanceof Error ? err.message : "Create failed",
							{
								code: ErrorCodes.INTERNAL_ERROR,
								category: "server",
								retryable: true,
							},
						);
			this.emitError?.(e);
			throw e;
		}
		return uuid;
	}

	async push(collection: string, value: JsonValue): Promise<string> {
		// For now, push is the same as create.
		return this.create(collection, value);
	}

	async update(path: Path, value: JsonValue): Promise<void> {
		// For now, update is synonymous with set (doc-level merging is handled by storage engine)
		return this.set(path, value);
	}

	// ─── Reads ─────────────────────────────────────────────────────────────────

	get(path: Path): Promise<JsonValue | null | undefined> {
		const segments = normalizePath(path);

		if (segments.length === 1) {
			// depth-1: query entire collection
			return this.conn
				.dispatch({
					type: "StoreQuery",
					table_index: segments[0],
				})
				.then((ok) => {
					const rows: JsonValue[] = (ok.value ?? []) as JsonValue[];
					return rows.map((row) =>
						row !== null && typeof row === "object" && !Array.isArray(row)
							? (unflatten(row as Record<string, JsonValue>) as JsonValue)
							: row,
					) as JsonValue;
				})
				.catch((err) => {
					this._emitError(err);
					throw err;
				});
		}

		if (segments.length === 2) {
			// depth-2: query by id
			return this.conn
				.dispatch({
					type: "StoreQuery",
					table_index: segments[0],
					conditions: [["id", 0, segments[1]]],
				})
				.then((ok) => {
					const rows: JsonValue[] = (ok.value ?? []) as JsonValue[];
					if (rows.length === 0) return null;
					const row = rows[0];
					return (
						row !== null && typeof row === "object" && !Array.isArray(row)
							? (unflatten(row as Record<string, JsonValue>) as JsonValue)
							: row
					) as JsonValue;
				});
		}

		// depth-3+: query by id, extract nested field
		return this.conn
			.dispatch({
				type: "StoreQuery",
				table_index: segments[0],
				conditions: [["id", 0, segments[1]]],
			})
			.then((ok) => {
				const rows: JsonValue[] = (ok.value ?? []) as JsonValue[];
				if (rows.length === 0) return undefined;
				const record = unflatten(
					rows[0] as Record<string, JsonValue>,
				) as Record<string, JsonValue>;

				let val: JsonValue | undefined = record as JsonValue;
				for (const part of segments.slice(2)) {
					if (
						val === null ||
						typeof val !== "object" ||
						!(part in (val as Record<string, JsonValue>))
					) {
						throw new ZyncBaseError(
							`Field ${part} not found at path ${segments.join(".")}`,
							{
								code: ErrorCodes.FIELD_NOT_FOUND,
								category: "client",
								retryable: false,
							},
						);
					}
					val = (val as Record<string, JsonValue>)[part];
				}
				return val;
			});
	}

	query(
		collection: string,
		options?: QueryOptions,
	): Promise<JsonValue[] & { nextCursor: string | null }> {
		const encoded = options ? encodeQueryOptions(options) : {};
		return this.conn
			.dispatch({
				type: "StoreQuery",
				table_index: collection,
				...encoded,
			})
			.then((ok) => {
				const rows = (ok.value ?? []).map((row: JsonValue) =>
					row !== null && typeof row === "object" && !Array.isArray(row)
						? (unflatten(row as Record<string, JsonValue>) as JsonValue)
						: row,
				);
				const result = rows as JsonValue[] & { nextCursor: string | null };
				result.nextCursor = ok.nextCursor ?? null;
				return result;
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
				}),
			);
		}

		const wireOps: (["s", string[], JsonValue] | ["r", string[]])[] = [];
		for (const op of operations) {
			const segments = normalizePath(op.path);
			const wirePath = encodeWirePath(segments);

			if (op.op === "remove") {
				wireOps.push(["r", wirePath]);
				continue;
			}

			let wireValue: JsonValue | undefined = op.value;
			if (
				segments.length === 2 &&
				wireValue !== null &&
				typeof wireValue === "object" &&
				!Array.isArray(wireValue)
			) {
				wireValue = flatten(
					wireValue as Record<string, JsonValue>,
				) as JsonValue;
			}
			wireOps.push(["s", wirePath, wireValue ?? null]);
		}

		return this.conn
			.dispatch({ type: "StoreBatch", ops: wireOps })
			.then(() => undefined);
	}

	// ─── Subscriptions ─────────────────────────────────────────────────────────

	private _handleSubscriptionResponse(
		ok: { subId?: number; value?: JsonValue },
		segments: string[],
		subscribeParams: Omit<StoreSubscribe, "id">,
		callback: (value: JsonValue) => void,
		projection: import("./subscriptions.js").ListenProjection,
		unlistenState: { unlistenCalled: boolean },
	): void {
		if (unlistenState.unlistenCalled) {
			if (ok.subId !== undefined) {
				this.conn
					.dispatch({ type: "StoreUnsubscribe", subId: ok.subId })
					.catch(() => {});
			}
			return;
		}

		const subId = ok.subId ?? null;
		if (subId === null) return;

		this.tracker.register(subId, {
			params: subscribeParams,
			callbacks: [callback as (value: unknown) => void],
			projection,
		});

		// Feed initial snapshot if provided
		if (ok.value !== undefined) {
			this._dispatchInitialSnapshot(subId, segments, ok.value);
		}
	}

	private _dispatchInitialSnapshot(
		subId: number,
		segments: string[],
		value: JsonValue,
	): void {
		const delta: StoreDelta = { type: "StoreDelta", subId, ops: [] };
		const collection = segments[0];

		if (Array.isArray(value)) {
			for (const item of value as JsonValue[]) {
				const op = this._createInitialSnapshotOp(collection, segments, item);
				if (op) delta.ops.push(op);
			}
		} else if (value !== null) {
			const op = this._createInitialSnapshotOp(collection, segments, value);
			if (op) delta.ops.push(op);
		}

		this.tracker.dispatch(delta);
	}

	private _createInitialSnapshotOp(
		collection: string,
		segments: string[],
		item: JsonValue,
	): { op: "set"; path: string[]; value: JsonValue } | null {
		if (item === null || typeof item !== "object" || Array.isArray(item)) {
			return null;
		}

		const val = item as Record<string, JsonValue>;
		const id =
			(val.id as string) || (segments.length > 1 ? segments[1] : undefined);

		if (!id) return null;

		return {
			op: "set" as const,
			path: [collection, id],
			value: item,
		};
	}

	listen(path: Path, callback: (value: JsonValue) => void): () => void {
		const segments = normalizePath(path);

		if (segments.length === 1) {
			throw new ZyncBaseError(
				"store.listen at collection level is not supported. Use store.subscribe() instead.",
				{ code: ErrorCodes.INVALID_PATH, category: "client", retryable: false },
			);
		}

		const subscribeParams: Omit<StoreSubscribe, "id"> = {
			type: "StoreSubscribe",
			namespace: this.conn.getStoreNamespace(),
			table_index: segments[0],
			conditions: [["id", 0, segments[1]]],
		};
		const field = segments.length === 2 ? null : segments.slice(2).join(".");
		const projection = { field, depth: segments.length };

		const unlistenState = {
			unlistenCalled: false,
			subId: null as number | null,
		};

		this.conn
			.dispatch({ ...subscribeParams })
			.then((ok) => {
				unlistenState.subId = ok.subId ?? null;
				this._handleSubscriptionResponse(
					ok,
					segments,
					subscribeParams,
					callback,
					projection,
					unlistenState,
				);
			})
			.catch((err) => {
				this._emitError(err);
			});

		return () => {
			unlistenState.unlistenCalled = true;
			if (unlistenState.subId !== null) {
				this.tracker.unregister(unlistenState.subId);
				this.conn
					.dispatch({ type: "StoreUnsubscribe", subId: unlistenState.subId })
					.catch(() => {});
				unlistenState.subId = null;
			}
		};
	}

	subscribe(
		collection: string,
		options: QueryOptions,
		callback: (results: JsonValue[]) => void,
	): SubscriptionHandle {
		const encoded = encodeQueryOptions(options);
		const subscribeParams: Omit<StoreSubscribe, "id"> = {
			type: "StoreSubscribe",
			namespace: this.conn.getStoreNamespace(),
			table_index: collection,
			...encoded,
		};

		const state = {
			subId: null as number | null,
			nextCursor: null as string | null,
			hasMore: false,
			unsubscribeCalled: false,
		};

		const handle = this._createSubscriptionHandle(state, collection);

		this.conn
			.dispatch({ ...subscribeParams })
			.then((ok) => {
				this._handleSubscribeSuccess(
					ok,
					state,
					handle,
					collection,
					subscribeParams,
					options,
					callback,
				);
			})
			.catch(() => {});

		return handle;
	}

	private _handleSubscribeSuccess(
		ok: OkResponse,
		state: {
			subId: number | null;
			nextCursor: string | null;
			hasMore: boolean;
			unsubscribeCalled: boolean;
		},
		handle: SubscriptionHandle,
		collection: string,
		subscribeParams: Omit<StoreSubscribe, "id">,
		options: QueryOptions,
		callback: (results: JsonValue[]) => void,
	): void {
		if (state.unsubscribeCalled) {
			if (ok.subId !== undefined) {
				this.conn
					.dispatch({ type: "StoreUnsubscribe", subId: ok.subId })
					.catch(() => {});
			}
			return;
		}

		state.subId = ok.subId ?? null;
		state.nextCursor = ok.nextCursor ?? null;
		state.hasMore = ok.hasMore ?? false;
		handle.hasMore = state.hasMore;

		if (state.subId !== null) {
			this.tracker.register(state.subId, {
				params: subscribeParams,
				callbacks: [callback as (v: JsonValue) => void],
				projection: null,
				materializedView: {
					records: new Map(),
					collection,
					comparator: buildComparator(options.orderBy),
				},
			});

			if (ok.value !== undefined) {
				this._dispatchInitialSnapshot(state.subId, [collection], ok.value);
			}
		}
	}

	private _createSubscriptionHandle(
		state: {
			subId: number | null;
			nextCursor: string | null;
			hasMore: boolean;
			unsubscribeCalled: boolean;
		},
		collection: string,
	): SubscriptionHandle {
		const handle: SubscriptionHandle = {
			hasMore: false,
			unsubscribe: () => {
				state.unsubscribeCalled = true;
				if (state.subId !== null) {
					this.tracker.unregister(state.subId);
					this.conn
						.dispatch({ type: "StoreUnsubscribe", subId: state.subId })
						.catch(() => {});
					state.subId = null;
				}
			},
			loadMore: (): Promise<void> => {
				if (state.subId === null || state.nextCursor === null) {
					return Promise.resolve();
				}
				const cursor = state.nextCursor;
				return this.conn
					.dispatch({
						type: "StoreLoadMore",
						subId: state.subId,
						nextCursor: cursor,
						table_index: collection,
					})
					.then((ok) => {
						state.nextCursor = ok.nextCursor ?? null;
						state.hasMore = ok.hasMore ?? false;
						handle.hasMore = state.hasMore;

						// Feed loaded rows into the materialized view
						if (state.subId !== null && ok.value !== undefined) {
							this._dispatchInitialSnapshot(
								state.subId,
								[collection],
								ok.value,
							);
						}
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
			this.emitError(
				new ZyncBaseError(err.message, {
					code: ErrorCodes.INTERNAL_ERROR,
					category: "server",
					retryable: true,
				}),
			);
		}
	}
}
