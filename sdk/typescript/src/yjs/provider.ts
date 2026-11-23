// biome-ignore-all lint/complexity/noExcessiveCognitiveComplexity: the provider is a linear sync/write state machine with explicit guards.

import * as Y from "yjs";

import type { ZyncBaseClient } from "../client.js";
import { ErrorCodes, ZyncBaseError } from "../errors.js";
import type {
	CollectionsOf,
	ConnectionStatus,
	DisconnectDetail,
	JsonValue,
	SchemaLike,
	Store,
	SubscriptionHandle,
} from "../types.js";
import { generateUUIDv7 } from "../uuid.js";
import {
	ChunkAssembler,
	chunkPayload,
	YJS_DOCUMENTS_COLLECTION,
	YJS_SNAPSHOTS_COLLECTION,
	YJS_UPDATES_COLLECTION,
	type YjsDocumentRow,
} from "./storage.js";

export type YjsProviderStatus = "connecting" | "connected" | "disconnected";

/** Events emitted by `ZyncBaseYjsProvider`. */
export interface ZyncBaseYjsProviderEvents {
	status: { status: YjsProviderStatus };
	sync: boolean;
	"connection-close": DisconnectDetail;
	"connection-error": unknown;
	error: unknown;
	destroy: undefined;
}

type EventName = keyof ZyncBaseYjsProviderEvents;
type EventHandler<T> = (payload: T) => void;

/** Thrown when `documentId` has no row in the configured documents collection. */
export class YjsDocumentNotFoundError extends Error {
	readonly code = "YJS_DOCUMENT_NOT_FOUND";
	readonly documentId: string;

	constructor(documentId: string) {
		super(`Yjs document header not found: ${documentId}`);
		this.name = "YjsDocumentNotFoundError";
		this.documentId = documentId;
	}
}

/** The compactor removed an uncommitted update group before this writer committed it. */
class YjsUpdateCommitConflictError extends Error {
	constructor() {
		super("Yjs update group was abandoned before its commit marker");
		this.name = "YjsUpdateCommitConflictError";
	}
}

export interface ZyncBaseYjsProviderOptions<S extends object = SchemaLike> {
	/** Collection names; defaults match `yjsStoreSchema`. */
	collections?: {
		documents?: CollectionsOf<S>;
		snapshots?: CollectionsOf<S>;
		updates?: CollectionsOf<S>;
	};
	/** Maximum payload bytes stored per row. Default 32 KiB. */
	chunkSize?: number;
	/** Rows fetched per history/snapshot page. Default 64. */
	pageSize?: number;
	/** Local write batching window in milliseconds. Default 150. */
	writeDebounceMs?: number;
	/** Auto-connect in the constructor. Default true, like `y-websocket`. */
	connect?: boolean;
	/** Initial write/sync retry delay in milliseconds. Default 500. */
	retryDelayMs?: number;
	/** Maximum retry delay in milliseconds. Default 30_000. */
	maxRetryDelayMs?: number;
}

interface WritePlan {
	updateId: string;
	merged: Uint8Array;
	parts: Uint8Array[];
	rowIds: string[];
}

/** Bounded set helpers: evicting an id is safe because Yjs updates are idempotent. */
const APPLIED_ID_LIMIT = 4_096;
const SEEN_ROW_LIMIT = 10_000;

function remember(set: Set<string>, id: string, limit: number): void {
	if (set.has(id)) return;
	set.add(id);
	if (set.size <= limit) return;
	const first = set.values().next().value;
	if (first !== undefined) set.delete(first);
}

function isRecord(value: JsonValue | null | undefined): value is {
	[key: string]: JsonValue;
} {
	return (
		value !== null &&
		value !== undefined &&
		typeof value === "object" &&
		!Array.isArray(value) &&
		!(value instanceof Uint8Array)
	);
}

