// Wire protocol type definitions
// Source of truth: specs/implementation/wire-protocol.md (ADR-023)
import type { ZyncBaseError } from "./errors";

// ─── Primitive / utility types ───────────────────────────────────────────────

export type JsonValue =
	| string
	| number
	| boolean
	| null
	| Uint8Array
	| JsonValue[]
	| { [key: string]: JsonValue };

/** A data address: dot-notation string or string array. */
export type Path = string | string[];

// ─── Schema-derived types ────────────────────────────────────────────────────

/**
 * Permissive schema fallback: any collection, any field, any value.
 * Generated schema types (see `bunx @zyncbase/client generate`) satisfy it.
 */
export type SchemaLike = Record<string, Record<string, unknown>>;

/** True when `S` is the permissive fallback rather than a generated schema. */
type IsLooseSchema<S> = string extends keyof S ? true : false;

/** Collection names declared by a schema. */
export type CollectionsOf<S> = keyof S & string;

/** Document shape declared by a schema, without server-issued columns. */
export type DocumentOf<S, C extends keyof S & string> = S[C];

/** Document row as returned by reads: schema fields plus the server-issued id. */
export type DocumentRowOf<S, C extends keyof S & string> = S[C] & {
	id: string;
};

/** Types written as whole values — field paths never descend into these. */
type WholeValue = readonly unknown[] | Uint8Array;

/** Whether a field's value is an addressable nested object. */
type IsNested<T> =
	NonNullable<T> extends WholeValue
		? false
		: NonNullable<T> extends object
			? true
			: false;

/** Dot-joined field paths beneath a document shape ("address.city"). */
type DotFieldPaths<T> = {
	[K in keyof T & string]:
		| K
		| (IsNested<T[K]> extends true
				? `${K}.${DotFieldPaths<NonNullable<T[K]>>}`
				: never);
}[keyof T & string];

/** Segment-tuple field paths beneath a document shape (["address", "city"]). */
type TupleFieldPaths<T> = {
	[K in keyof T & string]:
		| [K]
		| (IsNested<T[K]> extends true
				? [K, ...TupleFieldPaths<NonNullable<T[K]>>]
				: never);
}[keyof T & string];

/** Every addressable path in a typed schema: dot strings and segment tuples. */
type SchemaPath<S> = {
	[C in CollectionsOf<S>]:
		| C
		| `${C}.${string}`
		| [C, string]
		| `${C}.${string}.${DotFieldPaths<S[C]>}`
		| [C, string, ...TupleFieldPaths<S[C]>];
}[CollectionsOf<S>];

type GetPath<S> = IsLooseSchema<S> extends true ? Path : SchemaPath<S>;

/** Paths addressing a document or field (writes need depth 2 or more). */
type WritePath<S> =
	IsLooseSchema<S> extends true
		? Path
		: Exclude<SchemaPath<S>, CollectionsOf<S>>;

/** Paths addressing exactly one document (collection + id). */
type DocumentPath<S> =
	IsLooseSchema<S> extends true
		? Path
		: {
				[C in CollectionsOf<S>]: `${C}.${string}` | [C, string];
			}[CollectionsOf<S>];

/** Value type at a dot-joined field path. */
type DotValue<T, P extends string> = P extends `${infer H}.${infer R}`
	? H extends keyof T
		? IsNested<T[H]> extends true
			? DotValue<NonNullable<T[H]>, R>
			: never
		: never
	: P extends keyof T
		? T[P]
		: never;

/** Value type at a segment-tuple field path. */
type TupleValue<T, Segs extends readonly string[]> = Segs extends readonly [
	infer H extends string,
	...infer R extends string[],
]
	? H extends keyof T
		? R extends []
			? T[H]
			: IsNested<T[H]> extends true
				? TupleValue<NonNullable<T[H]>, R>
				: never
		: never
	: never;

