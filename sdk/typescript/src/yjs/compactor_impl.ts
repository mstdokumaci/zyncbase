// biome-ignore-all lint/complexity/noExcessiveCognitiveComplexity: the compactor is a linear scan/commit/cleanup state machine with explicit guards.

import * as Y from "yjs";

import type { ZyncBaseClient } from "../client.js";
import { ErrorCodes, ZyncBaseError } from "../errors.js";
import type {
	BatchOperation,
	CollectionsOf,
	JsonValue,
	QueryOptions,
	SchemaLike,
	SortClause,
	Store,
} from "../types.js";
import { generateUUIDv7 } from "../uuid.js";
import {
	ChunkAssembler,
	chunkPayload,
	YJS_DOCUMENTS_COLLECTION,
	YJS_SNAPSHOTS_COLLECTION,
	YJS_UPDATES_COLLECTION,
} from "./storage.js";

export type YjsCompactorPhase =
	| "pass"
	| "namespace"
	| "scan"
	| "compact"
	| "cleanup";

export interface YjsCompactorErrorContext {
	namespace: string;
	documentId?: string;
	phase: YjsCompactorPhase;
}

export interface YjsCompactedEvent {
	namespace: string;
	documentId: string;
	updates: number;
	bytes: number;
}

export interface YjsCompactorOptions<S extends object = SchemaLike> {
	collections?: {
		documents?: CollectionsOf<S>;
		snapshots?: CollectionsOf<S>;
		updates?: CollectionsOf<S>;
	};
	/**
	 * Namespaces to process. Omit to use the client's current store namespace.
	 * A callback lets a multi-tenant app track active namespaces.
	 *
	 * The worker switches the client's store namespace; give it a dedicated
	 * service client.
	 */
	namespaces?: readonly string[] | (() => Promise<readonly string[]>);
	/** Delay between completed passes. Default 30s. */
	intervalMs?: number;
	/** Delete compacted updates older than this. Default 24h. */
	updateRetentionMs?: number;
	/** Keep old snapshot generations for this long. Default 1h. */
	snapshotRetentionMs?: number;
	/** Delay between bounded cleanup sweeps. Default 10m. */
	cleanupIntervalMs?: number;
	/** Snapshot payload bytes per row. Default 32 KiB. */
	chunkSize?: number;
	/** Query page size. Default 64. */
	pageSize?: number;
	/** Maximum update rows scanned per namespace pass. Default 5000. */
	maxUpdatesPerPass?: number;
	/** Maximum documents compacted per namespace pass. Default 100. */
	maxDocumentsPerPass?: number;
	/** Maximum document headers cleaned per namespace pass. Default 50. */
	maxCleanupDocumentsPerPass?: number;
	/** Per-document error and pass-level error callback. */
	onError?: (error: unknown, context: YjsCompactorErrorContext) => void;
	/** Called after a document snapshot commits. */
	onCompacted?: (event: YjsCompactedEvent) => void;
}

interface RetryEntry {
	attempts: number;
	nextAt: number;
}

interface NamespaceState {
	updateCursor: number;
	retry: Map<string, RetryEntry>;
	cleanupCursor: number | null;
	nextCleanupAt: number;
}

interface UpdateGroup {
	min: number;
	max: number;
	complete: boolean;
	rows: Array<{ id: string; createdAt: number }>;
}

const RETRY_BASE_MS = 1_000;
const RETRY_MAX_MS = 60_000;
const DELETE_BATCH_SIZE = 400;

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

function isPreconditionFailed(error: unknown): boolean {
	return (
		error instanceof ZyncBaseError &&
		error.code === ErrorCodes.PRECONDITION_FAILED
	);
}

function isPositiveInteger(value: number): boolean {
	return Number.isInteger(value) && value > 0;
}

function isNonNegativeInteger(value: number): boolean {
	return Number.isInteger(value) && value >= 0;
}

/**
 * Long-running compactor for the Yjs storage contract.
 *
 * Start it through `startYjsCompactor` and stop it on shutdown.
 */
export class YjsCompactor<S extends object = SchemaLike, A = never, P = never> {
	private readonly client: ZyncBaseClient<S, A, P>;
	private readonly store: Store;
	private readonly documentsCollection: string;
	private readonly snapshotsCollection: string;
	private readonly updatesCollection: string;
	private readonly namespaces:
		| readonly string[]
		| (() => Promise<readonly string[]>)
		| undefined;
	private readonly intervalMs: number;
	private readonly updateRetentionMs: number;
	private readonly snapshotRetentionMs: number;
	private readonly cleanupIntervalMs: number;
	private readonly chunkSize: number;
	private readonly pageSize: number;
	private readonly maxUpdatesPerPass: number;
	private readonly maxDocumentsPerPass: number;
	private readonly maxCleanupDocumentsPerPass: number;
	private readonly onError: (
		error: unknown,
		context: YjsCompactorErrorContext,
	) => void;
	private readonly onCompacted: (event: YjsCompactedEvent) => void;

