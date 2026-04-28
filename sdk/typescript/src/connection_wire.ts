import { decode, encode } from "@msgpack/msgpack";
import { ErrorCodes, SchemaError, ZyncBaseError } from "./errors.js";
import { SchemaDictionary } from "./schema_dictionary.js";
import type {
	ErrorResponse,
	InboundMessage,
	JsonValue,
	OkResponse,
	OutboundMessage,
	SchemaSync,
	StoreBatch,
	StoreDelta,
	StoreLoadMore,
	StoreQuery,
	StoreRemove,
	StoreSet,
	StoreSetNamespace,
	StoreSubscribe,
	StoreUnsubscribe,
} from "./types.js";

type WithoutId<T extends { id: number }> = Omit<T, "id">;

export type OutboundRequest =
	| WithoutId<StoreSet>
	| WithoutId<StoreRemove>
	| WithoutId<StoreBatch>
	| WithoutId<StoreSetNamespace>
	| WithoutId<StoreQuery>
	| WithoutId<StoreSubscribe>
	| WithoutId<StoreUnsubscribe>
	| WithoutId<StoreLoadMore>;

export interface PendingRequestContext {
	type: OutboundMessage["type"];
	responseTableIndex?: number;
}

export interface EncodedOutbound {
	bytes: Uint8Array;
	context: PendingRequestContext;
	debugMessage: OutboundMessage;
}

export class ConnectionWireCodec {
	readonly schema = new SchemaDictionary();

	encode(message: OutboundRequest, id: number): EncodedOutbound {
		const debugMessage = { ...message, id } as OutboundMessage;
		let wireMessage: Record<string, unknown>;
		try {
			wireMessage = this.encodeWireMessage(
				debugMessage as unknown as Record<string, unknown>,
			);
		} catch (err) {
			throw this.mapSchemaEncodingError(err);
		}

		const responseTableIndex: number | undefined =
			typeof wireMessage.table_index === "number"
				? wireMessage.table_index
				: undefined;

		if (debugMessage.type === "StoreLoadMore" && "table_index" in wireMessage) {
			const { table_index: _, ...rest } = wireMessage;
			wireMessage = rest;
		}

		return {
			bytes: encode(wireMessage) as Uint8Array,
			context: { type: debugMessage.type, responseTableIndex },
			debugMessage,
		};
	}

	decode(data: ArrayBuffer | Uint8Array): InboundMessage | null {
		let msg: InboundMessage;
		try {
			msg = decode(
				data instanceof ArrayBuffer ? new Uint8Array(data) : data,
			) as InboundMessage;
		} catch {
			return null;
		}

		if (!msg || typeof msg !== "object" || !("type" in msg)) return null;
		if (msg.type === "StoreDelta") return this.decodeDelta(msg);
		return msg;
	}

	decodeOkResponse(
		ok: OkResponse,
		context?: PendingRequestContext,
	): OkResponse {
		if (
			(context?.type === "StoreQuery" ||
				context?.type === "StoreSubscribe" ||
				context?.type === "StoreLoadMore") &&
			typeof context.responseTableIndex === "number" &&
			Array.isArray(ok.value)
		) {
			return {
				...ok,
				value: ok.value.map((row) =>
					this.decodeRow(context.responseTableIndex as number, row),
				) as OkResponse["value"],
			};
		}
		return ok;
	}

	async applySchemaSync(msg: SchemaSync): Promise<boolean> {
		return this.schema.processSchemaSync({
			tables: msg.tables,
			fields: msg.fields,
			fieldFlags: msg.fieldFlags,
		});
	}

	isSchemaReady(): boolean {
		return this.schema.isReady();
	}

	get schemaHash(): string | null {
		return this.schema.getHash();
	}

