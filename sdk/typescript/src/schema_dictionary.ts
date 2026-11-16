// Schema Dictionary — Client-side integer routing (ADR-009)
//
// Maintains bidirectional mappings between schema string identifiers
// (collection names, field names) and their dense integer indices.
// Built from the SchemaSync message pushed by the server on connect.

import hash from "string-hash-64";
import { packDocId, unpackDocId } from "./doc_id.js";
import { ErrorCodes, SchemaError } from "./errors.js";
import {
	fieldPathToFlat,
	flatten,
	setDeepProperty,
	splitFieldPath,
} from "./path.js";
import type { JsonValue, SparseFieldArray } from "./types.js";

/** Guards flat sparse field arrays: the wire format requires an even element count. */
function assertSparseLength(wireData: SparseFieldArray, label: string): void {
	if (wireData.length % 2 !== 0) {
		throw new SchemaError(
			`SchemaDictionary: odd-length sparse field array for ${label} (${wireData.length})`,
			"INVALID_MESSAGE_FORMAT",
		);
	}
}

/** Dense per-action dictionary entry built from SchemaSync. */
export interface ActionSchemaEntry {
	id: number;
	name: string;
	scope: "store" | "presence";
	hasReturns: boolean;
	params: string[];
	returns: string[];
	paramFieldToIndex: Map<string, number>;
	returnFieldToIndex: Map<string, number>;
	paramPaths: Array<string[] | undefined>;
	returnPaths: Array<string[] | undefined>;
}

function buildActionEntry(
	name: string,
	id: number,
	params: string[],
	returns: string[],
	flags: number,
): ActionSchemaEntry {
	return {
		id,
		name,
		scope: (flags & 0b10) !== 0 ? "presence" : "store",
		hasReturns: (flags & 0b01) !== 0,
		params,
		returns,
		paramFieldToIndex: buildFieldIndexMap(params),
		returnFieldToIndex: buildFieldIndexMap(returns),
		paramPaths: buildFieldPaths(params),
		returnPaths: buildFieldPaths(returns),
	};
}

function buildFieldIndexMap(fields: string[]): Map<string, number> {
	const map = new Map<string, number>();
	for (let i = 0; i < fields.length; i++) {
		map.set(fields[i], i);
	}
	return map;
}

function buildFieldPaths(fields: string[]): Array<string[] | undefined> {
	return fields.map((field) =>
		field.includes("__") ? splitFieldPath(field) : undefined,
	);
}

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
 *     `decodeRecord` before exposing to user code.
 *  5. On reconnect, the hash of the new SchemaSync is compared to
 *     the previous one; a mismatch triggers a `schemaChange` event.
 */
export class SchemaDictionary {
	// ─── Raw positional arrays (from SchemaSync) ──────────────────────────
	private tables: string[] = [];
	private fields: string[][] = [];
	private fieldFlags: number[][] = [];
	private fieldPaths: Array<Array<string[] | undefined>> = [];

	// ─── Presence field arrays (from SchemaSync) ──────────────────────────
	private presenceUserFields: string[] = [];
	private presenceSharedFields: string[] = [];
	private presenceUserFieldPaths: Array<string[] | undefined> = [];
	private presenceSharedFieldPaths: Array<string[] | undefined> = [];

	// ─── Bidirectional maps ────────────────────────────────────────────────
	private tableToIndex = new Map<string, number>();
	private fieldToIndex: Map<number, Map<string, number>> = new Map();

	// ─── Presence bidirectional maps ───────────────────────────────────────
	private presenceUserFieldToIndex = new Map<string, number>();
	private presenceSharedFieldToIndex = new Map<string, number>();

	// ─── Action arrays (from SchemaSync) ───────────────────────────────────
	private actionNames: string[] = [];
	private actionParams: string[][] = [];
	private actionReturns: string[][] = [];
	private actionFlags: number[] = [];

	// ─── Action bidirectional maps ─────────────────────────────────────────
	private actionToIndex = new Map<string, number>();
	private actionsByIndex: ActionSchemaEntry[] = [];

