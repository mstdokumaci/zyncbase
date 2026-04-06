// Wire protocol type definitions
// Source of truth: specs/implementation/wire-protocol.md (ADR-023)
import type { ZyncBaseError } from "./errors";

// ─── Primitive / utility types ───────────────────────────────────────────────

/** A data address: dot-notation string or string array. */
export type Path = string | string[];

/** Lifecycle events emitted by the Connection Manager. */
export type LifecycleEvent =
	| "connected"
	| "disconnected"
	| "reconnecting"
	| "error"
	| "statusChange";

// ─── Client configuration ────────────────────────────────────────────────────

export interface ClientOptions {
	url: string;
	auth?: { token: string }; // Optional until auth is implemented
	storeNamespace?: string; // default: 'public'
	presenceNamespace?: string; // default: same as storeNamespace
	reconnect?: boolean; // default: true
	reconnectDelay?: number; // ms, default: 1000
	maxReconnectDelay?: number; // ms, default: 30_000
	maxReconnectAttempts?: number; // default: Infinity
	reconnectJitter?: boolean; // default: true
}

export interface StatusDetail {
	previousStatus: LifecycleEvent | null;
	retryCount: number;
	retryIn: number | null;
	error?: ZyncBaseError;
}

// ─── SDK-side query types (Prisma-style, encoded to wire tuples before sending) ──

export interface QueryOptions {
	where?: Record<string, any>; // e.g. { age: { gte: 18 }, status: { eq: 'active' } }
	orderBy?: Record<string, "asc" | "desc">; // e.g. { created_at: 'desc' }
	limit?: number;
	after?: string; // opaque cursor token
}

export interface BatchOperation {
	op: "set" | "remove";
	path: Path;
	value?: any;
}

export interface SubscriptionHandle {
	unsubscribe: () => void;
	loadMore: () => Promise<void>;
	hasMore: boolean;
}

// ─── Store interface ──────────────────────────────────────────────────────────

export interface Store {
	/** Set a value at a specific path. Returns a Promise that resolves when the server acknowledges. */
	set(path: Path, value: any): Promise<void>;
	/** Remove a value at a specific path. Returns a Promise that resolves when the server acknowledges. */
	remove(path: Path): Promise<void>;
	/** Create a new document in a collection with an auto-generated UUIDv7. Returns a Promise of the ID. */
	create(collection: string, value: any): Promise<string>;
	/** Push a new value to a collection with an auto-generated ULID/UUID. Returns a Promise of the ID. */
	push(collection: string, value: any): Promise<string>;
	/** Merge fields into an existing document. Returns a Promise that resolves when the server acknowledges. */
	update(path: Path, value: any): Promise<void>;
	/** Get current value(s) in a one-off read. */
	get(path: Path): Promise<any>;
	/** Listen for changes at a path. Returns an unlisten function. */
	listen(path: Path, callback: (value: any) => void): () => void;
	/** Subscribe to a collection with complex queries. */
	subscribe(
		collection: string,
		options: QueryOptions,
		callback: (results: any[]) => void,
	): SubscriptionHandle;
	// Batch — async
	batch(operations: BatchOperation[]): Promise<void>;
	query(
		collection: string,
		options?: QueryOptions,
	): Promise<any[] & { nextCursor: string | null }>;
}

// ─── Outbound wire messages: writes ──────────────────────────────────────────

export interface StoreSet {
	type: "StoreSet";
	id: number;
	namespace: string;
	path: string[];
	value: any;
}

export interface StoreRemove {
	type: "StoreRemove";
	id: number;
	namespace: string;
	path: string[];
}

/** ops are positional tuples: ["s", path, value] for set, ["r", path] for remove */
export interface StoreBatch {
	type: "StoreBatch";
	id: number;
	namespace: string;
	ops: (["s", string[], any] | ["r", string[]])[];
}

// ─── Outbound wire messages: reads (one-shot) ─────────────────────────────────

export interface StoreQuery {
	type: "StoreQuery";
	id: number;
	namespace: string;
	collection: string;
	conditions?: [field: string, op: number, value?: any][];
	orConditions?: [field: string, op: number, value?: any][];
	orderBy?: [field: string, descFlag: number];
	limit?: number;
	after?: string; // opaque Base64 cursor
}

// ─── Outbound wire messages: subscriptions (ongoing) ─────────────────────────

export interface StoreSubscribe {
	type: "StoreSubscribe";
	id: number;
	namespace: string;
	collection: string;
	conditions?: [field: string, op: number, value?: any][];
	orConditions?: [field: string, op: number, value?: any][];
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
}

/** Union of all outbound message types. */
export type OutboundMessage =
	| StoreSet
	| StoreRemove
	| StoreBatch
	| StoreQuery
	| StoreSubscribe
	| StoreUnsubscribe
	| StoreLoadMore;

// ─── Inbound wire messages ────────────────────────────────────────────────────

/** Success response for any request. Extra fields present depending on request type. */
export interface OkResponse {
	type: "ok";
	id: number;
	// StoreQuery response fields:
	value?: any[];
	nextCursor?: string | null;
	// StoreSubscribe response fields:
	subId?: number;
	hasMore?: boolean;
}

export interface ErrorResponse {
	type: "error";
	id: number;
	code: string;
	message: string;
	category?: string;
	retryAfter?: number;
	details?: Record<string, any>;
}

/** Server push — record-level delta for an active subscription. No request id. */
export interface StoreDelta {
	type: "StoreDelta";
	subId: number;
	ops: Array<
		{ op: "set"; path: string[]; value: any } | { op: "remove"; path: string[] }
	>;
}

/** Union of all inbound message types. */
export type InboundMessage = OkResponse | ErrorResponse | StoreDelta;