	private readonly states = new Map<string, NamespaceState>();
	private timer: ReturnType<typeof setTimeout> | null = null;
	private pass: Promise<boolean> | null = null;
	private stopped = false;
	private runningValue = false;

	constructor(
		client: ZyncBaseClient<S, A, P>,
		options: YjsCompactorOptions<S> = {},
	) {
		this.client = client;
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
		this.namespaces = options.namespaces;
		this.intervalMs = options.intervalMs ?? 30_000;
		this.updateRetentionMs = options.updateRetentionMs ?? 24 * 60 * 60_000;
		this.snapshotRetentionMs = options.snapshotRetentionMs ?? 60 * 60_000;
		this.cleanupIntervalMs = options.cleanupIntervalMs ?? 10 * 60_000;
		this.chunkSize = options.chunkSize ?? 32 * 1024;
		this.pageSize = options.pageSize ?? 64;
		this.maxUpdatesPerPass = options.maxUpdatesPerPass ?? 5_000;
		this.maxDocumentsPerPass = options.maxDocumentsPerPass ?? 100;
		this.maxCleanupDocumentsPerPass = options.maxCleanupDocumentsPerPass ?? 50;
		this.onError =
			options.onError ??
			((error, context) =>
				console.error("[ZyncBase Yjs compactor]", error, context));
		this.onCompacted = options.onCompacted ?? (() => {});

		if (!isPositiveInteger(this.intervalMs)) {
			throw new RangeError("intervalMs must be a positive integer");
		}
		if (!isNonNegativeInteger(this.updateRetentionMs)) {
			throw new RangeError("updateRetentionMs must be a non-negative integer");
		}
		if (!isNonNegativeInteger(this.snapshotRetentionMs)) {
			throw new RangeError(
				"snapshotRetentionMs must be a non-negative integer",
			);
		}
		if (!isNonNegativeInteger(this.cleanupIntervalMs)) {
			throw new RangeError("cleanupIntervalMs must be a non-negative integer");
		}
		if (!isPositiveInteger(this.chunkSize)) {
			throw new RangeError("chunkSize must be a positive integer");
		}
		if (!isPositiveInteger(this.pageSize)) {
			throw new RangeError("pageSize must be a positive integer");
		}
		if (!isPositiveInteger(this.maxUpdatesPerPass)) {
			throw new RangeError("maxUpdatesPerPass must be a positive integer");
		}
		if (!isPositiveInteger(this.maxDocumentsPerPass)) {
			throw new RangeError("maxDocumentsPerPass must be a positive integer");
		}
		if (!isPositiveInteger(this.maxCleanupDocumentsPerPass)) {
			throw new RangeError(
				"maxCleanupDocumentsPerPass must be a positive integer",
			);
		}
	}

	get running(): boolean {
		return this.runningValue;
	}

	start(): void {
		if (this.runningValue) return;
		this.runningValue = true;
		this.stopped = false;
		void this.loop();
	}

	async stop(): Promise<void> {
		this.stopped = true;
		this.runningValue = false;
		if (this.timer !== null) {
			clearTimeout(this.timer);
			this.timer = null;
		}
		const pass = this.pass;
		if (pass !== null) await pass.catch(() => {});
	}

	/** Run one full pass. Used by the loop and by deterministic unit tests. */
	async runPass(): Promise<boolean> {
		const namespaces = await this.resolveNamespaces();
		let hasMore = false;
		for (const namespace of namespaces) {
			if (this.stopped) break;
			if (namespace !== "") {
				try {
					await this.client.setStoreNamespace(namespace);
				} catch (error) {
					this.reportError(error, { namespace, phase: "namespace" });
					continue;
				}
			}
			try {
				const more = await this.runNamespacePass(namespace);
				hasMore = hasMore || more;
			} catch (error) {
				this.reportError(error, { namespace, phase: "scan" });
			}
		}
		return hasMore;
	}

	// ─── Loop ────────────────────────────────────────────────────────────────

