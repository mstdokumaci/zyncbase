/** Collection names, schema fragment, and chunk helpers for the Yjs provider. */

export const YJS_DOCUMENTS_COLLECTION = "yjs_documents";
export const YJS_SNAPSHOTS_COLLECTION = "yjs_snapshots";
export const YJS_UPDATES_COLLECTION = "yjs_updates";

/**
 * Store definitions for a first-class Yjs document:
 * - `yjs_documents`: one header row per document; app metadata lives here.
 * - `yjs_snapshots`: chunked compacted state, owned by the compactor.
 * - `yjs_updates`: chunked append-only updates, written by providers.
 *
 * Merge into the `store` object of a ZyncBase schema. If collections are
 * renamed, update the keys and the provider's `collections` option together.
 */
export const yjsStoreSchema = {
	yjs_documents: {
		required: ["compaction_version"],
		unique: [["slug"]],
		fields: {
			slug: { type: "string", minLength: 1, maxLength: 120 },
			current_snapshot_id: { type: "string", minLength: 1, maxLength: 64 },
			compacted_through: { type: "integer", minimum: 0 },
			compaction_version: { type: "integer", minimum: 0 },
		},
	},
	yjs_snapshots: {
		required: [
			"document_id",
			"snapshot_id",
			"compaction_version",
			"part",
			"parts",
		],
		unique: [["snapshot_id", "part"]],
		fields: {
			document_id: {
				type: "string",
				references: "yjs_documents",
				onDelete: "cascade",
				indexed: true,
			},
			snapshot_id: { type: "string", minLength: 1, maxLength: 64 },
			compaction_version: { type: "integer", minimum: 0 },
			part: { type: "integer", minimum: 0 },
			parts: { type: "integer", minimum: 1 },
			committed: { type: "boolean" },
			data: { type: "bytes" },
		},
	},
	yjs_updates: {
		required: ["document_id", "update_id", "part", "parts"],
		unique: [["update_id", "part"]],
		fields: {
			document_id: {
				type: "string",
				references: "yjs_documents",
				onDelete: "cascade",
				indexed: true,
			},
			update_id: { type: "string", minLength: 1, maxLength: 64 },
			part: { type: "integer", minimum: 0 },
			parts: { type: "integer", minimum: 1 },
			committed: { type: "boolean" },
			data: { type: "bytes" },
		},
	},
} as const;

/** A `yjs_documents` row as read by the provider. */
export interface YjsDocumentRow {
	id: string;
	slug?: string | null;
	current_snapshot_id?: string | null;
	compacted_through?: number | null;
	compaction_version?: number | null;
	created_at?: number;
	updated_at?: number;
}

/** One chunk of a logical payload. */
export interface ChunkPayloadRow {
	id: string;
	payloadId: string;
	part: number;
	parts: number;
	data?: Uint8Array | null;
	/** Required on commit rows; a payload is sealed only when this is true. */
	committed?: boolean;
}

/** A fully assembled payload. */
export interface AssembledPayload {
	payloadId: string;
	bytes: Uint8Array;
}

/**
 * Returns an explicit commit flag. Absence is not a default: it means the row
 * does not seal the payload.
 */
export function parseCommitted(value: unknown): boolean | undefined {
	return value === true ? true : value === false ? false : undefined;
}

interface PendingPayload {
	parts: number;
	chunks: Map<number, Uint8Array>;
	committed: boolean;
}

/** Keep buffered partial payloads bounded even if a writer never commits. */
const MAX_PENDING_PAYLOADS = 512;

/** Split bytes into one or more parts of at most `chunkSize` bytes. */
export function chunkPayload(
	bytes: Uint8Array,
	chunkSize: number,
): Uint8Array[] {
	if (!Number.isInteger(chunkSize) || chunkSize < 1) {
		throw new RangeError("chunkSize must be a positive integer");
	}
	if (bytes.length === 0) return [];
	const parts: Uint8Array[] = [];
	for (let offset = 0; offset < bytes.length; offset += chunkSize) {
		parts.push(bytes.slice(offset, offset + chunkSize));
	}
	return parts;
}

/**
 * Reassembles chunked payloads delivered in any order. A payload with one part
 * is complete immediately; larger payloads need every part plus a commit row
 * (`part === parts`) with `committed === true`.
 */
export class ChunkAssembler {
	private readonly pending = new Map<string, PendingPayload>();

	/** Returns the assembled bytes when this row completes a payload. */
	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: chunk validation is a linear parser with explicit guards.
	add(row: ChunkPayloadRow): AssembledPayload | null {
		if (!Number.isInteger(row.parts) || row.parts < 1) return null;
		if (!Number.isInteger(row.part) || row.part < 0 || row.part > row.parts) {
			return null;
		}
		const isCommit = row.part === row.parts;
		if (row.parts === 1 && isCommit) return null;
		if (!isCommit && !(row.data instanceof Uint8Array)) return null;

		let payload = this.pending.get(row.payloadId);
		if (payload === undefined) {
			if (this.pending.size >= MAX_PENDING_PAYLOADS) {
				const oldest = this.pending.keys().next().value;
				if (oldest !== undefined) this.pending.delete(oldest);
			}
			payload = { parts: row.parts, chunks: new Map(), committed: false };
			this.pending.set(row.payloadId, payload);
		}
		if (payload.parts !== row.parts) return null;

		if (isCommit) {
			if (row.committed !== true) return null;
			payload.committed = true;
		} else {
			payload.chunks.set(row.part, row.data as Uint8Array);
		}

		if (row.parts > 1 && !payload.committed) return null;
		for (let index = 0; index < payload.parts; index += 1) {
			if (!payload.chunks.has(index)) return null;
		}

		let length = 0;
		for (let index = 0; index < payload.parts; index += 1) {
			length += payload.chunks.get(index)?.length ?? 0;
		}
		const bytes = new Uint8Array(length);
		let offset = 0;
		for (let index = 0; index < payload.parts; index += 1) {
			const chunk = payload.chunks.get(index);
			if (chunk === undefined) return null;
			bytes.set(chunk, offset);
			offset += chunk.length;
		}
		this.pending.delete(row.payloadId);
		return { payloadId: row.payloadId, bytes };
	}

	reset(): void {
		this.pending.clear();
	}

	get size(): number {
		return this.pending.size;
	}
}