function isResponseTooLarge(error: unknown): boolean {
	return (
		error instanceof ZyncBaseError &&
		error.code === ErrorCodes.RESPONSE_TOO_LARGE
	);
}

function isRetryable(error: unknown): boolean {
	if (!(error instanceof ZyncBaseError)) return false;
	// Writes can land while the client socket is connected but the session is
	// still restoring; that is transient even though the SDK marks the code
	// non-retryable.
	if (error.code === ErrorCodes.SESSION_NOT_READY) return true;
	return error.retryable;
}

function isPreconditionFailed(error: unknown): boolean {
	return (
		error instanceof ZyncBaseError &&
		error.code === ErrorCodes.PRECONDITION_FAILED
	);
}

/**
 * Persists and synchronizes a `Y.Doc` through ZyncBase.
 *
 * The document header row in `yjs_documents` is owned by the application. The
 * provider appends chunked updates to `yjs_updates`, subscribes to updates for
 * the document, and applies the committed snapshot from `yjs_snapshots`.
 */
export class ZyncBaseYjsProvider<
	S extends object = SchemaLike,
	A = never,
	P = never,
> {
	readonly documentId: string;
	readonly doc: Y.Doc;

	private readonly client: ZyncBaseClient<S, A, P>;
	private readonly store: Store;
	private readonly documentsCollection: string;
	private readonly snapshotsCollection: string;
	private readonly updatesCollection: string;
	private readonly chunkSize: number;
	private readonly pageSize: number;
	private readonly writeDebounceMs: number;
	private readonly retryDelayMs: number;
	private readonly maxRetryDelayMs: number;

	private readonly listeners = new Map<EventName, Set<EventHandler<never>>>();
	private readonly assembler = new ChunkAssembler();
	private readonly applied = new Set<string>();
	private readonly seenRows = new Set<string>();

	private pending: Uint8Array[] = [];
	private plan: WritePlan | null = null;
	private draining: Promise<void> | null = null;
	private flushTimer: ReturnType<typeof setTimeout> | null = null;
	private retryTimer: ReturnType<typeof setTimeout> | null = null;
	private retryAttempt = 0;
	private writeBlocked = false;

	private subscription: SubscriptionHandle | null = null;
	private syncPromise: Promise<void> | null = null;
	private syncQueued = false;
	private syncRetryTimer: ReturnType<typeof setTimeout> | null = null;
	private syncRetryAttempt = 0;

	private connectPromise: Promise<void> | null = null;
	private clientListenersAttached = false;
	private active = false;
	private connecting = false;
	private destroyed = false;
	private autoConnectCancelled = false;
	private statusValue: YjsProviderStatus = "disconnected";
	private syncedValue = false;
	private generation = 0;

	constructor(
		client: ZyncBaseClient<S, A, P>,
		documentId: string,
		doc: Y.Doc,
		options: ZyncBaseYjsProviderOptions<S> = {},
	) {
		if (typeof documentId !== "string" || documentId.length === 0) {
			throw new TypeError("documentId must be a non-empty string");
		}
		this.client = client;
		this.documentId = documentId;
		this.doc = doc;
		this.store = client.store as unknown as Store;
		this.documentsCollection =
			(options.collections?.documents as string | undefined) ??
			YJS_DOCUMENTS_COLLECTION;
		this.snapshotsCollection =
			(options.collections?.snapshots as string | undefined) ??
			YJS_SNAPSHOTS_COLLECTION;
		this.updatesCollection =
			(options.collections?.updates as string | undefined) ??
			YJS_UPDATES_COLLECTION;
		this.chunkSize = options.chunkSize ?? 32 * 1024;
		this.pageSize = options.pageSize ?? 64;
		this.writeDebounceMs = options.writeDebounceMs ?? 150;
		this.retryDelayMs = options.retryDelayMs ?? 500;
		this.maxRetryDelayMs = options.maxRetryDelayMs ?? 30_000;

		if (!Number.isInteger(this.chunkSize) || this.chunkSize < 1) {
			throw new RangeError("chunkSize must be a positive integer");
		}
		if (!Number.isInteger(this.pageSize) || this.pageSize < 1) {
			throw new RangeError("pageSize must be a positive integer");
		}
		if (!Number.isInteger(this.writeDebounceMs) || this.writeDebounceMs < 0) {
			throw new RangeError("writeDebounceMs must be a non-negative integer");
		}
		if (!Number.isInteger(this.retryDelayMs) || this.retryDelayMs < 0) {
			throw new RangeError("retryDelayMs must be a non-negative integer");
		}
		if (
			!Number.isInteger(this.maxRetryDelayMs) ||
			this.maxRetryDelayMs < this.retryDelayMs
		) {
			throw new RangeError(
				"maxRetryDelayMs must be an integer greater than or equal to retryDelayMs",
			);
		}

		this.doc.on("update", this.handleDocUpdate);
		this.doc.on("destroy", this.handleDocDestroy);

		if (options.connect !== false) {
			queueMicrotask(() => {
				if (this.autoConnectCancelled || this.destroyed || this.active) {
					return;
				}
				void this.connect().catch(() => {});
			});
		}
	}

	// ─── Public lifecycle ────────────────────────────────────────────────────

	get synced(): boolean {
		return this.syncedValue;
	}

	get connected(): boolean {
		return this.active && this.client.status === "connected";
	}

	get status(): YjsProviderStatus {
		return this.statusValue;
	}

	on<K extends EventName>(
		event: K,
		handler: EventHandler<ZyncBaseYjsProviderEvents[K]>,
	): this {
		let handlers = this.listeners.get(event);
		if (handlers === undefined) {
			handlers = new Set();
			this.listeners.set(event, handlers);
		}
		handlers.add(handler as EventHandler<never>);
		return this;
	}

	off<K extends EventName>(
		event: K,
		handler: EventHandler<ZyncBaseYjsProviderEvents[K]>,
	): this {
		this.listeners.get(event)?.delete(handler as EventHandler<never>);
		return this;
	}

	/**
	 * Connects the shared client if needed, loads the document snapshot and
	 * update history, then resolves once the initial sync is complete.
	 */
	connect(): Promise<void> {
		if (this.destroyed) {
			return Promise.reject(new Error("Yjs provider has been destroyed"));
		}
		if (this.connectPromise !== null) return this.connectPromise;
		if (this.active && this.syncedValue) return Promise.resolve();

		const generation = ++this.generation;
		this.active = true;
		this.connecting = true;
		this.attachClientListeners();
		this.setStatus("connecting");

		let promise: Promise<void>;
		promise = this.runConnect(generation).finally(() => {
			if (this.connectPromise === promise) this.connectPromise = null;
		});
		this.connectPromise = promise;
		return promise;
	}

	/**
	 * Stops syncing without disconnecting the shared client. Local edits are
	 * buffered and flushed after a later `connect()`.
	 */
	disconnect(): void {
		if (this.destroyed) return;
		this.autoConnectCancelled = true;
		this.active = false;
		this.connecting = false;
		this.generation += 1;
		this.connectPromise = null;
		this.syncPromise = null;
		this.syncQueued = false;
		this.clearTimers();
		this.detachClientListeners();
		const subscription = this.subscription;
		this.subscription = null;
		if (subscription !== null) {
			void subscription.unsubscribe().catch(() => {});
		}
		this.setSynced(false);
		this.setStatus("disconnected");
	}

	/** Tears down listeners and timers. Does not disconnect the shared client. */
	destroy(): void {
		if (this.destroyed) return;
		this.disconnect();
		this.destroyed = true;
		this.doc.off("update", this.handleDocUpdate);
		this.doc.off("destroy", this.handleDocDestroy);
		this.pending = [];
		this.plan = null;
		this.emit("destroy", undefined);
		this.listeners.clear();
	}

	/**
	 * Forces buffered local edits to be written. Rejects when the provider is
	 * not connected or a write fails; failed bytes stay queued.
	 *
	 * `flush()` is also the explicit retry after a non-retryable write failure:
	 * it clears the write block and retries the retained payload before any
	 * later queued deltas. Transient failures are reported to the caller while
	 * automatic backoff continues.
	 */
	async flush(): Promise<void> {
		if (this.destroyed) {
			throw new Error("Yjs provider has been destroyed");
		}
		if (
			this.plan === null &&
			this.pending.length === 0 &&
			this.draining === null
		) {
			return;
		}
		if (!this.active || this.client.status !== "connected") {
			throw notConnectedError();
		}
		if (this.flushTimer !== null) {
			clearTimeout(this.flushTimer);
			this.flushTimer = null;
		}
		let failure: unknown;
		const wasBlocked = this.writeBlocked;
		if (this.draining !== null) {
			try {
				await this.draining;
			} catch (error) {
				failure = error;
			}
		}
		if (failure !== undefined) {
			if (
				this.plan === null &&
				this.pending.length === 0 &&
				this.draining === null
			) {
				return;
			}
			if (!wasBlocked) throw failure;
		}
		if (wasBlocked) this.writeBlocked = false;
		return this.drain();
	}

	// ─── Connection / sync ───────────────────────────────────────────────────

	private attachClientListeners(): void {
		if (this.clientListenersAttached) return;
		this.client.on("statusChange", this.handleClientStatus);
		this.client.on("synced", this.handleClientSynced);
		this.client.on("disconnected", this.handleClientDisconnected);
		this.client.on("error", this.handleClientError);
		this.clientListenersAttached = true;
	}

	private detachClientListeners(): void {
		if (!this.clientListenersAttached) return;
		this.client.off("statusChange", this.handleClientStatus);
		this.client.off("synced", this.handleClientSynced);
		this.client.off("disconnected", this.handleClientDisconnected);
		this.client.off("error", this.handleClientError);
		this.clientListenersAttached = false;
	}

	private handleClientStatus = (status: ConnectionStatus): void => {
		if (!this.active || this.destroyed) return;
		if (status === "disconnected") {
			this.setSynced(false);
			this.setStatus("disconnected");
			return;
		}
		if (status === "connected") {
			this.setStatus("connected");
			return;
		}
		this.setStatus("connecting");
	};

	private handleClientSynced = (): void => {
		if (!this.active || this.connecting || this.destroyed) return;
		if (this.syncRetryTimer !== null) {
			clearTimeout(this.syncRetryTimer);
			this.syncRetryTimer = null;
		}
		this.resync();
	};

	private handleClientDisconnected = (detail: DisconnectDetail): void => {
		if (!this.active || this.destroyed) return;
		this.setSynced(false);
		this.setStatus("disconnected");
		this.emit("connection-close", detail);
	};

	private handleClientError = (error: ZyncBaseError): void => {
		if (this.destroyed) return;
		this.emit("connection-error", error);
	};

	private async runConnect(generation: number): Promise<void> {
		try {
			if (this.client.status === "disconnected") {
				await this.client.connect();
			}
			if (generation !== this.generation) throw abortedError();

			if (this.subscription === null) {
				const subscription = await this.store.subscribe(
					this.updatesCollection,
					{
						where: { document_id: this.documentId },
						orderBy: [{ created_at: "desc" }],
						limit: 1,
					},
					this.handleSubscriptionRows,
				);
				if (generation !== this.generation) {
					await subscription.unsubscribe();
					throw abortedError();
				}
				this.subscription = subscription;
			}

			const header = await this.readHeader();
			if (generation !== this.generation) throw abortedError();
			if (header === null) {
				throw new YjsDocumentNotFoundError(this.documentId);
			}

			this.setStatus(
				this.client.status === "connected" ? "connected" : "connecting",
			);
			await this.syncStore(generation);
			if (generation !== this.generation) throw abortedError();

			this.connecting = false;
			this.syncRetryAttempt = 0;
			this.retryAttempt = 0;
			this.setSynced(true);
			if (generation !== this.generation || !this.active || this.destroyed) {
				return;
			}
			this.setStatus("connected");
			void this.drain().catch((error: unknown) => this.emitError(error));
		} catch (error) {
			if (generation === this.generation) {
				this.connecting = false;
				this.active = false;
				this.setSynced(false);
				this.setStatus("disconnected");
				this.detachClientListeners();
				await this.clearSubscription();
				this.emitError(error);
			}
			throw error;
		}
	}

	private resync(): void {
		const generation = this.generation;
		void this.syncStore(generation)
			.then(() => {
				if (generation !== this.generation || !this.active) return;
				this.syncRetryAttempt = 0;
				this.retryAttempt = 0;
				this.setSynced(true);
				if (generation !== this.generation || !this.active || this.destroyed) {
					return;
				}
				this.setStatus("connected");
				void this.drain().catch((error: unknown) => this.emitError(error));
			})
			.catch((error: unknown) => {
				if (generation !== this.generation || !this.active) return;
				this.setSynced(false);
				this.emitError(error);
				if (error instanceof YjsDocumentNotFoundError) {
					this.active = false;
					this.setStatus("disconnected");
					this.detachClientListeners();
					void this.clearSubscription();
					return;
				}
				if (isRetryable(error)) this.scheduleSyncRetry();
			});
	}

	private syncStore(generation: number): Promise<void> {
		if (this.syncPromise !== null) {
			this.syncQueued = true;
			return this.syncPromise;
		}
		let promise: Promise<void>;
		promise = this.runSync(generation).finally(() => {
			if (this.syncPromise === promise) this.syncPromise = null;
			if (this.syncQueued) {
				this.syncQueued = false;
				if (this.active && !this.destroyed) this.resync();
			}
		});
		this.syncPromise = promise;
		return promise;
	}

	private async runSync(generation: number): Promise<void> {
		this.assembler.reset();
		this.seenRows.clear();
		const appliedSnapshots = new Set<string>();

		for (let attempt = 0; attempt < 3; attempt += 1) {
			if (generation !== this.generation) return;

			const header = await this.readHeader();
			if (generation !== this.generation) return;
			if (header === null) throw new YjsDocumentNotFoundError(this.documentId);

			const snapshotId = header.current_snapshot_id ?? null;

			if (snapshotId !== null && !appliedSnapshots.has(snapshotId)) {
				const applied = await this.applySnapshot(snapshotId, generation);
				if (generation !== this.generation) return;
				if (!applied) {
					const after = await this.readHeader();
					if (generation !== this.generation) return;
					if (after === null) {
						throw new YjsDocumentNotFoundError(this.documentId);
					}
					if ((after.current_snapshot_id ?? null) !== snapshotId) continue;
					throw new Error(
						`Yjs snapshot "${snapshotId}" for document "${this.documentId}" is incomplete`,
					);
				}
				appliedSnapshots.add(snapshotId);
			}

			await this.readUpdates(generation);
			if (generation !== this.generation) return;

			const after = await this.readHeader();
			if (generation !== this.generation) return;
			if (after === null) throw new YjsDocumentNotFoundError(this.documentId);
			if ((after.current_snapshot_id ?? null) === snapshotId) {
				return;
			}
		}

		throw new Error(
			`Yjs document "${this.documentId}" is being compacted continuously`,
		);
	}

	private async readHeader(): Promise<YjsDocumentRow | null> {
		const row = await this.store.get([
			this.documentsCollection,
			this.documentId,
		]);
		if (!isRecord(row)) return null;
		return {
			id: typeof row.id === "string" ? row.id : this.documentId,
			current_snapshot_id:
				typeof row.current_snapshot_id === "string"
					? row.current_snapshot_id
					: null,
			compacted_through:
				typeof row.compacted_through === "number"
					? row.compacted_through
					: null,
		};
	}

	private async readUpdates(generation: number): Promise<void> {
		const where: Record<string, JsonValue> = {
			document_id: this.documentId,
		};

		let after: string | undefined;
		let limit = this.pageSize;
		for (;;) {
			let page: JsonValue[] & { nextCursor: string | null };
			try {
				page = (await this.store.query(this.updatesCollection, {
					where,
					orderBy: [{ created_at: "asc" }],
					limit,
					...(after === undefined ? {} : { after }),
				})) as JsonValue[] & { nextCursor: string | null };
			} catch (error) {
				if (isResponseTooLarge(error) && limit > 1) {
					limit = Math.max(1, Math.floor(limit / 2));
					continue;
				}
				throw error;
			}
			if (generation !== this.generation) return;
			for (const row of page) this.ingestUpdateRow(row);
			after = page.nextCursor ?? undefined;
			if (after === undefined) return;
		}
	}

	private async applySnapshot(
		snapshotId: string,
		generation: number,
	): Promise<boolean> {
		const assembler = new ChunkAssembler();
		let after: string | undefined;
		let limit = this.pageSize;

		for (;;) {
			let page: JsonValue[] & { nextCursor: string | null };
			try {
				page = (await this.store.query(this.snapshotsCollection, {
					where: {
						document_id: this.documentId,
						snapshot_id: snapshotId,
					},
					orderBy: [{ created_at: "asc" }],
					limit,
					...(after === undefined ? {} : { after }),
				})) as JsonValue[] & { nextCursor: string | null };
			} catch (error) {
				if (isResponseTooLarge(error) && limit > 1) {
					limit = Math.max(1, Math.floor(limit / 2));
					continue;
				}
				throw error;
			}
			if (generation !== this.generation) return false;

			for (const row of page) {
				if (!isRecord(row)) continue;
				if (
					row.document_id !== this.documentId ||
					row.snapshot_id !== snapshotId
				) {
					continue;
				}
				const part = row.part;
				const parts = row.parts;
				if (typeof part !== "number" || typeof parts !== "number") continue;
				const data = row.data;
				if (part < parts && !(data instanceof Uint8Array)) continue;
				const assembled = assembler.add({
					id: typeof row.id === "string" ? row.id : "",
					payloadId: snapshotId,
					part,
					parts,
					data: data instanceof Uint8Array ? data : null,
				});
				if (assembled === null) continue;
				try {
					Y.applyUpdate(this.doc, assembled.bytes, this);
				} catch (error) {
					this.emitError(error);
					return false;
				}
				return true;
			}

			after = page.nextCursor ?? undefined;
			if (after === undefined) return false;
		}
	}

	private handleSubscriptionRows = (rows: JsonValue[]): void => {
		if (!this.active || this.destroyed) return;
		for (const row of rows) this.ingestUpdateRow(row);
	};

	private ingestUpdateRow(row: JsonValue): void {
		if (!isRecord(row)) return;
		const id = row.id;
		if (typeof id !== "string") return;
		const updatedAt = typeof row.updated_at === "number" ? row.updated_at : 0;
		const seenKey = `${id}:${updatedAt}`;
		if (this.seenRows.has(seenKey)) return;
		remember(this.seenRows, seenKey, SEEN_ROW_LIMIT);

		const updateId = row.update_id;
		if (
			typeof updateId !== "string" ||
			updateId.length === 0 ||
			this.applied.has(updateId)
		) {
			return;
		}
		const part = row.part;
		const parts = row.parts;
		if (typeof part !== "number" || typeof parts !== "number") return;
		const data = row.data;
		if (part < parts && !(data instanceof Uint8Array)) return;
		const committed =
			row.committed === false
				? false
				: row.committed === true
					? true
					: undefined;

		const assembled = this.assembler.add({
			id,
			payloadId: updateId,
			part,
			parts,
			data: data instanceof Uint8Array ? data : null,
			committed,
		});
		if (assembled === null) return;

		try {
			Y.applyUpdate(this.doc, assembled.bytes, this);
			remember(this.applied, updateId, APPLIED_ID_LIMIT);
		} catch (error) {
			// A malformed payload must not be retried forever.
			remember(this.applied, updateId, APPLIED_ID_LIMIT);
			this.emitError(error);
		}
	}

	// ─── Local writes ────────────────────────────────────────────────────────

	private handleDocUpdate = (update: Uint8Array, origin: unknown): void => {
		if (origin instanceof ZyncBaseYjsProvider) return;
		this.pending.push(update.slice());
		if (this.active) this.scheduleFlush(this.writeDebounceMs);
	};

	private handleDocDestroy = (): void => {
		this.destroy();
	};

	private scheduleFlush(delay: number): void {
		if (this.flushTimer !== null || !this.active || this.destroyed) return;
		this.flushTimer = setTimeout(() => {
			this.flushTimer = null;
			void this.drain().catch(() => {});
		}, delay);
	}

	private scheduleRetry(): void {
		if (this.retryTimer !== null || !this.active || this.destroyed) return;
		const delay = Math.min(
			this.maxRetryDelayMs,
			this.retryDelayMs * 2 ** this.retryAttempt,
		);
		this.retryAttempt += 1;
		this.retryTimer = setTimeout(() => {
			this.retryTimer = null;
			void this.drain().catch(() => {});
		}, delay);
	}

	private scheduleSyncRetry(): void {
		if (
			this.syncRetryTimer !== null ||
			!this.active ||
			this.destroyed ||
			this.connecting
		) {
			return;
		}
		const delay = Math.min(
			this.maxRetryDelayMs,
			this.retryDelayMs * 2 ** this.syncRetryAttempt,
		);
		this.syncRetryAttempt += 1;
		this.syncRetryTimer = setTimeout(() => {
			this.syncRetryTimer = null;
			if (this.active && !this.destroyed) this.resync();
		}, delay);
	}

	private clearTimers(): void {
		if (this.flushTimer !== null) {
			clearTimeout(this.flushTimer);
			this.flushTimer = null;
		}
		if (this.retryTimer !== null) {
			clearTimeout(this.retryTimer);
			this.retryTimer = null;
		}
		if (this.syncRetryTimer !== null) {
			clearTimeout(this.syncRetryTimer);
			this.syncRetryTimer = null;
		}
	}

	private drain(): Promise<void> {
		if (this.draining !== null) return this.draining;
		let promise: Promise<void>;
		promise = this.runDrain().finally(() => {
			if (this.draining === promise) this.draining = null;
			if (
				this.active &&
				!this.destroyed &&
				this.client.status === "connected" &&
				!this.writeBlocked &&
				this.retryTimer === null &&
				(this.plan !== null || this.pending.length > 0)
			) {
				this.scheduleFlush(0);
			}
		});
		this.draining = promise;
		return promise;
	}

	private async runDrain(): Promise<void> {
		if (this.writeBlocked) return;
		if (!this.active || this.destroyed) {
			if (this.plan !== null || this.pending.length > 0) {
				throw notConnectedError();
			}
			return;
		}
		if (this.client.status !== "connected") {
			if (this.plan !== null || this.pending.length > 0) {
				throw notConnectedError();
			}
			return;
		}
		if (this.retryTimer !== null) {
			clearTimeout(this.retryTimer);
			this.retryTimer = null;
		}

		while (this.plan !== null || this.pending.length > 0) {
			if (!this.active || this.destroyed) {
				throw notConnectedError();
			}
			if (this.client.status !== "connected") {
				throw notConnectedError();
			}

			if (this.plan === null) {
				if (this.pending.length === 0) break;
				const merged =
					this.pending.length === 1
						? (this.pending[0] as Uint8Array)
						: Y.mergeUpdates(this.pending);
				this.pending = [];
				this.plan = this.createPlan(merged);
			}

			const plan = this.plan;
			try {
				await this.writePlan(plan);
			} catch (error) {
				if (error instanceof YjsUpdateCommitConflictError) {
					this.pending.unshift(plan.merged);
					this.plan = null;
					this.scheduleRetry();
					throw error;
				}
				if (isRetryable(error)) {
					this.emitError(error);
					this.scheduleRetry();
					throw error;
				}
				this.writeBlocked = true;
				this.emitError(error);
				throw error;
			}

			remember(this.applied, plan.updateId, APPLIED_ID_LIMIT);
			this.plan = null;
			this.retryAttempt = 0;
		}
	}

	private createPlan(merged: Uint8Array): WritePlan {
		const parts = chunkPayload(merged, this.chunkSize);
		const rowIds = parts.map(() => generateUUIDv7());
		if (parts.length > 1) rowIds.push(generateUUIDv7());
		return {
			updateId: generateUUIDv7(),
			merged,
			parts,
			rowIds,
		};
	}

	private async writePlan(plan: WritePlan): Promise<void> {
		const parts = plan.parts;
		const markerIndex = parts.length;
		const markerRowId =
			parts.length > 1 ? (plan.rowIds[markerIndex] as string) : null;

		if (markerRowId !== null) {
			await this.store.set([this.updatesCollection, markerRowId], {
				document_id: this.documentId,
				update_id: plan.updateId,
				part: parts.length,
				parts: parts.length,
				committed: false,
			});
		}

		for (let index = 0; index < parts.length; index += 1) {
			await this.store.set(
				[this.updatesCollection, plan.rowIds[index] as string],
				{
					document_id: this.documentId,
					update_id: plan.updateId,
					part: index,
					parts: parts.length,
					data: parts[index] as Uint8Array,
				},
			);
		}

		if (markerRowId !== null) {
			try {
				await this.store.set(
					[this.updatesCollection, markerRowId],
					{
						document_id: this.documentId,
						update_id: plan.updateId,
						part: parts.length,
						parts: parts.length,
						committed: true,
					},
					{ if: { committed: { eq: false } } },
				);
			} catch (error) {
				if (isPreconditionFailed(error)) {
					throw new YjsUpdateCommitConflictError();
				}
				throw error;
			}
		}
	}

	// ─── Helpers ─────────────────────────────────────────────────────────────

	private async clearSubscription(): Promise<void> {
		const subscription = this.subscription;
		this.subscription = null;
		if (subscription !== null) {
			await subscription.unsubscribe().catch(() => {});
		}
	}

	private setStatus(status: YjsProviderStatus): void {
		if (this.statusValue === status) return;
		this.statusValue = status;
		this.emit("status", { status });
	}

	private setSynced(synced: boolean): void {
		if (this.syncedValue === synced) return;
		this.syncedValue = synced;
		this.emit("sync", synced);
	}

	private emit<K extends EventName>(
		event: K,
		payload: ZyncBaseYjsProviderEvents[K],
	): void {
		const handlers = this.listeners.get(event);
		if (handlers === undefined) return;
		for (const handler of [...handlers]) {
			try {
				(handler as EventHandler<ZyncBaseYjsProviderEvents[K]>)(payload);
			} catch (error) {
				console.error(`[ZyncBase Yjs] "${event}" handler threw:`, error);
			}
		}
	}

	private emitError(error: unknown): void {
		this.emit("error", error);
	}
}

function abortedError(): Error {
	return new Error("Yjs provider operation was aborted");
}

function notConnectedError(): ZyncBaseError {
	return new ZyncBaseError("Yjs provider is not connected", {
		code: ErrorCodes.CONNECTION_FAILED,
		category: "network",
		retryable: true,
	});
}