/** Value returned by `get` at a path. */
type GetValue<S, P> =
	IsLooseSchema<S> extends true
		? JsonValue | null | undefined
		: P extends readonly [infer C extends string, ...infer R]
			? C extends keyof S
				? R extends [string]
					? DocumentRowOf<S, C> | null
					: R extends [string, ...infer F extends string[]]
						? TupleValue<S[C], F> | undefined
						: never
				: never
			: P extends string
				? P extends `${infer C}.${infer R}`
					? C extends keyof S
						? R extends `${string}.${infer F}`
							? [DotValue<S[C], F>] extends [never]
								? PathError
								: DotValue<S[C], F> | undefined
							: DocumentRowOf<S, C> | null
						: never
					: P extends keyof S
						? DocumentRowOf<S, P>[]
						: never
				: never;

/**
 * Marker for a dot-string path whose field segment does not resolve. The call
 * itself still compiles (`${collection}.${string}` covers doc-level ids), but
 * the result is unusable — assigning it forces the typo into the open.
 */
type PathError = { readonly __zyncbaseUnknownFieldPath: true };

/** Value accepted by `set` at a path. */
type SetValue<S, P> =
	IsLooseSchema<S> extends true
		? JsonValue
		: P extends readonly [infer C extends string, ...infer R]
			? C extends keyof S
				? R extends [string]
					? DocumentOf<S, C>
					: R extends [string, ...infer F extends string[]]
						? TupleValue<S[C], F> | null
						: never
				: never
			: P extends string
				? P extends `${infer C}.${infer R}`
					? C extends keyof S
						? R extends `${string}.${infer F}`
							? DotValue<S[C], F> | null
							: DocumentOf<S, C>
						: never
					: never
				: never;

/** Value accepted by `create` for a collection. */
type CreateValue<S, C extends keyof S & string> =
	IsLooseSchema<S> extends true ? JsonValue : S[C];

/** Row shape returned by `query` and `subscribe`. */
type RowsOf<S, C extends keyof S & string> =
	IsLooseSchema<S> extends true ? JsonValue[] : DocumentRowOf<S, C>[];

/** Connection lifecycle status as exposed by `client.status` and `statusChange`. */
export type ConnectionStatus =
	| "connecting"
	| "connected"
	| "reconnecting"
	| "disconnected";

/** Payload of the `disconnected` event — why the connection ended and what comes next. */
export interface DisconnectDetail {
	/** Machine-readable cause; always set. */
	code: string;
	/** Human-readable text from the server, when it sent one. */
	reason: string;
	/** ZyncBaseError category, for existing retry logic. */
	category: string;
	/** Whether the SDK reconnects on normal backoff. */
	retryable: boolean;
	/** Reconnect attempts made before giving up. */
	attempt: number;
}

/** Typed event map — `client.on` and `client.off` are keyed by this. */
export interface ClientEvents {
	connected: () => void;
	reconnected: () => void;
	synced: () => void;
	disconnected: (detail: DisconnectDetail) => void;
	reconnecting: (attempt: number, delayMs: number) => void;
	schemaChange: () => void;
	error: (error: ZyncBaseError) => void;
	tokenExpired: () => void;
	statusChange: (status: ConnectionStatus, detail: StatusDetail) => void;
}

/** Lifecycle events emitted by the Connection Manager. */
export type LifecycleEvent = keyof ClientEvents;

export interface WriteOptions {
	confirm?: "accepted" | "committed";
}

// ─── Client configuration ────────────────────────────────────────────────────

export type AuthConfig =
	| { token: string }
	| { tokenProvider: () => Promise<string> }
	| { anonymous: true };

export interface TicketResponse {
	ticket: string;
	expiresAt: number;
}