	private async loop(): Promise<void> {
		if (this.stopped) return;
		const pass = this.runPass();
		this.pass = pass;
		let hasMore = false;
		try {
			hasMore = await pass;
		} catch (error) {
			this.reportError(error, { namespace: "", phase: "pass" });
		} finally {
			if (this.pass === pass) this.pass = null;
		}
		if (this.stopped) return;
		this.timer = setTimeout(
			() => {
				this.timer = null;
				void this.loop();
			},
			hasMore ? 0 : this.intervalMs,
		);
	}

	private async resolveNamespaces(): Promise<string[]> {
		if (this.namespaces === undefined) return [""];
		const values =
			typeof this.namespaces === "function"
				? await this.namespaces()
				: this.namespaces;
		const unique: string[] = [];
		for (const value of values) {
			if (
				typeof value === "string" &&
				value.length > 0 &&
				!unique.includes(value)
			) {
				unique.push(value);
			}
		}
		return unique;
	}

	private stateFor(namespace: string): NamespaceState {
		let state = this.states.get(namespace);
		if (state === undefined) {
			state = {
				updateCursor: 0,
				retry: new Map(),
				cleanupCursor: null,
				nextCleanupAt: 0,
			};
			this.states.set(namespace, state);
		}
		return state;
	}

	// ─── Namespace pass ──────────────────────────────────────────────────────

	private async runNamespacePass(namespace: string): Promise<boolean> {
		const state = this.stateFor(namespace);
		const discovered = await this.discover(state);

		const now = Date.now();
		const documents = new Set(discovered.documents);
		for (const [documentId, retry] of state.retry) {
			if (retry.nextAt <= now) documents.add(documentId);
		}

		let hasMore = discovered.hasMore;
		const list = [...documents];
		if (list.length > this.maxDocumentsPerPass) {
			for (const documentId of list.slice(this.maxDocumentsPerPass)) {
				this.defer(state, documentId);
			}
			list.length = this.maxDocumentsPerPass;
			hasMore = true;
		}

		for (const documentId of list) {
			if (this.stopped) break;
			try {
				const result = await this.compactDocument(namespace, documentId);
				if (result === "compacted" || result === "skipped") {
					state.retry.delete(documentId);
				} else {
					this.scheduleRetry(state, documentId);
				}
			} catch (error) {
				this.reportError(error, {
					namespace,
					documentId,
					phase: "compact",
				});
				this.scheduleRetry(state, documentId);
			}
		}

		if (!this.stopped && Date.now() >= state.nextCleanupAt) {
			const more = await this.cleanupNamespace(namespace, state);
			hasMore = hasMore || more;
		}
		return hasMore;
	}

	private async discover(
		state: NamespaceState,
	): Promise<{ documents: Set<string>; hasMore: boolean }> {
		const documents = new Set<string>();
		let scanned = 0;
		let hasMore = false;
		let lastCreatedAt = state.updateCursor;

		for await (const page of this.pages(
			this.updatesCollection,
			{ created_at: { gt: state.updateCursor } },
			[{ created_at: "asc" }],
		)) {
			for (const value of page) {
				if (!isRecord(value)) continue;
				const documentId = value.document_id;
				if (typeof documentId === "string" && documentId.length > 0) {
					documents.add(documentId);
				}
				const createdAt = value.created_at;
				if (typeof createdAt === "number" && createdAt > lastCreatedAt) {
					lastCreatedAt = createdAt;
				}
			}
			scanned += page.length;
			if (this.stopped) break;
			if (scanned >= this.maxUpdatesPerPass) {
				hasMore = page.nextCursor !== null;
				break;
			}
		}

		state.updateCursor = lastCreatedAt;
		return { documents, hasMore };
	}

	private defer(state: NamespaceState, documentId: string): void {
		const existing = state.retry.get(documentId);
		state.retry.set(documentId, {
			attempts: existing?.attempts ?? 0,
			nextAt: Date.now(),
		});
	}

	private scheduleRetry(state: NamespaceState, documentId: string): void {
		const attempts = (state.retry.get(documentId)?.attempts ?? 0) + 1;
		const delay = Math.min(RETRY_MAX_MS, RETRY_BASE_MS * 2 ** (attempts - 1));
		state.retry.set(documentId, {
			attempts,
			nextAt: Date.now() + delay,
		});
	}

	// ─── Document compaction ─────────────────────────────────────────────────

