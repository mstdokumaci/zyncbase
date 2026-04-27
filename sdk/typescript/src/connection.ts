// Connection Manager
import { decode, encode } from "@msgpack/msgpack";
import { ErrorCodes, SchemaError, ZyncBaseError } from "./errors.js";
import { SchemaDictionary } from "./schema_dictionary.js";
import type {
	ClientOptions,
	ConnectedMessage,
	ErrorResponse,
	InboundMessage,
	LifecycleEvent,
	OkResponse,
	StatusDetail,
	StoreDelta,
} from "./types";
import { generateUUIDv7 } from "./uuid.js";

const CLIENT_ID_STORAGE_KEY = "zyncbase_client_id";

function getOrCreateClientId(explicit?: string): string {
	if (explicit) return explicit;
	if (typeof localStorage !== "undefined") {
		const stored = localStorage.getItem(CLIENT_ID_STORAGE_KEY);
		if (stored) return stored;
		const id = generateUUIDv7();
		localStorage.setItem(CLIENT_ID_STORAGE_KEY, id);
		return id;
	}
	return generateUUIDv7();
}

type EventHandler = (...args: unknown[]) => void;
type MessageHandler = (msg: InboundMessage) => void;
type DeltaHandler = (delta: StoreDelta) => void;
type PendingEntry = {
	resolve: (value: OkResponse) => void;
	reject: (reason: unknown) => void;
	outboundType?: string;
	outboundTableIndex?: number;
};

type ConnectionStatus =
	| "connecting"
	| "connected"
	| "reconnecting"
	| "disconnected";

export class ConnectionManager {
	private options: ClientOptions;
	private ws: WebSocket | null = null;

	// msg_id counter and pending queue
	private nextMsgId = 1;
	private pendingQueue: Map<number, PendingEntry> = new Map();

	// Lifecycle event registry
	private eventListeners: Map<LifecycleEvent, EventHandler[]> = new Map();

	// Raw message handler (for internal use by Store layer)
	private messageHandler: MessageHandler | null = null;

	// Delta handler registered by SubscriptionTracker
	private deltaHandler: DeltaHandler | null = null;

	// Reconnection state
	private reconnectAttempt = 0;
	private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
	private intentionalDisconnect = false;
	private status: ConnectionStatus = "disconnected";

	// Active namespaces
	private storeNamespace: string;
	private presenceNamespace: string;
	private readonly clientId: string;

	// Schema dictionary (populated from SchemaSync)
	readonly schemaDictionary = new SchemaDictionary();

	// Sequence lock for inbound message processing
	private processingPromise: Promise<void> = Promise.resolve();

	// SchemaSync readiness promise
	private schemaSyncResolve: (() => void) | null = null;
	private schemaSyncReject: ((reason?: unknown) => void) | null = null;
	private schemaSyncPromise: Promise<void> = new Promise(() => {});

	constructor(options: ClientOptions) {
		this.options = options;
		this.storeNamespace = options.storeNamespace ?? "public";
		this.presenceNamespace = options.presenceNamespace ?? this.storeNamespace;
		this.clientId = getOrCreateClientId(options.clientId);
	}

	getStoreNamespace(): string {
		return this.storeNamespace;
	}
	async setStoreNamespace(ns: string): Promise<void> {
		await this.dispatch({ type: "StoreSetNamespace", namespace: ns });
		this.storeNamespace = ns;
	}
	getPresenceNamespace(): string {
		return this.presenceNamespace;
	}
	setPresenceNamespace(ns: string) {
		this.presenceNamespace = ns;
	}

	/** Open the WebSocket and resolve when connected. */
	connect(): Promise<void> {
		this.intentionalDisconnect = false;
		this.setStatus("connecting");
		this.processingPromise = Promise.resolve();

		// Create a fresh SchemaSync readiness promise
		this.schemaSyncPromise = new Promise<void>((resolve, reject) => {
			this.schemaSyncResolve = resolve;
			this.schemaSyncReject = reject;
		});
		// Prevent unhandled rejections if the promise is rejected before it's awaited
		this.schemaSyncPromise.catch(() => {});

		return new Promise((resolve, reject) => {
			const url = new URL(this.options.url);
			url.searchParams.set("clientId", this.clientId);
			const ws = new WebSocket(url.toString());
			ws.binaryType = "arraybuffer";
			this.ws = ws;

			ws.onopen = () => {
				this.setStoreNamespace(this.storeNamespace)
					.then(() => {
						this.reconnectAttempt = 0;
						this.setStatus("connected");
						this.emit("connected");
						resolve();
					})
					.catch(reject);
			};

			ws.onerror = (_event) => this._handleSocketError(reject);

			ws.onclose = (_event) =>
				this._handleSocketClose(_event.code, _event.reason);

			ws.onmessage = (event) => this._handleRawMessage(event.data);
		});
	}