export interface ClientOptions {
	url: string;
	auth?: AuthConfig;
	storeNamespace?: string; // default: 'public'
	presenceNamespace?: string; // default: same as storeNamespace
	reconnect?: boolean; // default: true
	reconnectDelay?: number; // ms, default: 1000
	maxReconnectDelay?: number; // ms, default: 30_000
	maxReconnectAttempts?: number; // default: Infinity
	reconnectJitter?: boolean; // default: true
	liveness?: {
		enabled?: boolean; // default: true
		intervalMs?: number; // default: 15_000; minimum: 1_000
		timeoutMs?: number; // default: 10_000; range: 1..2_147_483_647
	};
	retryRateLimits?: boolean; // default: true — auto-retry RATE_LIMITED
	retryServerErrors?: boolean; // default: true — auto-retry INTERNAL_ERROR, ENGINE_UNHEALTHY
	maxServerRetries?: number; // default: 3 — max attempts for server errors
	debug?: boolean; // default: false
}

export interface StatusDetail {
	previousStatus: ConnectionStatus;
	retryCount: number;
	retryIn: number | null;
	error?: ZyncBaseError;
}

// ─── SDK-side query types (Prisma-style, encoded to wire tuples before sending) ──

export type SortDirection = "asc" | "desc";

/** A single sort clause with exactly one field and one direction. */
export type SortClause = Readonly<Record<string, SortDirection>>;

export interface QueryOptions {
	where?: Record<string, JsonValue | Record<string, JsonValue> | JsonValue[]>; // e.g. { age: { gte: 18 }, or: [...] }
	orderBy?: readonly SortClause[]; // e.g. [{ created_at: 'desc' }] — array order defines precedence
	limit?: number;
	after?: string; // opaque cursor token
}

/**
 * One batch write. The value stays `JsonValue` rather than correlating to the
 * path; use `set` for schema-checked writes.
 */
export interface BatchOperation {
	op: "set" | "remove";
	path: Path;
	value?: JsonValue;
}

export interface SubscriptionHandle {
	/** Detach this consumer; its callback stops firing immediately. */
	unsubscribe: () => Promise<void>;
	loadMore: () => Promise<void>;
	hasMore: boolean;
	/** Current sorted results; empty before the first delivery. */
	getSnapshot: () => JsonValue[];
}

/** Handle returned by `store.listen`. */
export interface ListenHandle {
	/** Detach this consumer; its callback stops firing immediately. */
	unlisten: () => Promise<void>;
	/** Last value delivered to callbacks for this path; `undefined` before the first. */
	getSnapshot: () => JsonValue | undefined;
}

// ─── Store interface ──────────────────────────────────────────────────────────

export interface Store<S extends object = SchemaLike> {
	/** Set a value at a specific path. Returns a Promise that resolves when the server acknowledges. */
	set<const P extends WritePath<S>>(
		path: P,
		value: SetValue<S, P>,
		options?: WriteOptions,
	): Promise<void>;
	/** Remove a value at a specific path. Returns a Promise that resolves when the server acknowledges. */
	remove<const P extends DocumentPath<S>>(
		path: P,
		options?: WriteOptions,
	): Promise<void>;
	/** Create a new document in a collection with an auto-generated UUIDv7. Returns a Promise of the ID. */
	create<C extends CollectionsOf<S>>(
		collection: C,
		value: CreateValue<S, C>,
		options?: WriteOptions,
	): Promise<string>;
	/** Get current value(s) in a one-off read. */
	get<const P extends GetPath<S>>(path: P): Promise<GetValue<S, P>>;
	/** Listen for changes at a path; resolves with a handle once the registration settles. */
	listen<const P extends WritePath<S>>(
		path: P,
		callback: (value: GetValue<S, P>) => void,
	): Promise<ListenHandle>;
	/** Subscribe to a collection with complex queries; resolves with its handle after server acknowledgement. */
	subscribe<C extends CollectionsOf<S>>(
		collection: C,
		options: QueryOptions,
		callback: (results: RowsOf<S, C>) => void,
	): Promise<SubscriptionHandle>;
	// Batch — async
	batch(operations: BatchOperation[], options?: WriteOptions): Promise<void>;
	query<C extends CollectionsOf<S>>(
		collection: C,
		options?: QueryOptions,
	): Promise<RowsOf<S, C> & { nextCursor: string | null }>;
}

// ─── Outbound wire messages: auth ─────────────────────────────────────────────

export interface AuthRefresh {
	type: "AuthRefresh";
	id: number;
	token: string;
}

