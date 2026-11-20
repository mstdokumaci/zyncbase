// Pending local writes, applied over server records until they settle.

import type { OutboundRequest } from "./connection_wire.js";
import { flatten, unflatten } from "./path.js";
import type { SchemaDictionary } from "./schema_dictionary.js";
import type { JsonValue } from "./types.js";
import { sortedSet } from "./value_order.js";

type Flat = Record<string, JsonValue>;

/** One document change of a write, in the flat `__` field form. */
export type OverlayOp =
	| { kind: "create"; collection: string; id: string; record: Flat }
	| { kind: "set"; collection: string; id: string; patch: Flat }
	| { kind: "remove"; collection: string; id: string }
	| {
			kind: "increment";
			collection: string;
			id: string;
			field: string;
			by: number;
			time: number;
	  };

/** Documents touched by writes: collection → ids. */
export type OverlayKeys = Map<string, Set<string>>;

/** A write's handle in `PendingWrites`. */
export interface PendingEntry {
	readonly seq: number;
	readonly keys: OverlayKeys;
}

interface KeyOps {
	seq: number;
	ops: OverlayOp[];
}

/**
 * Pending writes per document, in send order. The server applies writes in
 * send order and never retries one, so a commit also settles every earlier
 * write's changes to the same documents: they are applied or failed already.
 */
export class PendingWrites {
	private readonly docs = new Map<string, Map<string, KeyOps[]>>();
	private seq = 0;

	add(ops: readonly OverlayOp[]): PendingEntry {
		const seq = ++this.seq;
		const keys: OverlayKeys = new Map();
		for (const op of ops) {
			const ids = keys.get(op.collection) ?? new Set<string>();
			keys.set(op.collection, ids.add(op.id));
			const byId = this.docs.get(op.collection) ?? new Map<string, KeyOps[]>();
			this.docs.set(op.collection, byId);
			const list = byId.get(op.id) ?? [];
			byId.set(op.id, list);
			const last = list[list.length - 1];
			if (last?.seq === seq) last.ops.push(op);
			else list.push({ seq, ops: [op] });
		}
		return { seq, keys };
	}

	/** The write committed: drop it and every earlier write on its documents. */
	commit(entry: PendingEntry): OverlayKeys {
		return this.drop(entry, (ops) => ops.seq <= entry.seq);
	}

	/** The write failed: drop only it. */
	fail(entry: PendingEntry): OverlayKeys {
		return this.drop(entry, (ops) => ops.seq === entry.seq);
	}

	/** Drop every pending write; returns the documents they touched. */
	clear(): OverlayKeys {
		const keys: OverlayKeys = new Map();
		for (const [collection, byId] of this.docs) {
			keys.set(collection, new Set(byId.keys()));
		}
		this.docs.clear();
		return keys;
	}

	has(collection: string, id: string): boolean {
		return this.docs.get(collection)?.has(id) ?? false;
	}

	/** Whether any document in `collection` has a pending write. */
	touches(collection: string): boolean {
		return this.docs.has(collection);
	}

	/** Ids in `collection` with pending writes. */
	ids(collection: string): Iterable<string> {
		return this.docs.get(collection)?.keys() ?? [];
	}

	/**
	 * Applies the document's pending writes, in send order, to `base` (the
	 * server record, or null when unknown or absent). Returns null when the
	 * result is no document.
	 */
	apply(
		collection: string,
		id: string,
		base: JsonValue | null,
	): JsonValue | null {
		let value = isRecord(base) ? flatten(base) : null;
		for (const { ops } of this.docs.get(collection)?.get(id) ?? []) {
			for (const op of ops) value = applyOp(value, op);
		}
		return value === null ? null : unflatten(value);
	}

	private drop(
		entry: PendingEntry,
		settled: (ops: KeyOps) => boolean,
	): OverlayKeys {
		for (const [collection, ids] of entry.keys) {
			const byId = this.docs.get(collection);
			if (byId === undefined) continue;
			for (const id of ids) {
				const list = byId.get(id)?.filter((ops) => !settled(ops));
				if (list?.length) byId.set(id, list);
				else byId.delete(id);
			}
			if (byId.size === 0) this.docs.delete(collection);
		}
		return entry.keys;
	}
}

