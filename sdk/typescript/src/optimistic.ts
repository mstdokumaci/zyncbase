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

type IncrementOp = Extract<OverlayOp, { kind: "increment" }>;

/** Where a pending increment sits relative to the committed record. */
interface IncrementState {
	/** Committed field value from which this increment is not yet reflected. */
	base?: number;
	/** Server revision (`updated_at`) that already includes the increment. */
	reflectedAt?: number;
	/** Committed field value that included it, when no revision is available. */
	reflectedValue?: number;
}

/**
 * Pending writes per document, in send order. The server applies writes in
 * send order and never retries one, so a commit also settles every earlier
 * write's changes to the same documents: they are applied or failed already.
 */
export class PendingWrites {
	private readonly docs = new Map<string, Map<string, KeyOps[]>>();
	private readonly incrementStates = new WeakMap<IncrementOp, IncrementState>();
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
		return this.drop(entry, (ops) => ops.seq <= entry.seq, true);
	}

	/** The write failed: drop only it. */
	fail(entry: PendingEntry): OverlayKeys {
		return this.drop(entry, (ops) => ops.seq === entry.seq, false);
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
		const entries = this.docs.get(collection)?.get(id) ?? [];
		const skip =
			value === null || !hasIncrement(entries)
				? undefined
				: this.reconcile(collection, id, value);
		for (const { ops } of entries) {
			for (const op of ops) {
				if (skip?.has(op)) continue;
				value = applyOp(value, op);
			}
		}
		return value === null ? null : unflatten(value);
	}

	/**
	 * Marks pending increments the committed record already includes. A delta
	 * can carry one or several pending increments; those form a prefix whose
	 * cumulative `by` matches the committed field value.
	 */
	private reconcile(
		collection: string,
		id: string,
		base: Flat,
	): ReadonlySet<OverlayOp> {
		const skip = new Set<OverlayOp>();
		const revision =
			typeof base.updated_at === "number" ? base.updated_at : undefined;
		for (const [field, ops] of this.incrementsByField(collection, id)) {
			const baseValue = base[field];
			if (typeof baseValue === "number") {
				this.reconcileField(skip, ops, baseValue, revision);
			}
		}
		return skip;
	}

	private incrementsByField(
		collection: string,
		id: string,
	): Map<string, IncrementOp[]> {
		const byField = new Map<string, IncrementOp[]>();
		for (const { ops } of this.docs.get(collection)?.get(id) ?? []) {
			for (const op of ops) {
				if (op.kind !== "increment") continue;
				const list = byField.get(op.field) ?? [];
				byField.set(op.field, list);
				list.push(op);
			}
		}
		return byField;
	}

	private reconcileField(
		skip: Set<OverlayOp>,
		ops: IncrementOp[],
		baseValue: number,
		revision: number | undefined,
	): void {
		const candidates: IncrementOp[] = [];
		for (const op of ops) {
			const state = this.incrementState(op);
			if (this.isReflected(state, revision, baseValue)) {
				skip.add(op);
				continue;
			}
			if (state.base === undefined) state.base = baseValue;
			candidates.push(op);
		}
		if (candidates.length === 0) return;
		const matched = this.matchIncrementPrefix(candidates, baseValue);
		if (matched < 0) {
			this.rebaseIncrements(candidates, 0, baseValue);
			return;
		}
		this.markReflected(skip, candidates, matched, baseValue, revision);
		this.rebaseIncrements(candidates, matched + 1, baseValue);
	}

	private isReflected(
		state: IncrementState,
		revision: number | undefined,
		baseValue: number,
	): boolean {
		if (revision !== undefined && state.reflectedAt !== undefined) {
			return revision >= state.reflectedAt;
		}
		return (
			state.reflectedValue !== undefined && state.reflectedValue === baseValue
		);
	}

	private matchIncrementPrefix(ops: IncrementOp[], baseValue: number): number {
		let cumulative = this.incrementState(ops[0]).base ?? baseValue;
		let matched = -1;
		for (let i = 0; i < ops.length; i += 1) {
			cumulative += ops[i].by;
			if (baseValue === cumulative) matched = i;
		}
		return matched;
	}

	private markReflected(
		skip: Set<OverlayOp>,
		ops: IncrementOp[],
		matched: number,
		baseValue: number,
		revision: number | undefined,
	): void {
		for (let i = 0; i <= matched; i += 1) {
			const op = ops[i];
			const state = this.incrementState(op);
			state.base = baseValue;
			state.reflectedAt = revision;
			state.reflectedValue = baseValue;
			skip.add(op);
		}
	}

	private rebaseIncrements(
		ops: IncrementOp[],
		from: number,
		baseValue: number,
	): void {
		for (let i = from; i < ops.length; i += 1) {
			this.incrementState(ops[i]).base = baseValue;
		}
	}

	private incrementState(op: IncrementOp): IncrementState {
		let state = this.incrementStates.get(op);
		if (state === undefined) {
			state = {};
			this.incrementStates.set(op, state);
		}
		return state;
	}

	private drop(
		entry: PendingEntry,
		settled: (ops: KeyOps) => boolean,
		advanceRemaining: boolean,
	): OverlayKeys {
		for (const [collection, ids] of entry.keys) {
			const byId = this.docs.get(collection);
			if (byId === undefined) continue;
			for (const id of ids) {
				this.dropDocument(byId, id, settled, advanceRemaining);
			}
			if (byId.size === 0) this.docs.delete(collection);
		}
		return entry.keys;
	}

	private dropDocument(
		byId: Map<string, KeyOps[]>,
		id: string,
		settled: (ops: KeyOps) => boolean,
		advanceRemaining: boolean,
	): void {
		const remaining: KeyOps[] = [];
		const settledIncrements: IncrementOp[] = [];
		for (const ops of byId.get(id) ?? []) {
			if (!settled(ops)) remaining.push(ops);
			else if (advanceRemaining) collectIncrements(ops, settledIncrements);
		}
		if (advanceRemaining) {
			this.advanceBaselines(remaining, settledIncrements);
		}
		if (remaining.length) byId.set(id, remaining);
		else byId.delete(id);
	}

	/**
	 * A commit makes an earlier increment part of committed state even while
	 * its delta is still batched. Move later pending increments' baseline past
	 * it so that delta reconciles instead of adding the increment twice.
	 */
	private advanceBaselines(remaining: KeyOps[], settled: IncrementOp[]): void {
		for (const { ops } of remaining) {
			for (const op of ops) {
				if (op.kind === "increment") this.advanceBaseline(op, settled);
			}
		}
	}

	private advanceBaseline(op: IncrementOp, settled: IncrementOp[]): void {
		const state = this.incrementState(op);
		for (const dropped of settled) {
			if (dropped.field !== op.field) continue;
			const droppedState = this.incrementState(dropped);
			if (
				droppedState.reflectedAt !== undefined ||
				droppedState.reflectedValue !== undefined
			) {
				continue;
			}
			if (state.base !== undefined) state.base += dropped.by;
		}
	}
}

function hasIncrement(entries: readonly KeyOps[]): boolean {
	for (const { ops } of entries) {
		for (const op of ops) {
			if (op.kind === "increment") return true;
		}
	}
	return false;
}

function collectIncrements(ops: KeyOps, out: IncrementOp[]): void {
	for (const op of ops.ops) {
		if (op.kind === "increment") out.push(op);
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
		if (!Array.isArray(fieldValue)) {
			patch[field] = copyBinary(fieldValue);
			continue;
		}
		const docId = schema.isDocIdField(
			tableIndex,
			schema.getFieldIndex(tableIndex, field),
		);
		patch[field] = sortedSet(fieldValue, docId).map(copyBinary);
	}
	return patch;
}

/** Copy a leaf buffer so later caller mutations cannot alter the pending patch. */
function copyBinary(value: JsonValue): JsonValue {
	if (value instanceof Uint8Array) return value.slice();
	return value;
}