	// ─── Offline safety hash ───────────────────────────────────────────────
	private hash: number | null = null;
	private previousHash: number | null = null;

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
		actions?: string[];
		actionParams?: string[][];
		actionReturns?: string[][];
		actionFlags?: number[];
	}): Promise<boolean> {
		this.previousHash = this.hash;
		this.validateSchemaSyncPayload(payload);
		this.validateActionArrays(payload);
		this.buildStoreMaps(payload);
		this.buildPresenceMaps(payload);
		this.buildActionMaps(payload);
		this.hash = this.computeHash(payload);
		this.ready = true;
		return this.previousHash !== null && this.previousHash !== this.hash;
	}

	private validateActionArrays(payload: {
		actions?: string[];
		actionParams?: string[][];
		actionReturns?: string[][];
		actionFlags?: number[];
	}): void {
		const names = payload.actions ?? [];
		const params = payload.actionParams ?? [];
		const returns = payload.actionReturns ?? [];
		const flags = payload.actionFlags ?? [];
		if (
			params.length !== names.length ||
			returns.length !== names.length ||
			flags.length !== names.length
		) {
			throw new Error(
				"SchemaDictionary: SchemaSync action dictionary length mismatch",
			);
		}
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
		this.fieldPaths = payload.fields.map((fields) =>
			fields.map((field) =>
				field.includes("__") ? splitFieldPath(field) : undefined,
			),
		);

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
		this.presenceUserFieldPaths = this.presenceUserFields.map((field) =>
			field.includes("__") ? splitFieldPath(field) : undefined,
		);
		this.presenceSharedFieldPaths = this.presenceSharedFields.map((field) =>
			field.includes("__") ? splitFieldPath(field) : undefined,
		);

		this.presenceUserFieldToIndex.clear();
		for (let i = 0; i < this.presenceUserFields.length; i++) {
			this.presenceUserFieldToIndex.set(this.presenceUserFields[i], i);
		}

		this.presenceSharedFieldToIndex.clear();
		for (let i = 0; i < this.presenceSharedFields.length; i++) {
			this.presenceSharedFieldToIndex.set(this.presenceSharedFields[i], i);
		}
	}

	private buildActionMaps(payload: {
		actions?: string[];
		actionParams?: string[][];
		actionReturns?: string[][];
		actionFlags?: number[];
	}): void {
		this.actionNames = payload.actions ?? [];
		this.actionParams = payload.actionParams ?? [];
		this.actionReturns = payload.actionReturns ?? [];
		this.actionFlags = payload.actionFlags ?? [];

		this.actionToIndex.clear();
		for (let i = 0; i < this.actionNames.length; i++) {
			this.actionToIndex.set(this.actionNames[i], i);
		}

		this.actionsByIndex = this.actionNames.map((name, index) =>
			buildActionEntry(
				name,
				index,
				this.actionParams[index] ?? [],
				this.actionReturns[index] ?? [],
				this.actionFlags[index] ?? 0,
			),
		);
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
				`SchemaDictionary: table index ${index} out of range`,
				"TABLE_NOT_FOUND",
			);
		}
		return this.tables[index];
	}

	/** Get the field name for a given table and field index. Throws if out of range. */
	getFieldName(tableIndex: number, fieldIndex: number): string {
		if (tableIndex < 0 || tableIndex >= this.tables.length) {
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

	// ─── Path Encoding / Decoding ──────────────────────────────────────────

	/**
	 * Encode a logical SDK path into a wire-format path with integer indices.
	 *
	 * Examples:
	 *   ["users", "u1"]                    → [0, "u1"]
	 *   ["users", "u1", "name"]            → [0, "u1", 2]
	 *   ["users", "u1", "address.city"]    → [0, "u1", 5]
	 *
	 * The third segment is a logical dotted field path. It is flattened with
	 * "__" (matching the server's column naming) and resolved to a field index.
	 */
	encodePath(segments: string[]): (number | Uint8Array)[] {
		if (segments.length === 0) {
			throw new SchemaError("SchemaDictionary: empty path", "INVALID_PATH");
		}
		if (segments.length > 3) {
			throw new SchemaError(
				"SchemaDictionary: path arrays support at most 3 segments",
				"INVALID_PATH",
			);
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

		const flatField = fieldPathToFlat(segments[2]);
		const fieldIndex = this.getFieldIndex(tableIndex, flatField);

		return [tableIndex, docId, fieldIndex];
	}

	/**
	 * Decode a wire-format path back to a logical SDK path.
	 *
	 * Examples:
	 *   [0, "u1"]     → ["users", "u1"]
	 *   [0, "u1", 2]  → ["users", "u1", "name"]
	 *   [0, "u1", 5]  → ["users", "u1", "address.city"]  (if field 5 = "address__city")
	 */
	decodePath(wirePath: (number | string | Uint8Array)[]): string[] {
		if (wirePath.length === 0) {
			throw new SchemaError(
				"SchemaDictionary: empty wire path",
				"INVALID_PATH",
			);
		}
		if (wirePath.length > 3) {
			throw new SchemaError(
				"SchemaDictionary: wire path has more than 3 segments",
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

		// Restore the logical dotted field path from the flat "__" form.
		return [tableName, docId, splitFieldPath(flatField).join(".")];
	}

	// ─── Value Encoding / Decoding ─────────────────────────────────────────

	/**
	 * Encode a flat string-keyed value map into an integer-keyed sparse array.
	 *
	 * Example:
	 *   { "x": 100, "y": 200 } → [1, 100, 2, 200]
	 *
	 * Keys are already flattened to the schema's "__" form. A null key that
	 * names an object namespace (for example "address" when the schema has
	 * "address__city" and "address__zip") clears every leaf beneath it. An
	 * explicit leaf always wins over a namespace clear, regardless of key
	 * order.
	 */
	encodeValue(
		tableIndex: number,
		value: Record<string, unknown>,
	): SparseFieldArray {
		const fieldMap = this.fieldToIndex.get(tableIndex);
		if (fieldMap === undefined) {
			throw new SchemaError(
				`SchemaDictionary: unknown table index ${tableIndex}`,
				"TABLE_NOT_FOUND",
			);
		}

		const entries = Object.entries(value);

		// Fast path: no namespace clear, so preserve insertion order and avoid
		// the Map/sort allocation on ordinary writes.
		const needsExpansion = entries.some(
			([key, val]) => val === null && !fieldMap.has(key),
		);
		if (!needsExpansion) {
			const result: SparseFieldArray = [];
			for (const [key, val] of entries) {
				const fieldIndex = fieldMap.get(key);
				if (fieldIndex === undefined) {
					throw this.unknownFieldError(tableIndex, key);
				}
				result.push(
					fieldIndex,
					this.encodeFieldValue(tableIndex, fieldIndex, val),
				);
			}
			return result;
		}

		const encoded = new Map<number, unknown>();
		this.expandNullNamespaces(tableIndex, value, fieldMap, encoded);
		this.applyDirectFields(tableIndex, value, fieldMap, encoded);
		return this.toSparseArray(encoded);
	}

	/** Expands a null namespace key to every leaf beneath it. */
	private expandNullNamespaces(
		tableIndex: number,
		value: Record<string, unknown>,
		fieldMap: Map<string, number>,
		encoded: Map<number, unknown>,
	): void {
		for (const [key, val] of Object.entries(value)) {
			if (fieldMap.has(key) || val !== null) continue;
			const prefix = `${key}__`;
			let matched = false;
			for (const [name, index] of fieldMap) {
				if (!name.startsWith(prefix)) continue;
				encoded.set(index, null);
				matched = true;
			}
			if (!matched) throw this.unknownFieldError(tableIndex, key);
		}
	}

	/** Applies direct leaf keys after namespace clears so they always win. */
	private applyDirectFields(
		tableIndex: number,
		value: Record<string, unknown>,
		fieldMap: Map<string, number>,
		encoded: Map<number, unknown>,
	): void {
		for (const [key, val] of Object.entries(value)) {
			const fieldIndex = fieldMap.get(key);
			if (fieldIndex === undefined) {
				if (val === null) continue;
				throw this.unknownFieldError(tableIndex, key);
			}
			encoded.set(
				fieldIndex,
				this.encodeFieldValue(tableIndex, fieldIndex, val),
			);
		}
	}

	private unknownFieldError(tableIndex: number, key: string): SchemaError {
		return new SchemaError(
			`SchemaDictionary: unknown field "${key}" in table index ${tableIndex}`,
			"FIELD_NOT_FOUND",
		);
	}

	private toSparseArray(encoded: Map<number, unknown>): SparseFieldArray {
		const result: SparseFieldArray = [];
		for (const [index, val] of [...encoded.entries()].sort(
			([a], [b]) => a - b,
		)) {
			result.push(index, val);
		}
		return result;
	}

	/** Decode a complete positional record into its final nested SDK shape. */
	decodeRecord(
		tableIndex: number,
		wireRecord: readonly unknown[],
	): Record<string, JsonValue> {
		const fields = this.getFields(tableIndex);
		if (wireRecord.length !== fields.length) {
			throw new Error(
				`SchemaDictionary: record field count ${wireRecord.length} does not match schema field count ${fields.length} for table index ${tableIndex}`,
			);
		}

		const result: Record<string, JsonValue> = {};
		const fieldFlags = this.fieldFlags[tableIndex];
		const fieldPaths = this.fieldPaths[tableIndex];
		for (let fieldIndex = 0; fieldIndex < wireRecord.length; fieldIndex++) {
			const fieldName = fields[fieldIndex];
			const value = this.decodeFieldValueWithFlags(
				fieldFlags[fieldIndex],
				wireRecord[fieldIndex],
			) as JsonValue;
			const fieldPath = fieldPaths[fieldIndex];
			if (fieldPath !== undefined) {
				setDeepProperty(result, fieldPath, value);
			} else {
				result[fieldName] = value;
			}
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
		return this.decodeFieldValueWithFlags(
			this.getFieldFlags(tableIndex, fieldIndex),
			value,
		);
	}

	private decodeFieldValueWithFlags(flags: number, value: unknown): unknown {
		if ((flags & 0b10) === 0) {
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

	isBytesField(tableIndex: number, fieldIndex: number): boolean {
		return (this.getFieldFlags(tableIndex, fieldIndex) & 0b1000) !== 0;
	}

	isRequiredField(tableIndex: number, fieldIndex: number): boolean {
		return (this.getFieldFlags(tableIndex, fieldIndex) & 0b100) !== 0;
	}

	isSystemField(tableIndex: number, fieldIndex: number): boolean {
		return (this.getFieldFlags(tableIndex, fieldIndex) & 0b01) !== 0;
	}

	getFields(tableIndex: number): string[] {
		if (tableIndex < 0 || tableIndex >= this.tables.length) {
			throw new SchemaError(
				`SchemaDictionary: table index ${tableIndex} out of range`,
				"TABLE_NOT_FOUND",
			);
		}
		return this.fields[tableIndex];
	}

	// ─── Presence Encoding / Decoding ─────────────────────────────────────

	/**
	 * Encode a nested presence data object into a flat sparse field array for user presence.
	 * Flattens nested objects (e.g., { cursor: { x: 1, y: 2 } } → { "cursor__x": 1, "cursor__y": 2 })
	 * then maps field names to their integer indices.
	 */
	encodePresenceUserValue(data: Record<string, JsonValue>): SparseFieldArray {
		const flat = flatten(data);
		const result: SparseFieldArray = [];
		for (const [key, value] of Object.entries(flat)) {
			const index = this.presenceUserFieldToIndex.get(key);
			if (index === undefined) {
				throw new SchemaError(
					`SchemaDictionary: unknown presence user field "${key}"`,
					"FIELD_NOT_FOUND",
				);
			}
			result.push(index, value);
		}
		return result;
	}

	/**
	 * Encode a nested presence data object into a flat sparse field array for shared state.
	 */
	encodePresenceSharedValue(data: Record<string, JsonValue>): SparseFieldArray {
		const flat = flatten(data);
		const result: SparseFieldArray = [];
		for (const [key, value] of Object.entries(flat)) {
			const index = this.presenceSharedFieldToIndex.get(key);
			if (index === undefined) {
				throw new SchemaError(
					`SchemaDictionary: unknown presence shared field "${key}"`,
					"FIELD_NOT_FOUND",
				);
			}
			result.push(index, value);
		}
		return result;
	}

	/**
	 * Decode a flat sparse field array into a nested string-keyed object for user presence.
	 */
	decodePresenceUserValue(
		wireData: SparseFieldArray,
	): Record<string, JsonValue> {
		assertSparseLength(wireData, "presence user data");
		const result: Record<string, JsonValue> = {};
		for (let i = 0; i < wireData.length; i += 2) {
			const index = wireData[i] as number;
			const fieldName = this.presenceUserFields[index];
			if (fieldName === undefined) {
				throw new SchemaError(
					`SchemaDictionary: unknown presence user field index ${index}`,
					"FIELD_NOT_FOUND",
				);
			}
			const value = wireData[i + 1] as JsonValue;
			const fieldPath = this.presenceUserFieldPaths[index];
			if (fieldPath) setDeepProperty(result, fieldPath, value);
			else result[fieldName] = value;
		}
		return result;
	}

	/**
	 * Decode a flat sparse field array into a nested string-keyed object for shared state.
	 */
	decodePresenceSharedValue(
		wireData: SparseFieldArray,
	): Record<string, JsonValue> {
		assertSparseLength(wireData, "presence shared data");
		const result: Record<string, JsonValue> = {};
		for (let i = 0; i < wireData.length; i += 2) {
			const index = wireData[i] as number;
			const fieldName = this.presenceSharedFields[index];
			if (fieldName === undefined) {
				throw new SchemaError(
					`SchemaDictionary: unknown presence shared field index ${index}`,
					"FIELD_NOT_FOUND",
				);
			}
			const value = wireData[i + 1] as JsonValue;
			const fieldPath = this.presenceSharedFieldPaths[index];
			if (fieldPath) setDeepProperty(result, fieldPath, value);
			else result[fieldName] = value;
		}
		return result;
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
		return unpackDocId(bin);
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

	// ─── Action Encoding / Decoding ───────────────────────────────────────

	/** Get the dictionary entry for an action name. Throws if not found. */
	getAction(name: string): ActionSchemaEntry {
		const idx = this.actionToIndex.get(name);
		if (idx === undefined) {
			throw new SchemaError(
				`SchemaDictionary: unknown action "${name}"`,
				"ACTION_NOT_FOUND",
			);
		}
		return this.actionsByIndex[idx];
	}

	/** Get the action name for a given action index. Throws if out of range. */
	getActionName(index: number): string {
		const action = this.actionsByIndex[index];
		if (action === undefined) {
			throw new SchemaError(
				`SchemaDictionary: unknown action index ${index}`,
				"ACTION_NOT_FOUND",
			);
		}
		return action.name;
	}

	/** Encode a params object into an integer-keyed sparse field array. */
	encodeActionParams(
		action: ActionSchemaEntry,
		data: Record<string, JsonValue>,
	): SparseFieldArray {
		return this.encodeActionFields(
			data,
			action.paramFieldToIndex,
			`action "${action.name}" params`,
		);
	}

	/** Encode a returns object into an integer-keyed sparse field array. */
	encodeActionReturns(
		action: ActionSchemaEntry,
		data: Record<string, JsonValue>,
	): SparseFieldArray {
		return this.encodeActionFields(
			data,
			action.returnFieldToIndex,
			`action "${action.name}" returns`,
		);
	}

	/** Decode a params sparse field array into a nested string-keyed object. */
	decodeActionParams(
		action: ActionSchemaEntry,
		wireData: SparseFieldArray,
	): Record<string, JsonValue> {
		return this.decodeActionFields(
			wireData,
			action.params,
			action.paramPaths,
			`action "${action.name}" params`,
		);
	}

	/** Decode a returns sparse field array into a nested string-keyed object. */
	decodeActionReturns(
		action: ActionSchemaEntry,
		wireData: SparseFieldArray,
	): Record<string, JsonValue> {
		return this.decodeActionFields(
			wireData,
			action.returns,
			action.returnPaths,
			`action "${action.name}" returns`,
		);
	}

	private encodeActionFields(
		data: Record<string, JsonValue>,
		indexMap: Map<string, number>,
		label: string,
	): SparseFieldArray {
		const flat = flatten(data);
		const result: SparseFieldArray = [];
		for (const [key, value] of Object.entries(flat)) {
			const index = indexMap.get(key);
			if (index === undefined) {
				throw new SchemaError(
					`SchemaDictionary: unknown field "${key}" in ${label}`,
					"FIELD_NOT_FOUND",
				);
			}
			result.push(index, value);
		}
		return result;
	}

	private decodeActionFields(
		wireData: SparseFieldArray,
		fields: string[],
		paths: Array<string[] | undefined>,
		label: string,
	): Record<string, JsonValue> {
		assertSparseLength(wireData, label);
		const result: Record<string, JsonValue> = {};
		for (let i = 0; i < wireData.length; i += 2) {
			const index = wireData[i] as number;
			const fieldName = fields[index];
			if (fieldName === undefined) {
				throw new SchemaError(
					`SchemaDictionary: unknown field index ${index} in ${label}`,
					"FIELD_NOT_FOUND",
				);
			}
			const value = wireData[i + 1] as JsonValue;
			const fieldPath = paths[index];
			if (fieldPath) setDeepProperty(result, fieldPath, value);
			else result[fieldName] = value;
		}
		return result;
	}

	// ─── Private helpers ───────────────────────────────────────────────────
	private getFieldFlags(tableIndex: number, fieldIndex: number): number {
		if (tableIndex < 0 || tableIndex >= this.tables.length) {
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
	 * Compute a 53-bit hash of the canonical SchemaSync routing
	 * dictionaries. Used for offline safety detection.
	 */
	private computeHash(payload: {
		tables: string[];
		fields: string[][];
		fieldFlags: number[][];
		presenceUserFields?: string[];
		presenceSharedFields?: string[];
		actions?: string[];
		actionParams?: string[][];
		actionReturns?: string[][];
		actionFlags?: number[];
	}): number {
		const canonical = JSON.stringify({
			tables: payload.tables,
			fields: payload.fields,
			fieldFlags: payload.fieldFlags,
			presenceUserFields: payload.presenceUserFields ?? [],
			presenceSharedFields: payload.presenceSharedFields ?? [],
			actions: payload.actions ?? [],
			actionParams: payload.actionParams ?? [],
			actionReturns: payload.actionReturns ?? [],
			actionFlags: payload.actionFlags ?? [],
		});
		return hash(canonical);
	}
}