	private async compactDocument(
		namespace: string,
		documentId: string,
	): Promise<"compacted" | "skipped" | "incomplete" | "conflict"> {
		const rawHeader = await this.store.get([
			this.documentsCollection,
			documentId,
		]);
		if (!isRecord(rawHeader)) return "skipped";

		const rawVersion = rawHeader.compaction_version;
		if (
			typeof rawVersion !== "number" ||
			!Number.isInteger(rawVersion) ||
			rawVersion < 0
		) {
			throw new Error(
				`Yjs document "${documentId}" is missing an integer compaction_version`,
			);
		}
		const version = rawVersion;
		const currentSnapshotId =
			typeof rawHeader.current_snapshot_id === "string"
				? rawHeader.current_snapshot_id
				: null;
		const watermark =
			typeof rawHeader.compacted_through === "number"
				? rawHeader.compacted_through
				: null;
		if (watermark !== null && currentSnapshotId === null) {
			throw new Error(
				`Yjs document "${documentId}" has compacted_through without a snapshot`,
			);
		}

		const doc = new Y.Doc();
		try {
			if (currentSnapshotId !== null) {
				const snapshot = await this.readSnapshot(documentId, currentSnapshotId);
				if (snapshot === null) return "incomplete";
				Y.applyUpdate(doc, snapshot);
			}

			const where: Record<string, JsonValue> = {
				document_id: documentId,
			};
			if (watermark !== null) where.created_at = { gt: watermark };

			const assembler = new ChunkAssembler();
			const groups = new Map<string, UpdateGroup>();
			for await (const page of this.pages(this.updatesCollection, where, [
				{ created_at: "asc" },
			])) {
				for (const value of page) {
					if (!isRecord(value)) continue;
					if (value.document_id !== documentId) continue;
					const updateId = value.update_id;
					if (typeof updateId !== "string" || updateId.length === 0) {
						continue;
					}
					const part = value.part;
					const parts = value.parts;
					if (typeof part !== "number" || typeof parts !== "number") {
						continue;
					}
					const data = value.data;
					if (part < parts && !(data instanceof Uint8Array)) continue;
					const createdAt =
						typeof value.created_at === "number" ? value.created_at : 0;
					let group = groups.get(updateId);
					if (group === undefined) {
						group = {
							min: createdAt,
							max: createdAt,
							complete: false,
							rows: [],
						};
						groups.set(updateId, group);
					}
					group.min = Math.min(group.min, createdAt);
					group.max = Math.max(group.max, createdAt);
					const rowId = typeof value.id === "string" ? value.id : "";
					if (rowId.length > 0) {
						group.rows.push({ id: rowId, createdAt });
					}
					const assembled = assembler.add({
						id: rowId,
						payloadId: updateId,
						part,
						parts,
						data: data instanceof Uint8Array ? data : null,
					});
					if (assembled !== null) {
						Y.applyUpdate(doc, assembled.bytes);
						group.complete = true;
					}
				}
				if (this.stopped) return "skipped";
			}

			const now = Date.now() * 1_000;
			const updateCutoff = now - this.updateRetentionMs * 1_000;
			const completeGroups: UpdateGroup[] = [];
			const activeIncomplete: UpdateGroup[] = [];
			const abandoned: Array<{ id: string; createdAt: number }> = [];
			for (const group of groups.values()) {
				if (group.complete) {
					completeGroups.push(group);
				} else if (group.max < updateCutoff) {
					abandoned.push(...group.rows);
				} else {
					activeIncomplete.push(group);
				}
			}
			await this.deleteRows(this.updatesCollection, abandoned);

			if (completeGroups.length === 0) {
				return activeIncomplete.length > 0 ? "incomplete" : "skipped";
			}

			const maxComplete = Math.max(...completeGroups.map((group) => group.max));
			const minIncomplete =
				activeIncomplete.length === 0
					? null
					: Math.min(...activeIncomplete.map((group) => group.min));
			const nextWatermark =
				minIncomplete === null
					? maxComplete
					: Math.min(maxComplete, minIncomplete - 1);
			if (watermark !== null && nextWatermark <= watermark) {
				return activeIncomplete.length > 0 ? "incomplete" : "skipped";
			}

			const bytes = Y.encodeStateAsUpdate(doc);
			const snapshotId = await this.writeSnapshot(documentId, bytes);
			try {
				await this.store.batch([
					{
						op: "set",
						path: [this.documentsCollection, documentId, "current_snapshot_id"],
						value: snapshotId,
						if: { compaction_version: { eq: version } },
					},
					{
						op: "set",
						path: [this.documentsCollection, documentId, "compacted_through"],
						value: nextWatermark,
						if: { compaction_version: { eq: version } },
					},
					{
						op: "set",
						path: [this.documentsCollection, documentId, "compaction_version"],
						value: version + 1,
						if: { compaction_version: { eq: version } },
					},
				]);
			} catch (error) {
				if (isPreconditionFailed(error)) return "conflict";
				throw error;
			}

			const removable: Array<{ id: string; createdAt: number }> = [];
			for (const group of completeGroups) {
				for (const row of group.rows) {
					if (row.createdAt <= nextWatermark && row.createdAt < updateCutoff) {
						removable.push(row);
					}
				}
			}
			await this.deleteRows(this.updatesCollection, removable);

			this.emitCompacted({
				namespace,
				documentId,
				updates: completeGroups.length,
				bytes: bytes.length,
			});
			return "compacted";
		} finally {
			doc.destroy();
		}
	}

