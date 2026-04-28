import { ErrorCodes, ZyncBaseError } from "./errors.js";
import { encodeWirePath, flatten, normalizePath, unflatten } from "./path.js";
import type {
	BatchOperation,
	JsonValue,
	OkResponse,
	Path,
	QueryOptions,
	StoreBatch,
	StoreLoadMore,
	StoreQuery,
	StoreRemove,
	StoreSet,
	StoreSubscribe,
	StoreUnsubscribe,
} from "./types.js";

type WithoutId<T extends { id: number }> = Omit<T, "id">;

export interface StoreCommand<TMessage> {
	segments: string[];
	message: TMessage;
}

export type WireCondition = [string, number] | [string, number, JsonValue];

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

export function buildSet(
	path: Path,
	value: JsonValue,
): StoreCommand<WithoutId<StoreSet>> {
	const segments = normalizePath(path);
	if (segments.length === 1) {
		throw new ZyncBaseError("store.set requires a path of depth 2 or more", {
			code: ErrorCodes.INVALID_PATH,
			category: "client",
			retryable: false,
		});
	}

	return {
		segments,
		message: {
			type: "StoreSet",
			path: encodeWirePath(segments),
			value: encodeWriteValue(segments, value),
		},
	};
}

export function buildRemove(path: Path): StoreCommand<WithoutId<StoreRemove>> {
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

	return {
		segments,
		message: { type: "StoreRemove", path: encodeWirePath(segments) },
	};
}

export function buildCreate(
	collection: string,
	value: JsonValue,
	id: string,
): StoreCommand<WithoutId<StoreSet>> {
	const segments = [collection, id];
	return {
		segments,
		message: {
			type: "StoreSet",
			path: encodeWirePath(segments),
			value: encodeWriteValue(segments, value),
		},
	};
}

export function buildGet(path: Path): StoreCommand<WithoutId<StoreQuery>> {
	const segments = normalizePath(path);
	return {
		segments,
		message: buildIdQuery(segments),
	};
}

export function buildQuery(
	collection: string,
	options?: QueryOptions,
): StoreCommand<WithoutId<StoreQuery>> {
	return {
		segments: [collection],
		message: {
			type: "StoreQuery",
			table_index: collection,
			...(options ? encodeQueryOptions(options) : {}),
		},
	};
}

export function buildBatch(
	operations: BatchOperation[],
): WithoutId<StoreBatch> {
	if (operations.length > 500) {
		throw new ZyncBaseError("Batch exceeds maximum of 500 operations", {
			code: ErrorCodes.BATCH_TOO_LARGE,
			category: "client",
			retryable: false,
		});
	}

	const ops: StoreBatch["ops"] = [];
	for (const op of operations) {
		const segments = normalizePath(op.path);
		const wirePath = encodeWirePath(segments);
		if (op.op === "remove") {
			ops.push(["r", wirePath]);
			continue;
		}
		ops.push(["s", wirePath, encodeWriteValue(segments, op.value ?? null)]);
	}

	return { type: "StoreBatch", ops };
}

export function buildListen(
	path: Path,
): StoreCommand<Omit<StoreSubscribe, "id">> {
	const segments = normalizePath(path);
	if (segments.length === 1) {
		throw new ZyncBaseError(
			"store.listen at collection level is not supported. Use store.subscribe() instead.",
			{ code: ErrorCodes.INVALID_PATH, category: "client", retryable: false },
		);
	}

	return {
		segments,
		message: {
			type: "StoreSubscribe",
			table_index: segments[0],
			conditions: [["id", 0, segments[1]]],
		},
	};
}

export function buildSubscribe(
	collection: string,
	options: QueryOptions,
): StoreCommand<Omit<StoreSubscribe, "id">> {
	return {
		segments: [collection],
		message: {
			type: "StoreSubscribe",
			table_index: collection,
			...encodeQueryOptions(options),
		},
	};
}

export function buildUnsubscribe(subId: number): Omit<StoreUnsubscribe, "id"> {
	return { type: "StoreUnsubscribe", subId };
}

export function buildLoadMore(
	subId: number,
	nextCursor: string,
	collection: string,
): Omit<StoreLoadMore, "id"> {
	return {
		type: "StoreLoadMore",
		subId,
		nextCursor,
		table_index: collection,
	};
}

export function shapeGetResult(
	segments: string[],
	rows: JsonValue[],
): JsonValue | null | undefined {
	if (segments.length === 1) {
		return rows.map(unflattenIfObject) as JsonValue;
	}

	if (rows.length === 0) return segments.length === 2 ? null : undefined;

	const row = rows[0];
	if (segments.length === 2) return unflattenIfObject(row);

	const record = unflatten(row as Record<string, JsonValue>) as Record<
		string,
		JsonValue
	>;
	let value: JsonValue | undefined = record as JsonValue;
	for (const part of segments.slice(2)) {
		if (
			value === null ||
			typeof value !== "object" ||
			!(part in (value as Record<string, JsonValue>))
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
		value = (value as Record<string, JsonValue>)[part];
	}
	return value;
}

export function shapeQueryResult(
	ok: OkResponse,
): JsonValue[] & { nextCursor: string | null } {
	const rows = (ok.value ?? []).map(unflattenIfObject);
	const result = rows as JsonValue[] & { nextCursor: string | null };
	result.nextCursor = ok.nextCursor ?? null;
	return result;
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

function buildIdQuery(segments: string[]): Omit<StoreQuery, "id"> {
	if (segments.length === 1) {
		return { type: "StoreQuery", table_index: segments[0] };
	}
	return {
		type: "StoreQuery",
		table_index: segments[0],
		conditions: [["id", 0, segments[1]]],
	};
}

function encodeWriteValue(segments: string[], value: JsonValue): JsonValue {
	if (segments.length === 2 && isObjectRecord(value)) {
		return flatten(value);
	}
	return value;
}

function unflattenIfObject(row: JsonValue): JsonValue {
	return isObjectRecord(row) ? (unflatten(row) as JsonValue) : row;
}

function isObjectRecord(value: JsonValue): value is Record<string, JsonValue> {
	return value !== null && typeof value === "object" && !Array.isArray(value);
}

function encodeOperatorObject(
	fieldKey: string,
	value: Record<string, JsonValue>,
	opKeys: string[],
): WireCondition[] {
	const conditions: WireCondition[] = [];
	for (const op of opKeys) {
		const code = OP_CODES[op];
		if (op === "isNull" || op === "isNotNull") {
			conditions.push([fieldKey, code]);
		} else {
			conditions.push([fieldKey, code, value[op] as JsonValue]);
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
			conditions.push([fieldKey, OP_CODES.eq, val as JsonValue]);
			continue;
		}

		const value = val as Record<string, JsonValue>;
		const opKeys = Object.keys(value).filter((op) => op in OP_CODES);
		if (opKeys.length > 0) {
			conditions.push(...encodeOperatorObject(fieldKey, value, opKeys));
		} else {
			conditions.push(
				...encodeConditionObject(
					value as Record<
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