/** `set` and `increment` need a known document; only `create` makes one. */
function applyOp(value: Flat | null, op: OverlayOp): Flat | null {
	switch (op.kind) {
		case "create":
			return { ...op.record };
		case "remove":
			return null;
		case "set":
			return value && { ...value, ...op.patch };
		case "increment": {
			const current = value?.[op.field];
			if (value === null || typeof current !== "number") return value;
			return { ...value, [op.field]: current + op.by, updated_at: op.time };
		}
	}
}

function isRecord(value: JsonValue | null): value is Flat {
	return (
		value !== null &&
		typeof value === "object" &&
		!Array.isArray(value) &&
		!(value instanceof Uint8Array)
	);
}

/** Context for shaping a write's overlay like the server shapes its rows. */
export interface OverlayContext {
	schema: SchemaDictionary;
	/** The connection's internal user id; the owner of rows it creates. */
	userId: string | null;
	/** Provisional `created_at` / `updated_at`, in microseconds. */
	time: number;
}

/**
 * Builds the overlay ops of a store write message, or null when the write
 * must not be shown before it commits (any `if`). `create` marks a
 * `StoreSet` from `store.create`, which makes a new document.
 */
export function overlayOps(
	message: OutboundRequest,
	create: boolean,
	context: OverlayContext,
): OverlayOp[] | null {
	switch (message.type) {
		case "StoreSet":
			if (message.if !== undefined || !isRecord(message.value)) return null;
			return [
				create
					? createOp(message.path, message.value, context)
					: setOp(message.path, message.value, context),
			];
		case "StoreRemove":
			if (message.if !== undefined) return null;
			return [
				{ kind: "remove", collection: message.path[0], id: message.path[1] },
			];
		case "StoreBatch":
			return batchOps(message.ops, context);
		default:
			return null;
	}
}

type BatchTuple = Extract<
	OutboundRequest,
	{ type: "StoreBatch" }
>["ops"][number];

function batchOps(
	tuples: BatchTuple[],
	context: OverlayContext,
): OverlayOp[] | null {
	const ops: OverlayOp[] = [];
	for (const tuple of tuples) {
		const op = batchOp(tuple, context);
		if (op === null) return null;
		ops.push(op);
	}
	return ops;
}

function batchOp(tuple: BatchTuple, context: OverlayContext): OverlayOp | null {
	const [collection, id] = tuple[1];
	switch (tuple[0]) {
		case "s":
			return tuple[3] === undefined && isRecord(tuple[2])
				? setOp(tuple[1], tuple[2], context)
				: null;
		case "r":
			return tuple[2] === undefined ? { kind: "remove", collection, id } : null;
		case "i":
			return tuple[4] === undefined
				? {
						kind: "increment",
						collection,
						id,
						field: tuple[2],
						by: tuple[3],
						time: context.time,
					}
				: null;
	}
}

function setOp(
	path: string[],
	value: Flat,
	context: OverlayContext,
): OverlayOp {
	const [collection, id] = path;
	const patch = shapePatch(collection, value, context.schema);
	return {
		kind: "set",
		collection,
		id,
		patch: { ...patch, updated_at: context.time },
	};
}

/** A new row: every schema field present, unset ones null, system fields provisional. */
function createOp(
	path: string[],
	value: Flat,
	context: OverlayContext,
): OverlayOp {
	const [collection, id] = path;
	const schema = context.schema;
	const record: Flat = {};
	for (const field of schema.getFields(schema.getTableIndex(collection))) {
		record[field] = null;
	}
	Object.assign(record, shapePatch(collection, value, schema));
	const system: Flat = {
		id,
		namespace_id: null,
		owner_id: collection === "users" ? id : context.userId,
		created_at: context.time,
		updated_at: context.time,
	};
	for (const [field, fieldValue] of Object.entries(system)) {
		if (Object.hasOwn(record, field)) record[field] = fieldValue;
	}
	return { kind: "create", collection, id, record };
}

/** Expands null namespaces and stores arrays in the server's sorted-set form. */
function shapePatch(
	collection: string,
	value: Flat,
	schema: SchemaDictionary,
): Flat {
	const tableIndex = schema.getTableIndex(collection);
	const patch = { ...schema.expandNullNamespaces(tableIndex, value) };
	for (const [field, fieldValue] of Object.entries(patch)) {
		if (!Array.isArray(fieldValue)) continue;
		const docId = schema.isDocIdField(
			tableIndex,
			schema.getFieldIndex(tableIndex, field),
		);
		patch[field] = sortedSet(fieldValue, docId);
	}
	return patch;
}