	private async readSnapshot(
		documentId: string,
		snapshotId: string,
	): Promise<Uint8Array | null> {
		const assembler = new ChunkAssembler();
		for await (const page of this.pages(
			this.snapshotsCollection,
			{ document_id: documentId, snapshot_id: snapshotId },
			[{ created_at: "asc" }],
		)) {
			for (const value of page) {
				if (!isRecord(value)) continue;
				if (
					value.document_id !== documentId ||
					value.snapshot_id !== snapshotId
				) {
					continue;
				}
				const part = value.part;
				const parts = value.parts;
				if (typeof part !== "number" || typeof parts !== "number") continue;
				const data = value.data;
				if (part < parts && !(data instanceof Uint8Array)) continue;
				const assembled = assembler.add({
					id: typeof value.id === "string" ? value.id : "",
					payloadId: snapshotId,
					part,
					parts,
					data: data instanceof Uint8Array ? data : null,
				});
				if (assembled !== null) return assembled.bytes;
			}
			if (this.stopped) return null;
		}
		return null;
	}

	private async writeSnapshot(
		documentId: string,
		bytes: Uint8Array,
	): Promise<string> {
		const snapshotId = generateUUIDv7();
		const parts = chunkPayload(bytes, this.chunkSize);
		for (let index = 0; index < parts.length; index += 1) {
			await this.store.set([this.snapshotsCollection, generateUUIDv7()], {
				document_id: documentId,
				snapshot_id: snapshotId,
				part: index,
				parts: parts.length,
				data: parts[index] as Uint8Array,
			});
			if (this.stopped) return snapshotId;
		}
		if (parts.length > 1) {
			await this.store.set([this.snapshotsCollection, generateUUIDv7()], {
				document_id: documentId,
				snapshot_id: snapshotId,
				part: parts.length,
				parts: parts.length,
			});
		}
		return snapshotId;
	}

	// ─── Cleanup ─────────────────────────────────────────────────────────────

	private async cleanupNamespace(
		namespace: string,
		state: NamespaceState,
	): Promise<boolean> {
		const now = Date.now();
		const nowMicros = now * 1_000;
		const updateCutoff = nowMicros - this.updateRetentionMs * 1_000;
		const snapshotCutoff = nowMicros - this.snapshotRetentionMs * 1_000;
		const where: Record<string, JsonValue> =
			state.cleanupCursor === null
				? {}
				: { created_at: { gt: state.cleanupCursor } };
		let processed = 0;
		let lastCreatedAt = state.cleanupCursor ?? 0;

		for await (const page of this.pages(this.documentsCollection, where, [
			{ created_at: "asc" },
		])) {
			for (const value of page) {
				if (this.stopped) return false;
				if (!isRecord(value)) continue;
				const documentId = value.id;
				if (typeof documentId !== "string") continue;
				const createdAt =
					typeof value.created_at === "number" ? value.created_at : 0;
				lastCreatedAt = Math.max(lastCreatedAt, createdAt);
				const currentSnapshotId =
					typeof value.current_snapshot_id === "string"
						? value.current_snapshot_id
						: null;
				const watermark =
					typeof value.compacted_through === "number"
						? value.compacted_through
						: null;
				try {
					if (currentSnapshotId !== null && watermark !== null) {
						await this.deleteCoveredUpdates(
							documentId,
							watermark,
							updateCutoff,
						);
						await this.deleteOldSnapshots(
							documentId,
							currentSnapshotId,
							snapshotCutoff,
						);
					}
				} catch (error) {
					this.reportError(error, {
						namespace,
						documentId,
						phase: "cleanup",
					});
				}
				processed += 1;
				if (processed >= this.maxCleanupDocumentsPerPass) {
					state.cleanupCursor = lastCreatedAt;
					state.nextCleanupAt = now;
					return true;
				}
			}
			if (page.nextCursor === null) {
				state.cleanupCursor = null;
				state.nextCleanupAt = now + this.cleanupIntervalMs;
				return false;
			}
			state.cleanupCursor = lastCreatedAt;
		}

		state.cleanupCursor = null;
		state.nextCleanupAt = now + this.cleanupIntervalMs;
		return false;
	}

