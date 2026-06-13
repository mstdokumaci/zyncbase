// Wire protocol type definitions
// Source of truth: specs/implementation/wire-protocol.md (ADR-023)
import type { ZyncBaseError } from "./errors";

// ─── Primitive / utility types ───────────────────────────────────────────────

export type JsonValue =
	| string
	| number
	| boolean
	| null
	| JsonValue[]
	| { [key: string]: JsonValue };

/** A data address: dot-notation string or string array. */
export type Path = string | string[];

/** Lifecycle events emitted by the Connection Manager. */
export type LifecycleEvent =
	| "connected"
	| "disconnected"
	| "reconnecting"
	| "error"
	| "statusChange"
	| "schemaChange"
	| "tokenExpired";

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
	retryRateLimits?: boolean; // default: true — auto-retry RATE_LIMITED
	retryServerErrors?: boolean; // default: true — auto-retry INTERNAL_ERROR, ENGINE_UNHEALTHY
	maxServerRetries?: number; // default: 3 — max attempts for server errors
	debug?: boolean; // default: false
}

export interface StatusDetail {
	previousStatus: LifecycleEvent | null;
	retryCount: number;
	retryIn: number | null;
	error?: ZyncBaseError;
}

// ─── SDK-side query types (Prisma-style, encoded to wire tuples before sending) ──

export interface QueryOptions {
	where?: Record<string, JsonValue | Record<string, JsonValue> | JsonValue[]>; // e.g. { age: { gte: 18 }, or: [...] }
	orderBy?: Record<string, "asc" | "desc">; // e.g. { created_at: 'desc' }
	limit?: number;
	after?: string; // opaque cursor token
}

export interface BatchOperation {
	op: "set" | "remove";
	path: Path;
	value?: JsonValue;
}

export interface SubscriptionHandle {
	unsubscribe: () => void;
	loadMore: () => Promise<void>;
	hasMore: boolean;
}

// ─── Store interface ──────────────────────────────────────────────────────────

export interface Store {
	/** Set a value at a specific path. Returns a Promise that resolves when the server acknowledges. */
	set(path: Path, value: JsonValue, options?: WriteOptions): Promise<void>;
	/** Remove a value at a specific path. Returns a Promise that resolves when the server acknowledges. */
	remove(path: Path, options?: WriteOptions): Promise<void>;
	/** Create a new document in a collection with an auto-generated UUIDv7. Returns a Promise of the ID. */
	create(
		collection: string,
		value: JsonValue,
		options?: WriteOptions,
	): Promise<string>;
	/** Get current value(s) in a one-off read. */
	get(path: Path): Promise<JsonValue | null | undefined>;
	/** Listen for changes at a path. Returns an unlisten function. */
	listen(path: Path, callback: (value: JsonValue) => void): () => void;
	/** Subscribe to a collection with complex queries. */
	subscribe(
		collection: string,
		options: QueryOptions,
		callback: (results: JsonValue[]) => void,
	): SubscriptionHandle;
	// Batch — async
	batch(operations: BatchOperation[], options?: WriteOptions): Promise<void>;
	query(
		collection: string,
		options?: QueryOptions,
	): Promise<JsonValue[] & { nextCursor: string | null }>;
}

// ─── Outbound wire messages: auth ─────────────────────────────────────────────

export interface AuthRefresh {
	type: "AuthRefresh";
	id: number;
	token: string;
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
	orderBy?: [field: string, descFlag: number];
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
	orderBy?: [field: string, descFlag: number];
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
	table_index?: string | number;
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
	data: Record<number, unknown>; // Integer-keyed field map
}

export interface PresenceSetShared {
	type: "PresenceSetShared";
	id: number;
	data: Record<number, unknown>; // Integer-keyed field map
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

/** Union of all outbound message types. */
export type OutboundMessage =
	| AuthRefresh
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
	| PresenceRemove;

// ─── Inbound wire messages ────────────────────────────────────────────────────

/** Success response for unknown request. Extra fields present depending on request type. */
export interface OkResponse {
	type: "ok";
	id: number;
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
	shared?: Record<number, unknown> | null;
}

/** User entry in PresenceSubscribe snapshot. */
export interface PresenceUserSnapshot {
	userId: Uint8Array; // bin16 on wire
	data: Record<number, unknown>; // Integer-keyed field map
	joinedAt: number; // Unix timestamp ms
}

export interface ErrorResponse {
	type: "error";
	id: number;
	code: string;
	message: string;
	category?: string;
	retryAfter?: number;
	details?: Record<string, JsonValue>;
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
}

export interface ConnectedMessage {
	type: "Connected";
	userId: string | null;
	storeNamespace?: string;
	presenceNamespace?: string;
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
	data?: Record<number, unknown>; // Integer-keyed field map; present for join/update
	joinedAt?: number; // Unix timestamp ms; present only for join
}

/** Server push — shared state changes. No request id. */
export interface SharedStateBroadcast {
	type: "SharedStateBroadcast";
	subId: number;
	data: Record<number, unknown> | Record<number, unknown>[]; // Single patch or array of patches
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
	/** Set your user presence data. Fire-and-forget. Throttled to ~60fps. */
	set(data: Record<string, unknown>): void;
	/** Merge fields into namespace-level shared state. Fire-and-forget. */
	setShared(data: Record<string, unknown>): void;
	/** Subscribe to user presence changes. Returns unsubscribe function. */
	subscribe(callback: (users: PresenceEntry[]) => void): () => void;
	/** Subscribe to shared state changes. Returns unsubscribe function. */
	subscribeShared(
		callback: (shared: Record<string, unknown> | null) => void,
	): () => void;
	/** Synchronous local lookup of a specific user's presence. */
	get(userId: string): PresenceEntry | undefined;
	/** Synchronous local lookup of all users' presence. */
	getAll(options?: PresenceGetAllOptions): PresenceEntry[];
	/** Synchronous local lookup of current shared state. */
	getShared(): Record<string, unknown> | null;
	/** Remove your presence record. */
	remove(): void;
}

/** Union of all inbound message types. */
export type InboundMessage =
	| OkResponse
	| ErrorResponse
	| StoreDelta
	| SchemaSync
	| ConnectedMessage
	| WriteCommitted
	| WriteError
	| PresenceBroadcast
	| SharedStateBroadcast;
