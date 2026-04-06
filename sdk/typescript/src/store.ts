// Store API

import type { ConnectionManager } from "./connection.js";
import { ErrorCodes, ZyncBaseError } from "./errors.js";
import { encodeWirePath, normalizePath } from "./path.js";
import type { SubscriptionTracker } from "./subscriptions.js";
import type {
	BatchOperation,
	Path,
	QueryOptions,
	StoreDelta,
	StoreSubscribe,
	SubscriptionHandle,
} from "./types.js";
import { generateUUIDv7 } from "./uuid.js";

/**
 * Recursively flatten a nested object using `__` as the key separator.
 * Arrays are stored as-is (not flattened).
 *
 * Example:
 *   flatten({ a: { b: 1, c: 2 } }) → { "a__b": 1, "a__c": 2 }
 */
export function flatten(
	obj: Record<string, unknown>,
	prefix = "",
): Record<string, unknown> {
	const result: Record<string, unknown> = {};
	for (const key of Object.keys(obj)) {
		const fullKey = prefix ? `${prefix}__${key}` : key;
		const value = obj[key];
		if (value !== null && typeof value === "object" && !Array.isArray(value)) {
			const nested = flatten(value as Record<string, unknown>, fullKey);
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
export function unflatten(
	obj: Record<string, unknown>,
): Record<string, unknown> {
	const result: Record<string, unknown> = {};
	for (const key of Object.keys(obj)) {
		const parts = key.split("__");
		let current = result;
		for (let i = 0; i < parts.length - 1; i++) {
			const part = parts[i];
			if (
				current[part] === undefined ||
				typeof current[part] !== "object" ||
				Array.isArray(current[part])
			) {
				current[part] = {};
			}
			current = current[part] as Record<string, unknown>;
		}
		current[parts[parts.length - 1]] = obj[key];
	}
	return result;
}

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

type WireCondition = [string, number] | [string, number, unknown];

/**
 * Encode a single condition object (e.g. { age: { gte: 18 } }) into wire tuples.
 * Nested field paths are flattened with `__`.
 */
function encodeOperatorObject(
	fieldKey: string,
	v: Record<string, unknown>,
	opKeys: string[],
): WireCondition[] {
	const conditions: WireCondition[] = [];
	for (const op of opKeys) {
		const code = OP_CODES[op];
		if (op === "isNull" || op === "isNotNull") {
			conditions.push([fieldKey, code]);
		} else {
			conditions.push([fieldKey, code, v[op]]);
		}
	}
	return conditions;
}

function encodeConditionObject(
	obj: Record<string, unknown>,
	prefix = "",
): WireCondition[] {
	const conditions: WireCondition[] = [];
	for (const [key, val] of Object.entries(obj)) {
		const fieldKey = prefix ? `${prefix}__${key}` : key;

		if (val === null || typeof val !== "object" || Array.isArray(val)) {
			// Direct equality
			conditions.push([fieldKey, OP_CODES.eq, val]);
			continue;
		}

		const v = val as Record<string, unknown>;
		// Check if this is an operator object (has known op keys)
		const opKeys = Object.keys(v).filter((k) => k in OP_CODES);
		if (opKeys.length > 0) {
			conditions.push(...encodeOperatorObject(fieldKey, v, opKeys));
		} else {
			// Nested field object — recurse
			conditions.push(...encodeConditionObject(v, fieldKey));
		}
	}
	return conditions;
}

/**
 * Encode SDK-side QueryOptions into wire-format fields for StoreQuery / StoreSubscribe.
 */
function extractOrConditions(or: unknown[]): WireCondition[] {
	const orConditions: WireCondition[] = [];
	for (const clause of or) {
		orConditions.push(
			...encodeConditionObject(clause as Record<string, unknown>),
		);
	}
	return orConditions;
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
		const { or, ...rest } = options.where as Record<string, unknown>;
		const conditions = encodeConditionObject(rest);
		if (conditions.length > 0) result.conditions = conditions;

		if (Array.isArray(or)) {
			const orConditions = extractOrConditions(or);
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

	async set(path: Path, value: unknown): Promise<void> {
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
			wireValue = flatten(value as Record<string, unknown>);
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

	async create(collection: string, value: unknown): Promise<string> {
		const uuid = generateUUIDv7();
		const segments = [collection, uuid];
		let wireValue = value;
		if (value !== null && typeof value === "object" && !Array.isArray(value)) {
			wireValue = flatten(value as Record<string, unknown>);
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

	async push(collection: string, value: unknown): Promise<string> {
		// For now, push is the same as create.
		return this.create(collection, value);
	}

	async update(path: Path, value: unknown): Promise<void> {
		// For now, update is synonymous with set (doc-level merging is handled by storage engine)
		return this.set(path, value);
	}

	// ─── Reads ─────────────────────────────────────────────────────────────────

	get(path: Path): Promise<unknown> {
		const segments = normalizePath(path);

		if (segments.length === 1) {
			// depth-1: query entire collection
			return this.conn
				.dispatch({
					type: "StoreQuery",
					collection: segments[0],
				})
				.then((ok) => {
					const rows: unknown[] = ok.value ?? [];
					return rows.map((row) =>
						row !== null && typeof row === "object" && !Array.isArray(row)
							? unflatten(row as Record<string, unknown>)
							: row,
					);
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
					collection: segments[0],
					conditions: [["id", 0, segments[1]]],
				})
				.then((ok) => {
					const rows: unknown[] = ok.value ?? [];
					if (rows.length === 0) return null;
					const row = rows[0];
					return row !== null && typeof row === "object" && !Array.isArray(row)
						? unflatten(row as Record<string, unknown>)
						: row;
				});
		}

		// depth-3+: query by id, extract nested field
		return this.conn
			.dispatch({
				type: "StoreQuery",
				collection: segments[0],
				conditions: [["id", 0, segments[1]]],
			})
			.then((ok) => {
				const rows: unknown[] = ok.value ?? [];
				if (rows.length === 0) return undefined;
				const record = unflatten(rows[0] as Record<string, unknown>);

				let val: unknown = record;
				for (const part of segments.slice(2)) {
					if (
						val === null ||
						typeof val !== "object" ||
						!(part in (val as Record<string, unknown>))
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
					val = (val as Record<string, unknown>)[part];
				}
				return val;
			});
	}

	query(
		collection: string,
		options?: QueryOptions,
	): Promise<unknown[] & { nextCursor: string | null }> {
		const encoded = options ? encodeQueryOptions(options) : {};
		return this.conn
			.dispatch({
				type: "StoreQuery",
				collection,
				...encoded,
			})
			.then((ok) => {
				const rows = (ok.value ?? []).map((row: unknown) =>
					row !== null && typeof row === "object" && !Array.isArray(row)
						? unflatten(row as Record<string, unknown>)
						: row,
				);
				const result = rows as unknown[] & { nextCursor: string | null };
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

		const wireOps: (["s", string[], unknown] | ["r", string[]])[] = [];
		for (const op of operations) {
			const segments = normalizePath(op.path);
			const wirePath = encodeWirePath(segments);

			if (op.op === "remove") {
				wireOps.push(["r", wirePath]);
				continue;
			}

			let wireValue = op.value;
			if (
				segments.length === 2 &&
				wireValue !== null &&
				typeof wireValue === "object" &&
				!Array.isArray(wireValue)
			) {
				wireValue = flatten(wireValue as Record<string, unknown>);
			}
			wireOps.push(["s", wirePath, wireValue]);
		}

		return this.conn
			.dispatch({ type: "StoreBatch", ops: wireOps })
			.then(() => undefined);
	}

	// ─── Subscriptions ─────────────────────────────────────────────────────────

	private _handleSubscriptionResponse(
		ok: { subId?: number; value?: unknown },
		segments: string[],
		subscribeParams: Omit<StoreSubscribe, "id">,
		callback: (value: unknown) => void,
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
			callbacks: [callback],
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
		value: unknown,
	): void {
		const delta: StoreDelta = { type: "StoreDelta", subId, ops: [] };
		const collection = segments[0];

		if (Array.isArray(value)) {
			for (const item of value as unknown[]) {
				const i = item as Record<string, unknown>;
				const id = (i.id as string) || segments[1];
				delta.ops.push({ op: "set", path: [collection, id], value: item });
			}
		} else if (value !== null) {
			const val = value as Record<string, unknown>;
			const id = (val.id as string) || segments[1];
			delta.ops.push({ op: "set", path: [collection, id], value: val });
		}

		this.tracker.dispatch(delta);
	}

	listen(path: Path, callback: (value: unknown) => void): () => void {
		const segments = normalizePath(path);
		let subscribeParams: Omit<StoreSubscribe, "id">;
		let projection: import("./subscriptions.js").ListenProjection;

		if (segments.length === 1) {
			subscribeParams = {
				type: "StoreSubscribe",
				namespace: this.conn.getStoreNamespace(),
				collection: segments[0],
			};
			projection = { field: null, depth: 1 };
		} else {
			subscribeParams = {
				type: "StoreSubscribe",
				namespace: this.conn.getStoreNamespace(),
				collection: segments[0],
				conditions: [["id", 0, segments[1]]],
			};
			const field = segments.length === 2 ? null : segments.slice(2).join(".");
			projection = { field, depth: segments.length };
		}

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
		callback: (results: unknown[]) => void,
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

		this.conn
			.dispatch({ ...subscribeParams })
			.then((ok) => {
				if (unsubscribeCalled) {
					if (ok.subId !== undefined) {
						this.conn
							.dispatch({ type: "StoreUnsubscribe", subId: ok.subId })
							.catch(() => {});
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
						callbacks: [callback as (v: unknown) => void],
						projection: null,
					});
				}
			})
			.catch(() => {});

		const handle: SubscriptionHandle = {
			hasMore: false,
			unsubscribe: () => {
				unsubscribeCalled = true;
				if (subId !== null) {
					this.tracker.unregister(subId);
					this.conn
						.dispatch({ type: "StoreUnsubscribe", subId })
						.catch(() => {});
					subId = null;
				}
			},
			loadMore: (): Promise<void> => {
				if (subId === null || nextCursor === null) {
					return Promise.resolve();
				}
				const cursor = nextCursor;
				return this.conn
					.dispatch({
						type: "StoreLoadMore",
						subId,
						nextCursor: cursor,
					})
					.then((ok) => {
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