export interface Ping {
	type: "Ping";
	id: number;
}

// ─── Outbound wire messages: writes ──────────────────────────────────────────

export interface StoreSet {
	type: "StoreSet";
	id: number;
	path: string[];
	value: JsonValue;
	confirm?: "accepted" | "committed";
	writeId?: string;
}

export interface StoreRemove {
	type: "StoreRemove";
	id: number;
	path: string[];
	confirm?: "accepted" | "committed";
	writeId?: string;
}

/** ops are positional tuples: ["s", path, value] for set, ["r", path] for remove */
export interface StoreBatch {
	type: "StoreBatch";
	id: number;
	ops: (["s", string[], JsonValue] | ["r", string[]])[];
	confirm?: "accepted" | "committed";
	writeId?: string;
}

export interface StoreSetNamespace {
	type: "StoreSetNamespace";
	id: number;
	namespace: string;
}

// ─── Outbound wire messages: reads (one-shot) ─────────────────────────────────

export interface StoreQuery {
	type: "StoreQuery";
	id: number;
	table_index: string | number;
	conditions?: [field: string, op: number, value?: JsonValue][];
	orConditions?: [field: string, op: number, value?: JsonValue][];
	orderBy?: [field: string, descFlag: number][]; // ordered sort clauses; array order = precedence
	limit?: number;
	after?: string; // opaque Base64 cursor
}

// ─── Outbound wire messages: subscriptions (ongoing) ─────────────────────────

export interface StoreSubscribe {
	type: "StoreSubscribe";
	id: number;
	table_index: string | number;
	conditions?: [field: string, op: number, value?: JsonValue][];
	orConditions?: [field: string, op: number, value?: JsonValue][];
	orderBy?: [field: string, descFlag: number][]; // ordered sort clauses; array order = precedence
	limit?: number;
}

export interface StoreUnsubscribe {
	type: "StoreUnsubscribe";
	id: number;
	subId: number;
}

export interface StoreLoadMore {
	type: "StoreLoadMore";
	id: number;
	subId: number;
	nextCursor: string;
}

// ─── Outbound wire messages: presence ─────────────────────────────────────────

export interface PresenceSetNamespace {
	type: "PresenceSetNamespace";
	id: number;
	namespace: string;
}

export interface PresenceSet {
	type: "PresenceSet";
	id: number;
	data: Record<string, unknown>; // User-facing string-keyed data
}

export interface PresenceSetShared {
	type: "PresenceSetShared";
	id: number;
	data: Record<string, unknown>; // User-facing string-keyed data
}

export interface PresenceSubscribe {
	type: "PresenceSubscribe";
	id: number;
}

export interface PresenceUnsubscribe {
	type: "PresenceUnsubscribe";
	id: number;
	subId: number;
}

export interface PresenceSubscribeShared {
	type: "PresenceSubscribeShared";
	id: number;
}

export interface PresenceUnsubscribeShared {
	type: "PresenceUnsubscribeShared";
	id: number;
	subId: number;
}

export interface PresenceRemove {
	type: "PresenceRemove";
	id: number;
}

// ─── Outbound wire messages: actions ─────────────────────────────────────────

export interface ActionCall {
	type: "ActionCall";
	id: number;
	/** Action name; the wire codec encodes it to the SchemaSync integer id. */
	action_id: string | number;
	timeoutMs?: number;
	params?: Record<string, unknown>;
}

export interface ActionReply {
	type: "ActionReply";
	id: number;
	execId: number;
	ok: boolean;
	/** Pre-encoded sparse field array (returns) or [code, message] error tuple. */
	payload: unknown;
}

export interface ActionRegister {
	type: "ActionRegister";
	id: number;
	action_ids: (string | number)[];
}