	private _handleSocketError(reject: (reason?: unknown) => void): void {
		const err = new ZyncBaseError("WebSocket error", {
			code: ErrorCodes.CONNECTION_FAILED,
			category: "network",
			retryable: true,
		});
		if (this.schemaSyncReject) {
			this.schemaSyncReject(err);
			this.schemaSyncReject = null;
		}
		this.emit("error", err);
		reject(err);
	}

	private _handleSocketClose(code: number, reason: string): void {
		const err = new ZyncBaseError("Connection closed", {
			code: ErrorCodes.CONNECTION_FAILED,
			category: "network",
			retryable: true,
		});

		if (this.schemaSyncReject) {
			this.schemaSyncReject(err);
			this.schemaSyncReject = null;
		}

		// Reject all pending requests
		for (const [_id, { reject: rej }] of this.pendingQueue) {
			rej(err);
		}
		this.pendingQueue.clear();

		if (!this.intentionalDisconnect && (this.options.reconnect ?? true)) {
			this._scheduleReconnect();
		} else {
			this.setStatus("disconnected");
			this.emit("disconnected", code, reason);
		}
	}

	/** Wait for SchemaSync to be received and processed. */
	awaitSchemaSync(): Promise<void> {
		return this.schemaSyncPromise;
	}

	/** Compute the backoff delay for a given attempt number. Exported for testing. */
	_computeBackoffDelay(attempt: number): number {
		const base = this.options.reconnectDelay ?? 1000;
		const maxDelay = this.options.maxReconnectDelay ?? 30_000;
		const preCap = base * 2 ** attempt;
		const jitter =
			(this.options.reconnectJitter ?? true)
				? preCap * (Math.random() * 0.2 - 0.1) // ±10% of preCap
				: 0;
		return Math.min(preCap + jitter, maxDelay);
	}

	/** Schedule the next reconnect attempt with exponential backoff. */
	private _scheduleReconnect(): void {
		const maxAttempts = this.options.maxReconnectAttempts ?? Infinity;
		if (this.reconnectAttempt >= maxAttempts) {
			this.setStatus("disconnected");
			this.emit("disconnected");
			return;
		}

		const delay = this._computeBackoffDelay(this.reconnectAttempt);
		this.reconnectAttempt++;

		this.setStatus("reconnecting", {
			retryCount: this.reconnectAttempt,
			retryIn: delay,
		});
		this.emit("reconnecting", this.reconnectAttempt, delay);

		this.reconnectTimer = setTimeout(() => {
			this.reconnectTimer = null;
			this.connect().catch(() => {
				// connect() will trigger onclose again if it fails, which calls _scheduleReconnect
			});
		}, delay);
	}

