// Schema Dictionary — Client-side integer routing (ADR-025)
//
// Maintains bidirectional mappings between schema string identifiers
// (collection names, field names) and their dense integer indices.
// Built from the SchemaSync message pushed by the server on connect.

import xxhash from "xxhash-wasm";
import { SchemaError } from "./errors.js";

/**
 * SchemaDictionary provides O(1) bidirectional lookups between
 * schema string identifiers and their positional integer indices.
 *
 * Lifecycle:
 *  1. Server pushes SchemaSync immediately after WebSocket upgrade.
 *  2. SDK calls `processSchemaSync()` to populate the dictionary.
 *  3. All subsequent Store operations encode paths/values through
 *     `encodePath` / `encodeValue` before transmission.
 *  4. All inbound responses/deltas decode through `decodePath` /
 *     `decodeValue` before exposing to user code.
 *  5. On reconnect, the hash of the new SchemaSync is compared to
 *     the previous one; a mismatch triggers a `schemaChange` event.
 */
export class SchemaDictionary {
	// ─── Raw positional arrays (from SchemaSync) ──────────────────────────
	private tables: string[] = [];
	private fields: string[][] = [];

	// ─── Bidirectional maps ────────────────────────────────────────────────
	private tableToIndex = new Map<string, number>();
	private fieldToIndex: Map<number, Map<string, number>> = new Map();

	// ─── Offline safety hash ───────────────────────────────────────────────
	private hash: string | null = null;
	private previousHash: string | null = null;

	// ─── State ─────────────────────────────────────────────────────────────
	private ready = false;

	// ─── Public API ────────────────────────────────────────────────────────

	/** Whether the dictionary has been populated from a SchemaSync message. */
	isReady(): boolean {
		return this.ready;
	}

	/**
	 * Process a SchemaSync payload from the server.
	 * Builds all internal mappings and computes the offline safety hash.
	 * Returns true if the schema has changed since the previous SchemaSync.
	 */
	async processSchemaSync(payload: {
		tables: string[];
		fields: string[][];
	}): Promise<boolean> {
		// Save previous hash for comparison
		this.previousHash = this.hash;

		// Store raw arrays
		this.tables = payload.tables;
		this.fields = payload.fields;

		// Build table index map
		this.tableToIndex.clear();
		for (let i = 0; i < payload.tables.length; i++) {
			this.tableToIndex.set(payload.tables[i], i);
		}

		// Build field index maps (per table)
		this.fieldToIndex.clear();
		for (let ti = 0; ti < payload.fields.length; ti++) {
			const fieldMap = new Map<string, number>();
			for (let fi = 0; fi < payload.fields[ti].length; fi++) {
				fieldMap.set(payload.fields[ti][fi], fi);
			}
			this.fieldToIndex.set(ti, fieldMap);
		}

		// Compute xxHash64 of the canonical payload for offline safety
		this.hash = await this.computeHash(payload);

		this.ready = true;

		// Schema changed if previous hash exists and differs
		return this.previousHash !== null && this.previousHash !== this.hash;
	}

	/** Get the table index for a collection name. Throws if not found. */
	getTableIndex(name: string): number {
		const idx = this.tableToIndex.get(name);
		if (idx === undefined) {
			throw new SchemaError(
				`SchemaDictionary: unknown table "${name}"`,
				"TABLE_NOT_FOUND",
			);
		}
		return idx;
	}

	/** Get the field index for a field name within a table. Throws if not found. */
	getFieldIndex(tableIndex: number, fieldName: string): number {
		const fieldMap = this.fieldToIndex.get(tableIndex);
		if (fieldMap === undefined) {
			throw new SchemaError(
				`SchemaDictionary: unknown table index ${tableIndex}`,
				"TABLE_NOT_FOUND",
			);
		}
		const idx = fieldMap.get(fieldName);
		if (idx === undefined) {
			throw new SchemaError(
				`SchemaDictionary: unknown field "${fieldName}" in table index ${tableIndex}`,
				"FIELD_NOT_FOUND",
			);
		}
		return idx;
	}

	/** Get the table name for a given index. Throws if out of range. */
	getTableName(index: number): string {
		if (index < 0 || index >= this.tables.length) {
			throw new SchemaError(
				`SchemaDictionary: table index ${index} out of range (0..${this.tables.length - 1})`,
				"TABLE_NOT_FOUND",
			);
		}
		return this.tables[index];
	}

	/** Get the field name for a given table and field index. Throws if out of range. */
	getFieldName(tableIndex: number, fieldIndex: number): string {
		if (tableIndex < 0 || tableIndex >= this.fields.length) {
			throw new SchemaError(
				`SchemaDictionary: table index ${tableIndex} out of range`,
				"TABLE_NOT_FOUND",
			);
		}
		const tableFields = this.fields[tableIndex];
		if (fieldIndex < 0 || fieldIndex >= tableFields.length) {
			throw new SchemaError(
				`SchemaDictionary: field index ${fieldIndex} out of range for table index ${tableIndex}`,
				"FIELD_NOT_FOUND",
			);
		}
		return tableFields[fieldIndex];
	}