/** Union of all outbound message types. */
export type OutboundMessage =
	| AuthRefresh
	| Ping
	| StoreSet
	| StoreRemove
	| StoreBatch
	| StoreSetNamespace
	| StoreQuery
	| StoreSubscribe
	| StoreUnsubscribe
	| StoreLoadMore
	| PresenceSetNamespace
	| PresenceSet
	| PresenceSetShared
	| PresenceSubscribe
	| PresenceUnsubscribe
	| PresenceSubscribeShared
	| PresenceUnsubscribeShared
	| PresenceRemove
	| ActionCall
	| ActionReply
	| ActionRegister;

// ─── Inbound wire messages ────────────────────────────────────────────────────

/** Success response for unknown request. Extra fields present depending on request type. */
export interface OkResponse {
	type: "ok";
	id: number;
	// PresenceSetNamespace response field (bin16 on wire):
	userId?: Uint8Array;
	// StoreQuery response fields:
	value?: JsonValue[];
	nextCursor?: string | null;
	// StoreSubscribe response fields:
	subId?: number;
	hasMore?: boolean;
	namespace_id?: number;
	// PresenceSubscribe response fields:
	users?: PresenceUserSnapshot[];
	// PresenceSubscribeShared response fields:
	shared?: Record<string, unknown> | null;
	// ActionCall sync response: decoded returns object.
	actionResult?: Record<string, JsonValue>;
}

/** User entry in PresenceSubscribe snapshot. */
export interface PresenceUserSnapshot {
	userId: Uint8Array; // bin16 on wire
	data: Record<string, unknown>; // Decoded string-keyed field map
	joinedAt: number; // Unix timestamp ms
}

export interface ErrorResponse {
	type: "error";
	id?: number;
	code: string;
	message: string;
	category?: string;
	retryAfter?: number;
	details?: Record<string, JsonValue>;
}

export interface ServerDisconnect {
	type: "ServerDisconnect";
	code: string;
	message: string;
}

/** Server push — record-level delta for an active subscription. No request id. */
export interface StoreDelta {
	type: "StoreDelta";
	subId: number;
	ops: Array<
		| { op: "set"; path: string[]; value: JsonValue }
		| { op: "remove"; path: string[] }
	>;
}

export interface SchemaSync {
	type: "SchemaSync";
	tables: string[];
	fields: string[][];
	fieldFlags: number[][];
	presenceUserFields?: string[];
	presenceSharedFields?: string[];
	actions?: string[];
	actionParams?: string[][];
	actionReturns?: string[][];
	actionFlags?: number[];
}

export interface WriteCommitted {
	type: "WriteCommitted";
	writeId: string;
}

export interface WriteError {
	type: "WriteError";
	writeId: string;
	code: string;
	message: string;
	/** Always "write" — async writer-thread failures. Accept-phase failures are synchronous request errors. */
	phase: "write";
	/** Index of the failing operation within a StoreBatch, when identifiable. */
	batchIndex?: number;
}

/** Server push — batched user presence changes. No request id. */
export interface PresenceBroadcast {
	type: "PresenceBroadcast";
	subId: number;
	users: PresenceBroadcastEntry[];
}

/** Single user entry in a PresenceBroadcast. */
export interface PresenceBroadcastEntry {
	userId: Uint8Array; // bin16 on wire
	event: "join" | "update" | "leave";
	data?: Record<string, unknown>; // Decoded string-keyed field map; present for join/update
	joinedAt?: number; // Unix timestamp ms; present only for join
}

/** Server push — shared state changes. No request id. */
export interface SharedStateBroadcast {
	type: "SharedStateBroadcast";
	subId: number;
	data: Record<string, unknown>[]; // Array of decoded patches
}

/** Flat sparse field array: `[field_index, value, field_index, value, ...]`. */
export type SparseFieldArray = unknown[];

/** Server push — forward an action call to a registered worker. */
export interface ActionForward {
	type: "ActionForward";
	execId: number;
	/** Canonical UUIDv7 string decoded from the wire bin16 user id. */
	userId: string;
	action_id: number;
	params: SparseFieldArray;
	/**
	 * Session claims projected through the action's schema `claims` list at
	 * forward time. Keys are session variable names; absent claims are omitted.
	 */
	claims: Readonly<Record<string, JsonValue>>;
}