	private encodeWireMessage(
		msg: Record<string, unknown>,
	): Record<string, unknown> {
		const type = msg.type;
		if (typeof type !== "string" || !type.startsWith("Store")) return msg;

		let wire: Record<string, unknown> = { ...msg };
		if (type === "StoreSet" || type === "StoreRemove") {
			wire = this.encodeStoreSetRemove(wire, type);
		} else if (type === "StoreBatch") {
			wire = this.encodeStoreBatch(wire);
		} else if (
			type === "StoreQuery" ||
			type === "StoreSubscribe" ||
			type === "StoreLoadMore"
		) {
			wire = this.encodeStoreQuerySubscribe(wire);
		}
		return wire;
	}

	private encodeStoreSetRemove(
		wire: Record<string, unknown>,
		type: string,
	): Record<string, unknown> {
		const path = wire.path;
		if (Array.isArray(path) && path.length > 0 && typeof path[0] === "string") {
			const logicalPath = path as string[];
			const encodedPath = this.schema.encodePath(logicalPath);
			wire.path = encodedPath;
			const tableIndex = encodedPath[0] as number;
			if (
				type === "StoreSet" &&
				logicalPath.length === 2 &&
				wire.value !== null &&
				typeof wire.value === "object" &&
				!Array.isArray(wire.value)
			) {
				wire.value = this.schema.encodeValue(
					tableIndex,
					wire.value as Record<string, unknown>,
				);
			} else if (
				type === "StoreSet" &&
				logicalPath.length >= 3 &&
				encodedPath.length === 3
			) {
				wire.value = this.schema.encodeFieldValue(
					tableIndex,
					encodedPath[2] as number,
					wire.value,
				);
			}
		}
		return wire;
	}

	private encodeStoreBatch(
		wire: Record<string, unknown>,
	): Record<string, unknown> {
		if (Array.isArray(wire.ops)) {
			wire.ops = wire.ops.map((op) => this.encodeBatchOp(op));
		}
		return wire;
	}

	private encodeBatchOp(op: unknown): unknown {
		if (!Array.isArray(op) || op.length < 2) return op;
		const kind = op[0];
		const rawPath = op[1];
		if (
			!Array.isArray(rawPath) ||
			rawPath.length === 0 ||
			typeof rawPath[0] !== "string"
		) {
			return op;
		}

		const encodedPath = this.schema.encodePath(rawPath as string[]);
		if (kind === "r") return ["r", encodedPath];
		if (
			kind === "s" &&
			(rawPath as string[]).length === 2 &&
			op[2] !== null &&
			typeof op[2] === "object" &&
			!Array.isArray(op[2])
		) {
			const tableIndex = encodedPath[0] as number;
			return [
				"s",
				encodedPath,
				this.schema.encodeValue(tableIndex, op[2] as Record<string, unknown>),
			];
		}
		if (kind === "s" && encodedPath.length === 3) {
			return [
				"s",
				encodedPath,
				this.schema.encodeFieldValue(
					encodedPath[0] as number,
					encodedPath[2] as number,
					op[2],
				),
			];
		}
		return ["s", encodedPath, op[2]];
	}

	private encodeStoreQuerySubscribe(
		wire: Record<string, unknown>,
	): Record<string, unknown> {
		if (typeof wire.table_index === "string") {
			const tableIndex = this.schema.getTableIndex(wire.table_index);
			wire.table_index = tableIndex;

			if (wire.conditions !== undefined) {
				wire.conditions = this.encodeConditions(tableIndex, wire.conditions);
			}
			if (wire.orConditions !== undefined) {
				wire.orConditions = this.encodeConditions(
					tableIndex,
					wire.orConditions,
				);
			}
			if (wire.orderBy !== undefined) {
				wire.orderBy = this.encodeOrderBy(tableIndex, wire.orderBy);
			}
		}
		return wire;
	}