	/** Get the current schema hash (null if not yet synced). */
	getHash(): string | null {
		return this.hash;
	}

	// ─── Path Encoding / Decoding ──────────────────────────────────────────

	/**
	 * Encode a logical SDK path into a wire-format path with integer indices.
	 *
	 * Examples:
	 *   ["users", "u1"]             → [0, "u1"]
	 *   ["users", "u1", "name"]     → [0, "u1", 2]
	 *   ["users", "u1", "address", "city"] → [0, "u1", 5]
	 *
	 * Segments at index 2+ are joined with "__" (matching the server's
	 * flattened column naming) and then resolved to a field index.
	 */
	encodePath(segments: string[]): (number | string)[] {
		if (segments.length === 0) {
			throw new SchemaError("SchemaDictionary: empty path", "INVALID_PATH");
		}

		const tableIndex = this.getTableIndex(segments[0]);

		if (segments.length === 1) {
			// Collection-only path
			return [tableIndex];
		}

		const docId = segments[1];

		if (segments.length === 2) {
			return [tableIndex, docId];
		}

		// Join segments[2:] with "__" to match flattened field name
		const flatField = segments.slice(2).join("__");
		const fieldIndex = this.getFieldIndex(tableIndex, flatField);

		return [tableIndex, docId, fieldIndex];
	}

	/**
	 * Decode a wire-format path back to a logical SDK path.
	 *
	 * Examples:
	 *   [0, "u1"]     → ["users", "u1"]
	 *   [0, "u1", 2]  → ["users", "u1", "name"]
	 *   [0, "u1", 5]  → ["users", "u1", "address", "city"]  (if field 5 = "address__city")
	 */
	decodePath(wirePath: (number | string)[]): string[] {
		if (wirePath.length === 0) {
			throw new SchemaError(
				"SchemaDictionary: empty wire path",
				"INVALID_PATH",
			);
		}

		const tableIndex = wirePath[0] as number;
		const tableName = this.getTableName(tableIndex);

		if (wirePath.length === 1) {
			return [tableName];
		}

		const docId = wirePath[1] as string;

		if (wirePath.length === 2) {
			return [tableName, docId];
		}

		const fieldIndex = wirePath[2] as number;
		const flatField = this.getFieldName(tableIndex, fieldIndex);

		// Split flattened field name on "__" to restore nested segments
		const fieldSegments = flatField.split("__");

		return [tableName, docId, ...fieldSegments];
	}

	// ─── Value Encoding / Decoding ─────────────────────────────────────────

	/**
	 * Encode a string-keyed value map into an integer-keyed wire map.
	 *
	 * Example:
	 *   { "x": 100, "y": 200 } → { 1: 100, 2: 200 }
	 *
	 * Only top-level keys are translated. Nested objects are not expected
	 * at this stage (they should be flattened before calling this method).
	 */
	encodeValue(
		tableIndex: number,
		value: Record<string, unknown>,
	): Record<number, unknown> {
		const result: Record<number, unknown> = {};
		for (const [key, val] of Object.entries(value)) {
			const fieldIndex = this.getFieldIndex(tableIndex, key);
			result[fieldIndex] = val;
		}
		return result;
	}

	/**
	 * Decode an integer-keyed wire map into a string-keyed value map.
	 *
	 * Example:
	 *   { 1: 100, 2: 200 } → { "x": 100, "y": 200 }
	 */
	decodeValue(
		tableIndex: number,
		wireValue: Record<number, unknown>,
	): Record<string, unknown> {
		const result: Record<string, unknown> = {};
		for (const [key, val] of Object.entries(wireValue)) {
			const fieldIndex = Number(key);
			const fieldName = this.getFieldName(tableIndex, fieldIndex);
			result[fieldName] = val;
		}
		return result;
	}

	// ─── Private helpers ───────────────────────────────────────────────────
	private static xxhashPromise: ReturnType<typeof xxhash> | null = null;

	/**
	 * Compute an xxHash64 of the canonical JSON representation of
	 * the tables + fields arrays. Used for offline safety detection.
	 */
	private async computeHash(payload: {
		tables: string[];
		fields: string[][];
	}): Promise<string> {
		if (!SchemaDictionary.xxhashPromise) {
			SchemaDictionary.xxhashPromise = xxhash();
		}
		const hasher = await SchemaDictionary.xxhashPromise;
		const canonical = JSON.stringify({
			tables: payload.tables,
			fields: payload.fields,
		});
		return hasher.h64ToString(canonical).padStart(16, "0");
	}
}