/** Decoded presence entry exposed to SDK consumers. */
export interface PresenceEntry {
	userId: string; // Decoded UUID string
	data: Record<string, unknown>; // Unflattened, string-keyed
	joinedAt: number; // Unix timestamp ms
}

/** Options for presence.getAll(). */
export interface PresenceGetAllOptions {
	includeSelf?: boolean;
}

/** Public Presence API interface. */
export interface Presence {
	/** Set your user presence data. Resolves when the server accepts it; throttled to ~60fps. */
	set(data: Record<string, unknown>): Promise<void>;
	/** Merge fields into namespace-level shared state. Resolves when the server accepts it. */
	setShared(data: Record<string, unknown>): Promise<void>;
	/**
	 * Subscribe to unordered user presence snapshots. Fires with a fresh snapshot when
	 * another user joins, updates, or leaves; self-only broadcasts do not fire. Resolves
	 * with an unsubscribe function after server acknowledgement.
	 */
	subscribe(
		callback: (users: PresenceEntry[]) => void,
	): Promise<() => Promise<void>>;
	/** Subscribe to shared state changes; resolves with an unsubscribe function after server acknowledgement. */
	subscribeShared(
		callback: (shared: Record<string, unknown> | null) => void,
	): Promise<() => Promise<void>>;
	/** Synchronous local lookup of a specific user's presence. */
	get(userId: string): PresenceEntry | undefined;
	/** Synchronous local lookup of all users' presence. Result order is unspecified. */
	getAll(options?: PresenceGetAllOptions): PresenceEntry[];
	/** Synchronous local lookup of current shared state. */
	getShared(): Record<string, unknown> | null;
	/** Scope-resolved internal users.id, or null before scope setup. */
	readonly localUserId: string | null;
	/** Remove your presence record; resolves after the server accepts it. */
	remove(): Promise<void>;
}

// ─── Actions interface ────────────────────────────────────────────────────────

export type ActionScope = "store" | "presence";

export interface ActionCallOptions {
	/**
	 * Upper bound (ms) on how long the server may wait for a sync action reply.
	 * Defaults to 10000ms on the server; a smaller value only shortens the deadline.
	 */
	timeoutMs?: number;
}

/** Verified request metadata injected by the server for every worker invocation. */
export interface ActionContext {
	/** Canonical UUIDv7 string of the authenticated user resolved by the bound scope. */
	readonly userId: string;
	/** Active namespace of the action's bound scope. */
	readonly namespace: string;
	/** Server-assigned execution id for this invocation. */
	readonly execId: number;
	/**
	 * Caller session claims projected through the action's schema `claims`
	 * list. Keys are session variable names — the same names `$session.<field>`
	 * resolves in authorization rules. Projected at forward time; a claim
	 * absent from the caller's session is omitted, not `null`. `{}` when the
	 * action declares no `claims`.
	 */
	readonly claims: Readonly<Record<string, JsonValue>>;
}

export type ActionHandler = (
	ctx: ActionContext,
	params: Record<string, unknown>,
) => unknown | Promise<unknown>;

/** Public Actions API interface. */
export interface Actions {
	/**
	 * Invoke an action. Async actions resolve to `undefined` on admission;
	 * sync actions resolve to the validated returns object.
	 * Action calls are never auto-retried.
	 */
	call(
		name: string,
		params?: Record<string, unknown>,
		options?: ActionCallOptions,
	): Promise<unknown>;
	/**
	 * Register a handler for an action. Throws `SESSION_NOT_READY` when the
	 * action's bound scope is not ready. Resolves when the server accepts the
	 * registration. A worker is an ordinary client.
	 */
	handle(name: string, handler: ActionHandler): Promise<void>;
}

/** Union of all inbound message types. */
export type InboundMessage =
	| OkResponse
	| ErrorResponse
	| ServerDisconnect
	| StoreDelta
	| SchemaSync
	| WriteCommitted
	| WriteError
	| PresenceBroadcast
	| SharedStateBroadcast
	| ActionForward;