	private encodeConditions(tableIndex: number, raw: unknown): unknown {
		if (!Array.isArray(raw)) return raw;
		return raw.map((cond) => {
			if (!Array.isArray(cond) || cond.length < 2) return cond;
			const field = cond[0];
			const op = cond[1];
			const fieldIndex =
				typeof field === "string"
					? this.schema.getFieldIndex(tableIndex, field)
					: field;
			return cond.length === 2
				? [fieldIndex, op]
				: [
						fieldIndex,
						op,
						this.schema.encodeFieldValue(
							tableIndex,
							fieldIndex as number,
							cond[2],
						),
					];
		});
	}

	private encodeOrderBy(tableIndex: number, raw: unknown): unknown {
		if (!Array.isArray(raw) || raw.length !== 2) return raw;
		const field = raw[0];
		const dir = raw[1];
		const fieldIndex =
			typeof field === "string"
				? this.schema.getFieldIndex(tableIndex, field)
				: field;
		return [fieldIndex, dir];
	}

	private decodeDelta(delta: StoreDelta): StoreDelta {
		const decodedOps = delta.ops.map((op) => {
			const wirePath = op.path as unknown as Array<
				number | string | Uint8Array
			>;
			let decodedPath = op.path;
			let tableIndex: number | null = null;
			if (
				Array.isArray(wirePath) &&
				wirePath.length > 0 &&
				typeof wirePath[0] === "number"
			) {
				tableIndex = wirePath[0] as number;
				decodedPath = this.schema.decodePath(wirePath) as unknown as string[];
			}

			if (
				op.op === "set" &&
				tableIndex !== null &&
				wirePath.length === 2 &&
				op.value !== null &&
				typeof op.value === "object" &&
				!Array.isArray(op.value) &&
				isNumericKeyedObject(op.value as Record<string, unknown>)
			) {
				return {
					...op,
					path: decodedPath,
					value: this.schema.decodeValue(
						tableIndex,
						op.value as unknown as Record<number, unknown>,
					) as unknown as typeof op.value,
				};
			}
			if (op.op === "set" && tableIndex !== null && wirePath.length === 3) {
				return {
					...op,
					path: decodedPath,
					value: this.schema.decodeFieldValue(
						tableIndex,
						wirePath[2] as number,
						op.value,
					) as typeof op.value,
				};
			}
			return { ...op, path: decodedPath };
		});
		return { ...delta, ops: decodedOps } as StoreDelta;
	}

	private decodeRow(tableIndex: number, row: JsonValue): JsonValue {
		if (
			row === null ||
			typeof row !== "object" ||
			Array.isArray(row) ||
			!isNumericKeyedObject(row as Record<string, unknown>)
		) {
			return row;
		}
		return this.schema.decodeValue(
			tableIndex,
			row as unknown as Record<number, unknown>,
		) as JsonValue;
	}

	private mapSchemaEncodingError(err: unknown): ZyncBaseError {
		if (err instanceof ZyncBaseError) return err;

		if (err instanceof SchemaError) {
			if (err.code === "TABLE_NOT_FOUND") {
				return new ZyncBaseError(err.message, {
					code: ErrorCodes.COLLECTION_NOT_FOUND,
					category: "validation",
					retryable: false,
				});
			}
			if (err.code === "FIELD_NOT_FOUND") {
				return new ZyncBaseError(err.message, {
					code: ErrorCodes.FIELD_NOT_FOUND,
					category: "validation",
					retryable: false,
				});
			}
		}

		const message =
			err instanceof Error ? err.message : "Schema encoding failed";
		return new ZyncBaseError(message, {
			code: ErrorCodes.INVALID_MESSAGE,
			category: "validation",
			retryable: false,
		});
	}
}

function isNumericKeyedObject(obj: Record<string, unknown>): boolean {
	const keys = Object.keys(obj);
	return keys.length > 0 && keys.every((key) => /^\d+$/.test(key));
}

export function errorResponseToError(err: ErrorResponse): ZyncBaseError {
	return ZyncBaseError.fromServerResponse(err);
}
