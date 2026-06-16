// Schema Dictionary — Client-side integer routing (ADR-025)
//
// Maintains bidirectional mappings between schema string identifiers
// (collection names, field names) and their dense integer indices.
// Built from the SchemaSync message pushed by the server on connect.

import xxhash from "xxhash-wasm";
import { packDocId, unpackDocId } from "./doc_id.js";
import { ErrorCodes, SchemaError } from "./errors.js";
import { flatten, joinFieldPath, splitFieldPath, unflatten } from "./path.js";
import type { JsonValue } from "./types.js";

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
	private fieldFlags: number[][] = [];

	// ─── Presence field arrays (from SchemaSync) ──────────────────────────
	private presenceUserFields: string[] = [];
	private presenceSharedFields: string[] = [];

	// ─── Bidirectional maps ────────────────────────────────────────────────
	private tableToIndex = new Map<string, number>();
	private fieldToIndex: Map<number, Map<string, number>> = new Map();

	// ─── Presence bidirectional maps ───────────────────────────────────────
	private presenceUserFieldToIndex = new Map<string, number>();
	private presenceSharedFieldToIndex = new Map<string, number>();

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
		fieldFlags: number[][];
		presenceUserFields?: string[];
		presenceSharedFields?: string[];
	}): Promise<boolean> {
		this.previousHash = this.hash;
		this.validateSchemaSyncPayload(payload);
		this.buildStoreMaps(payload);
		this.buildPresenceMaps(payload);
		this.hash = await this.computeHash(payload);
		this.ready = true;
		return this.previousHash !== null && this.previousHash !== this.hash;
	}

	private validateSchemaSyncPayload(payload: {
		fields: string[][];
		fieldFlags: number[][];
	}): void {
		if (!Array.isArray(payload.fieldFlags)) {
			throw new Error("SchemaDictionary: SchemaSync missing fieldFlags");
		}
		if (payload.fieldFlags.length !== payload.fields.length) {
			throw new Error(
				"SchemaDictionary: SchemaSync fieldFlags table count mismatch",
			);
		}
		for (let ti = 0; ti < payload.fields.length; ti++) {
			if (payload.fieldFlags[ti]?.length !== payload.fields[ti]?.length) {
				throw new Error(
					`SchemaDictionary: SchemaSync fieldFlags length mismatch for table index ${ti}`,
				);
			}
		}
	}

	private buildStoreMaps(payload: {
		tables: string[];
		fields: string[][];
		fieldFlags: number[][];
	}): void {
		this.tables = payload.tables;
		this.fields = payload.fields;
		this.fieldFlags = payload.fieldFlags;

		this.tableToIndex.clear();
		for (let i = 0; i < payload.tables.length; i++) {
			this.tableToIndex.set(payload.tables[i], i);
		}

		this.fieldToIndex.clear();
		for (let ti = 0; ti < payload.fields.length; ti++) {
			const fieldMap = new Map<string, number>();
			for (let fi = 0; fi < payload.fields[ti].length; fi++) {
				fieldMap.set(payload.fields[ti][fi], fi);
			}
			this.fieldToIndex.set(ti, fieldMap);
		}
	}

	private buildPresenceMaps(payload: {
		presenceUserFields?: string[];
		presenceSharedFields?: string[];
	}): void {
		this.presenceUserFields = payload.presenceUserFields ?? [];
		this.presenceSharedFields = payload.presenceSharedFields ?? [];

		this.presenceUserFieldToIndex.clear();
		for (let i = 0; i < this.presenceUserFields.length; i++) {
			this.presenceUserFieldToIndex.set(this.presenceUserFields[i], i);
		}

		this.presenceSharedFieldToIndex.clear();
		for (let i = 0; i < this.presenceSharedFields.length; i++) {
			this.presenceSharedFieldToIndex.set(this.presenceSharedFields[i], i);
		}
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
	encodePath(segments: string[]): (number | Uint8Array)[] {
		if (segments.length === 0) {
			throw new SchemaError("SchemaDictionary: empty path", "INVALID_PATH");
		}

		const tableIndex = this.getTableIndex(segments[0]);

		if (segments.length === 1) {
			// Collection-only path
			return [tableIndex];
		}

		const docId = packDocId(segments[1], ErrorCodes.INVALID_PATH);

		if (segments.length === 2) {
			return [tableIndex, docId];
		}

		// Join segments[2:] with "__" to match flattened field name
		const flatField = joinFieldPath(...segments.slice(2));
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
	decodePath(wirePath: (number | string | Uint8Array)[]): string[] {
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

		const rawDocId = wirePath[1];
		const docId =
			rawDocId instanceof Uint8Array ? unpackDocId(rawDocId) : String(rawDocId);

		if (wirePath.length === 2) {
			return [tableName, docId];
		}

		const fieldIndex = wirePath[2] as number;
		const flatField = this.getFieldName(tableIndex, fieldIndex);

		// Split flattened field name on "__" to restore nested segments
		const fieldSegments = splitFieldPath(flatField);

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
			result[fieldIndex] = this.encodeFieldValue(tableIndex, fieldIndex, val);
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
			result[fieldName] = this.decodeFieldValue(tableIndex, fieldIndex, val);
		}
		return result;
	}

	encodeFieldValue(
		tableIndex: number,
		fieldIndex: number,
		value: unknown,
	): unknown {
		if (!this.isDocIdField(tableIndex, fieldIndex)) {
			return value;
		}

		if (typeof value === "string") {
			return packDocId(value, ErrorCodes.INVALID_MESSAGE);
		}
		if (Array.isArray(value)) {
			return value.map((item) =>
				typeof item === "string"
					? packDocId(item, ErrorCodes.INVALID_MESSAGE)
					: item,
			);
		}
		return value;
	}

	decodeFieldValue(
		tableIndex: number,
		fieldIndex: number,
		value: unknown,
	): unknown {
		if (!this.isDocIdField(tableIndex, fieldIndex)) {
			return value;
		}
		if (value instanceof Uint8Array) {
			return unpackDocId(value);
		}
		if (Array.isArray(value)) {
			return value.map((item) =>
				item instanceof Uint8Array ? unpackDocId(item) : item,
			);
		}
		return value;
	}

	isDocIdField(tableIndex: number, fieldIndex: number): boolean {
		return (this.getFieldFlags(tableIndex, fieldIndex) & 0b10) !== 0;
	}

	// ─── Presence Encoding / Decoding ─────────────────────────────────────

	/**
	 * Encode a nested presence data object into an integer-keyed wire map for user presence.
	 * Flattens nested objects (e.g., { cursor: { x: 1, y: 2 } } → { "cursor__x": 1, "cursor__y": 2 })
	 * then maps field names to their integer indices.
	 */
	encodePresenceUserValue(
		data: Record<string, JsonValue>,
	): Record<number, unknown> {
		const flat = flatten(data);
		const result: Record<number, unknown> = {};
		for (const [key, value] of Object.entries(flat)) {
			const index = this.presenceUserFieldToIndex.get(key);
			if (index === undefined) {
				throw new SchemaError(
					`SchemaDictionary: unknown presence user field "${key}"`,
					"FIELD_NOT_FOUND",
				);
			}
			result[index] = value;
		}
		return result;
	}

	/**
	 * Encode a nested presence data object into an integer-keyed wire map for shared state.
	 */
	encodePresenceSharedValue(
		data: Record<string, JsonValue>,
	): Record<number, unknown> {
		const flat = flatten(data);
		const result: Record<number, unknown> = {};
		for (const [key, value] of Object.entries(flat)) {
			const index = this.presenceSharedFieldToIndex.get(key);
			if (index === undefined) {
				throw new SchemaError(
					`SchemaDictionary: unknown presence shared field "${key}"`,
					"FIELD_NOT_FOUND",
				);
			}
			result[index] = value;
		}
		return result;
	}

	/**
	 * Decode an integer-keyed wire map into a nested string-keyed object for user presence.
	 */
	decodePresenceUserValue(
		wireData: Record<number, unknown>,
	): Record<string, JsonValue> {
		const flat: Record<string, JsonValue> = {};
		for (const [key, value] of Object.entries(wireData)) {
			const index = Number(key);
			const fieldName = this.presenceUserFields[index];
			if (fieldName === undefined) {
				throw new SchemaError(
					`SchemaDictionary: unknown presence user field index ${index}`,
					"FIELD_NOT_FOUND",
				);
			}
			flat[fieldName] = value as JsonValue;
		}
		return unflatten(flat);
	}

	/**
	 * Decode an integer-keyed wire map into a nested string-keyed object for shared state.
	 */
	decodePresenceSharedValue(
		wireData: Record<number, unknown>,
	): Record<string, JsonValue> {
		const flat: Record<string, JsonValue> = {};
		for (const [key, value] of Object.entries(wireData)) {
			const index = Number(key);
			const fieldName = this.presenceSharedFields[index];
			if (fieldName === undefined) {
				throw new SchemaError(
					`SchemaDictionary: unknown presence shared field index ${index}`,
					"FIELD_NOT_FOUND",
				);
			}
			flat[fieldName] = value as JsonValue;
		}
		return unflatten(flat);
	}

	/**
	 * Decode a bin16 userId (Uint8Array) to a UUID string.
	 */
	decodePresenceUserId(bin: Uint8Array): string {
		if (bin.length !== 16) {
			throw new Error(
				`SchemaDictionary: invalid userId binary length ${bin.length}`,
			);
		}
		const hexChars = "0123456789abcdef";
		const uuid = new Array(36);
		for (let i = 0, j = 0; i < 16; i++) {
			const b = bin[i];
			uuid[j++] = hexChars[b >> 4];
			uuid[j++] = hexChars[b & 0x0f];
			if (i === 3 || i === 5 || i === 7 || i === 9) {
				uuid[j++] = "-";
			}
		}
		return uuid.join("");
	}

	/**
	 * Check if presence user fields are defined.
	 */
	hasPresenceUserFields(): boolean {
		return this.presenceUserFields.length > 0;
	}

	/**
	 * Check if presence shared fields are defined.
	 */
	hasPresenceSharedFields(): boolean {
		return this.presenceSharedFields.length > 0;
	}

	// ─── Private helpers ───────────────────────────────────────────────────
	private static xxhashPromise: ReturnType<typeof xxhash> | null = null;

	private getFieldFlags(tableIndex: number, fieldIndex: number): number {
		if (tableIndex < 0 || tableIndex >= this.fields.length) {
			throw new SchemaError(
				`SchemaDictionary: table index ${tableIndex} out of range`,
				"TABLE_NOT_FOUND",
			);
		}
		const flagsForTable = this.fieldFlags[tableIndex];
		if (
			!flagsForTable ||
			fieldIndex < 0 ||
			fieldIndex >= flagsForTable.length
		) {
			throw new SchemaError(
				`SchemaDictionary: field index ${fieldIndex} out of range for table index ${tableIndex}`,
				"FIELD_NOT_FOUND",
			);
		}
		return flagsForTable[fieldIndex];
	}

	/**
	 * Compute an xxHash64 of the canonical JSON representation of
	 * the tables + fields arrays. Used for offline safety detection.
	 */
	private async computeHash(payload: {
		tables: string[];
		fields: string[][];
		fieldFlags: number[][];
	}): Promise<string> {
		if (!SchemaDictionary.xxhashPromise) {
			SchemaDictionary.xxhashPromise = xxhash();
		}
		const hasher = await SchemaDictionary.xxhashPromise;
		const canonical = JSON.stringify({
			tables: payload.tables,
			fields: payload.fields,
			fieldFlags: payload.fieldFlags,
		});
		return hasher.h64ToString(canonical).padStart(16, "0");
	}
}

/**
 * Flatten a nested presence data object using "__" as the key separator.
 * Only flattens one level deep (presence schema allows max 1 level of nesting).
 *
 * Example:
 *   { cursor: { x: 1, y: 2 }, status: "active" } → { "cursor__x": 1, "cursor__y": 2, "status": "active" }
 */