	private async deleteCoveredUpdates(
		documentId: string,
		watermark: number,
		cutoff: number,
	): Promise<void> {
		const limit = Math.min(watermark, cutoff - 1);
		if (limit < 0) return;
		const deleted: Array<{ id: string; createdAt: number }> = [];
		for await (const page of this.pages(
			this.updatesCollection,
			{ document_id: documentId, created_at: { lte: limit } },
			[{ created_at: "asc" }],
		)) {
			for (const value of page) {
				if (!isRecord(value)) continue;
				if (value.document_id !== documentId) continue;
				const id = value.id;
				const createdAt = value.created_at;
				if (typeof id === "string" && typeof createdAt === "number") {
					deleted.push({ id, createdAt });
				}
			}
			if (deleted.length >= DELETE_BATCH_SIZE) {
				await this.deleteRows(
					this.updatesCollection,
					deleted.splice(0, deleted.length),
				);
			}
			if (this.stopped) return;
		}
		await this.deleteRows(this.updatesCollection, deleted);
	}

	private async deleteOldSnapshots(
		documentId: string,
		currentSnapshotId: string,
		cutoff: number,
	): Promise<void> {
		const groups = new Map<string, { max: number; rows: string[] }>();
		for await (const page of this.pages(
			this.snapshotsCollection,
			{ document_id: documentId },
			[{ created_at: "asc" }],
		)) {
			for (const value of page) {
				if (!isRecord(value)) continue;
				if (value.document_id !== documentId) continue;
				const snapshotId = value.snapshot_id;
				if (typeof snapshotId !== "string") continue;
				if (snapshotId === currentSnapshotId) continue;
				const id = value.id;
				if (typeof id !== "string") continue;
				const createdAt =
					typeof value.created_at === "number" ? value.created_at : 0;
				let group = groups.get(snapshotId);
				if (group === undefined) {
					group = { max: createdAt, rows: [] };
					groups.set(snapshotId, group);
				}
				group.max = Math.max(group.max, createdAt);
				group.rows.push(id);
			}
			if (this.stopped) return;
		}
		const ids: string[] = [];
		for (const group of groups.values()) {
			if (group.max < cutoff) ids.push(...group.rows);
		}
		await this.deleteRows(
			this.snapshotsCollection,
			ids.map((id) => ({ id })),
		);
	}

	private async deleteRows(
		collection: string,
		rows: Array<{ id: string }>,
	): Promise<void> {
		for (let index = 0; index < rows.length; index += DELETE_BATCH_SIZE) {
			const slice = rows.slice(index, index + DELETE_BATCH_SIZE);
			if (slice.length === 0) continue;
			const operations: BatchOperation[] = slice.map((row) => ({
				op: "remove",
				path: [collection, row.id],
			}));
			await this.store.batch(operations);
		}
	}

	// ─── Query pager ─────────────────────────────────────────────────────────

	private async *pages(
		collection: string,
		where: QueryOptions["where"],
		orderBy: readonly SortClause[],
	): AsyncGenerator<JsonValue[] & { nextCursor: string | null }> {
		let after: string | undefined;
		let limit = this.pageSize;
		for (;;) {
			if (this.stopped) return;
			let page: JsonValue[] & { nextCursor: string | null };
			try {
				page = (await this.store.query(collection, {
					where,
					orderBy,
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
			yield page;
			after = page.nextCursor ?? undefined;
			if (after === undefined) return;
		}
	}

	// ─── Events ──────────────────────────────────────────────────────────────

	private reportError(error: unknown, context: YjsCompactorErrorContext): void {
		try {
			this.onError(error, context);
		} catch (callbackError) {
			console.error(
				"[ZyncBase Yjs compactor] onError callback threw:",
				callbackError,
			);
		}
	}

	private emitCompacted(event: YjsCompactedEvent): void {
		try {
			this.onCompacted(event);
		} catch (callbackError) {
			console.error(
				"[ZyncBase Yjs compactor] onCompacted callback threw:",
				callbackError,
			);
		}
	}
}