	/** Send raw bytes over the WebSocket. */
	send(data: Uint8Array): void {
		if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
			throw new ZyncBaseError("WebSocket is not connected", {
				code: ErrorCodes.CONNECTION_FAILED,
				category: "network",
				retryable: true,
			});
		}
		this.ws.send(data);
	}

	/**
	 * Encode a message object, assign a msg_id, add to pendingQueue, send it,
	 * and return a Promise that resolves/rejects when the server responds.
	 */
	dispatch(msg: Record<string, unknown>): Promise<OkResponse> {
		const id = this.nextMsgId++;

		const msgWithId: Record<string, unknown> = { ...msg, id };

		if (this.options.debug) {
			console.log(
				`[SDK] >> ${msgWithId.type} (id=${id}):`,
				JSON.stringify(msgWithId),
			);
		}
		let wireMsgWithId: Record<string, unknown>;
		try {
			wireMsgWithId = this._encodeWireMessage(msgWithId);
		} catch (err) {
			throw this._mapSchemaEncodingError(err);
		}
		const encoded = encode(wireMsgWithId) as Uint8Array;

		return new Promise((resolve, reject) => {
			this.pendingQueue.set(id, {
				resolve,
				reject,
				outboundType:
					typeof wireMsgWithId.type === "string"
						? (wireMsgWithId.type as string)
						: undefined,
				outboundTableIndex:
					typeof wireMsgWithId.table_index === "number"
						? (wireMsgWithId.table_index as number)
						: undefined,
			});
			try {
				this.send(encoded);
			} catch (err) {
				this.pendingQueue.delete(id);
				reject(err);
			}
		});
	}

	/** Register a handler for decoded inbound messages (used by Store layer). */
	onMessage(handler: MessageHandler): void {
		this.messageHandler = handler;
	}

	/** Register the delta handler (used by SubscriptionTracker). */
	onDelta(handler: DeltaHandler): void {
		this.deltaHandler = handler;
	}

	/** Close the WebSocket and cancel any pending operations. */
	disconnect(): void {
		this.intentionalDisconnect = true;

		// Cancel any pending reconnect timer
		if (this.reconnectTimer !== null) {
			clearTimeout(this.reconnectTimer);
			this.reconnectTimer = null;
		}

		if (this.ws) {
			this.ws.onclose = null; // prevent the close handler from firing reconnect logic
			this.ws.close();
			this.ws = null;
		}
		// Reject all pending requests
		const discErr = new ZyncBaseError("Disconnected", {
			code: ErrorCodes.CONNECTION_FAILED,
			category: "network",
			retryable: false,
		});

		if (this.schemaSyncReject) {
			this.schemaSyncReject(discErr);
			this.schemaSyncReject = null;
		}

		for (const [, { reject: rej }] of this.pendingQueue) {
			rej(discErr);
		}
		this.pendingQueue.clear();
		this.setStatus("disconnected");
		this.emit("disconnected");
	}

	/** Register a lifecycle event listener. */
	on(event: LifecycleEvent, handler: EventHandler): void {
		if (!this.eventListeners.has(event)) {
			this.eventListeners.set(event, []);
		}
		this.eventListeners.get(event)?.push(handler);
	}

	/** Remove a lifecycle event listener. */
	off(event: LifecycleEvent, handler: EventHandler): void {
		const handlers = this.eventListeners.get(event);
		if (handlers) {
			const idx = handlers.indexOf(handler);
			if (idx !== -1) handlers.splice(idx, 1);
		}
	}

	private emit(event: LifecycleEvent, ...args: unknown[]): void {
		const handlers = this.eventListeners.get(event);
		if (handlers) {
			for (const h of handlers) {
				h(...args);
			}
		}
	}

	private setStatus(
		status: ConnectionStatus,
		detail?: Partial<StatusDetail>,
	): void {
		const previousStatus = this.status as LifecycleEvent;
		this.status = status;

		const fullDetail: StatusDetail = {
			previousStatus:
				previousStatus === "disconnected" && status === "connecting"
					? null
					: previousStatus,
			retryCount: detail?.retryCount ?? this.reconnectAttempt,
			retryIn: detail?.retryIn ?? null,
			error: detail?.error,
		};

		this.emit("statusChange", status, fullDetail);
	}

	private _handleRawMessage(data: ArrayBuffer | Uint8Array): void {
		// Queue the message for sequential processing
		this.processingPromise = this.processingPromise
			.then(() => this._processInbound(data))
			.catch((err) => {
				if (this.options.debug) {
					console.error("[SDK] Error processing inbound message:", err);
				}
			});
	}

	private async _processInbound(data: ArrayBuffer | Uint8Array): Promise<void> {
		let msg: InboundMessage;
		try {
			msg = decode(
				data instanceof ArrayBuffer ? new Uint8Array(data) : data,
			) as InboundMessage;
		} catch {
			return;
		}

		if (!msg || typeof msg !== "object" || !("type" in msg)) return;

		const type = (msg as unknown as Record<string, unknown>).type as string;
		const id = (msg as unknown as Record<string, unknown>).id ?? "push";
		if (this.options.debug) {
			console.log(`[SDK] << ${type} (id=${id}):`, JSON.stringify(msg));
		}

		let processedMsg: InboundMessage = msg;
		switch (type) {
			case "Connected":
				this._handleConnected(msg as ConnectedMessage);
				return;
			case "SchemaSync":
				await this._handleSchemaSync(msg);
				return; // SchemaSync is internal — not dispatched to messageHandler
			case "ok":
				this._handleOkResponse(msg as OkResponse);
				break;
			case "error":
				this._handleErrorResponse(msg as ErrorResponse);
				break;
			case "StoreDelta":
				processedMsg = this._decodeDelta(msg as StoreDelta);
				this._handleDeltaPush(processedMsg as StoreDelta);
				break;
		}

		if (this.messageHandler) this.messageHandler(processedMsg);
	}

	private _handleConnected(msg: ConnectedMessage): void {
		if (msg.storeNamespace) this.storeNamespace = msg.storeNamespace;
		if (msg.presenceNamespace) this.presenceNamespace = msg.presenceNamespace;
		if (this.options.debug) {
			console.log(`[SDK] Connected as userId=${msg.userId}`);
		}
	}

	private _handleOkResponse(ok: OkResponse): void {
		const entry = this.pendingQueue.get(ok.id);
		if (entry) {
			this.pendingQueue.delete(ok.id);
			let decodedOk = ok;
			try {
				if (
					(entry.outboundType === "StoreQuery" ||
						entry.outboundType === "StoreSubscribe" ||
						entry.outboundType === "StoreLoadMore") &&
					typeof entry.outboundTableIndex === "number" &&
					Array.isArray(ok.value)
				) {
					decodedOk = {
						...ok,
						value: ok.value.map((row) =>
							this._decodeRow(entry.outboundTableIndex as number, row),
						) as OkResponse["value"],
					};
				}
				entry.resolve(decodedOk);
			} catch (err) {
				entry.reject(err);
			}
		}
	}

	private _handleErrorResponse(err: ErrorResponse): void {
		const entry = this.pendingQueue.get(err.id);
		if (entry) {
			this.pendingQueue.delete(err.id);
			entry.reject(ZyncBaseError.fromServerResponse(err));
		}
	}

	private async _handleSchemaSync(msg: InboundMessage): Promise<void> {
		const payload = msg as {
			tables: string[];
			fields: string[][];
			fieldFlags: number[][];
		};
		let schemaChanged: boolean;
		try {
			schemaChanged = await this.schemaDictionary.processSchemaSync(payload);
		} catch (err) {
			const error =
				err instanceof ZyncBaseError
					? err
					: new ZyncBaseError(
							err instanceof Error ? err.message : "Invalid SchemaSync payload",
							{
								code: ErrorCodes.INVALID_MESSAGE,
								category: "validation",
								retryable: false,
							},
						);
			if (this.schemaSyncReject) {
				this.schemaSyncReject(error);
				this.schemaSyncResolve = null;
				this.schemaSyncReject = null;
			}
			this.emit("error", error);
			throw error;
		}

		if (schemaChanged) {
			this.emit("schemaChange");
		}
		// Resolve the schemaSyncPromise so awaitSchemaSync() unblocks
		if (this.schemaSyncResolve) {
			this.schemaSyncResolve();
			this.schemaSyncResolve = null;
			this.schemaSyncReject = null;
		}
	}

	private _handleDeltaPush(delta: StoreDelta): void {
		if (this.deltaHandler) {
			this.deltaHandler(delta);
		}
	}

	private _encodeWireMessage(
		msg: Record<string, unknown>,
	): Record<string, unknown> {
		const type = msg.type;
		if (typeof type !== "string" || !type.startsWith("Store")) return msg;

		let wire: Record<string, unknown> = { ...msg };

		if (type === "StoreSet" || type === "StoreRemove") {
			wire = this._encodeStoreSetRemove(wire, type);
		} else if (type === "StoreBatch") {
			wire = this._encodeStoreBatch(wire);
		} else if (
			type === "StoreQuery" ||
			type === "StoreSubscribe" ||
			type === "StoreLoadMore"
		) {
			wire = this._encodeStoreQuerySubscribe(wire);
		}

		return wire;
	}

	private _encodeStoreSetRemove(
		wire: Record<string, unknown>,
		type: string,
	): Record<string, unknown> {
		const path = wire.path;
		if (Array.isArray(path) && path.length > 0 && typeof path[0] === "string") {
			const logicalPath = path as string[];
			const encodedPath = this.schemaDictionary.encodePath(logicalPath);
			wire.path = encodedPath;
			const tableIndex = encodedPath[0] as number;
			if (
				type === "StoreSet" &&
				logicalPath.length === 2 &&
				wire.value !== null &&
				typeof wire.value === "object" &&
				!Array.isArray(wire.value)
			) {
				wire.value = this.schemaDictionary.encodeValue(
					tableIndex,
					wire.value as Record<string, unknown>,
				);
			} else if (
				type === "StoreSet" &&
				logicalPath.length >= 3 &&
				encodedPath.length === 3
			) {
				wire.value = this.schemaDictionary.encodeFieldValue(
					tableIndex,
					encodedPath[2] as number,
					wire.value,
				);
			}
		}
		return wire;
	}

	private _encodeStoreBatch(
		wire: Record<string, unknown>,
	): Record<string, unknown> {
		if (Array.isArray(wire.ops)) {
			wire.ops = wire.ops.map((op) => this._encodeBatchOp(op));
		}
		return wire;
	}

	private _encodeBatchOp(op: unknown): unknown {
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

		const encodedPath = this.schemaDictionary.encodePath(rawPath as string[]);
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
				this.schemaDictionary.encodeValue(
					tableIndex,
					op[2] as Record<string, unknown>,
				),
			];
		}
		if (kind === "s" && encodedPath.length === 3) {
			return [
				"s",
				encodedPath,
				this.schemaDictionary.encodeFieldValue(
					encodedPath[0] as number,
					encodedPath[2] as number,
					op[2],
				),
			];
		}
		return ["s", encodedPath, op[2]];
	}

	private _encodeStoreQuerySubscribe(
		wire: Record<string, unknown>,
	): Record<string, unknown> {
		if (typeof wire.table_index === "string") {
			const tableIndex = this.schemaDictionary.getTableIndex(
				wire.table_index as string,
			);
			wire.table_index = tableIndex;

			if (wire.conditions !== undefined) {
				wire.conditions = this._encodeConditions(tableIndex, wire.conditions);
			}
			if (wire.orConditions !== undefined) {
				wire.orConditions = this._encodeConditions(
					tableIndex,
					wire.orConditions,
				);
			}
			if (wire.orderBy !== undefined) {
				wire.orderBy = this._encodeOrderBy(tableIndex, wire.orderBy);
			}
		}
		return wire;
	}

	private _encodeConditions(tableIndex: number, raw: unknown): unknown {
		if (!Array.isArray(raw)) return raw;
		return raw.map((cond) => {
			if (!Array.isArray(cond) || cond.length < 2) return cond;
			const field = cond[0];
			const op = cond[1];
			const fieldIndex =
				typeof field === "string"
					? this.schemaDictionary.getFieldIndex(tableIndex, field)
					: field;
			return cond.length === 2
				? [fieldIndex, op]
				: [
						fieldIndex,
						op,
						this.schemaDictionary.encodeFieldValue(
							tableIndex,
							fieldIndex as number,
							cond[2],
						),
					];
		});
	}

	private _encodeOrderBy(tableIndex: number, raw: unknown): unknown {
		if (!Array.isArray(raw) || raw.length !== 2) return raw;
		const field = raw[0];
		const dir = raw[1];
		const fieldIndex =
			typeof field === "string"
				? this.schemaDictionary.getFieldIndex(tableIndex, field)
				: field;
		return [fieldIndex, dir];
	}

	private _decodeDelta(delta: StoreDelta): StoreDelta {
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
				decodedPath = this.schemaDictionary.decodePath(
					wirePath,
				) as unknown as string[];
			}

			if (
				op.op === "set" &&
				tableIndex !== null &&
				wirePath.length === 2 &&
				op.value !== null &&
				typeof op.value === "object" &&
				!Array.isArray(op.value) &&
				this._isNumericKeyedObject(op.value as Record<string, unknown>)
			) {
				return {
					...op,
					path: decodedPath,
					value: this.schemaDictionary.decodeValue(
						tableIndex,
						op.value as unknown as Record<number, unknown>,
					) as unknown as typeof op.value,
				};
			}
			if (op.op === "set" && tableIndex !== null && wirePath.length === 3) {
				return {
					...op,
					path: decodedPath,
					value: this.schemaDictionary.decodeFieldValue(
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

	private _decodeRow(tableIndex: number, row: unknown): unknown {
		if (
			row === null ||
			typeof row !== "object" ||
			Array.isArray(row) ||
			!this._isNumericKeyedObject(row as Record<string, unknown>)
		) {
			return row;
		}
		return this.schemaDictionary.decodeValue(
			tableIndex,
			row as Record<number, unknown>,
		);
	}

	private _isNumericKeyedObject(obj: Record<string, unknown>): boolean {
		const keys = Object.keys(obj);
		return keys.length > 0 && keys.every((k) => /^\d+$/.test(k));
	}

	private _mapSchemaEncodingError(err: unknown): ZyncBaseError {
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
