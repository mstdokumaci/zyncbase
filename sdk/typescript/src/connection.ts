// Connection Manager
import {
	ConnectionWireCodec,
	errorResponseToError,
	type OutboundRequest,
} from "./connection_wire.js";
import { ErrorCodes, ZyncBaseError } from "./errors.js";
import { PendingRequests } from "./pending_requests.js";
import type {
	ClientOptions,
	ConnectedMessage,
	ErrorResponse,
	InboundMessage,
	LifecycleEvent,
	OkResponse,
	SchemaSync,
	StatusDetail,
	StoreDelta,
} from "./types.js";
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

type ConnectionStatus =
	| "connecting"
	| "connected"
	| "reconnecting"
	| "disconnected";

export class ConnectionManager {
	private readonly options: ClientOptions;
	private readonly wire = new ConnectionWireCodec();
	readonly schemaDictionary = this.wire.schema;

	private ws: WebSocket | null = null;
	private readonly pending = new PendingRequests<
		OkResponse,
		ReturnType<ConnectionWireCodec["encode"]>["context"]
	>();
	private readonly eventListeners = new Map<LifecycleEvent, EventHandler[]>();

	private messageHandler: MessageHandler | null = null;
	private deltaHandler: DeltaHandler | null = null;

	private reconnectAttempt = 0;
	private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
	private intentionalDisconnect = false;
	private status: ConnectionStatus = "disconnected";

	private storeNamespace: string;
	private presenceNamespace: string;
	private readonly clientId: string;

	private processingPromise: Promise<void> = Promise.resolve();

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

	setPresenceNamespace(ns: string): void {
		this.presenceNamespace = ns;
	}

	connect(): Promise<void> {
		this.intentionalDisconnect = false;
		this.setStatus("connecting");
		this.processingPromise = Promise.resolve();
		this.resetSchemaSyncPromise();

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

			ws.onerror = () => this.handleSocketError(reject);
			ws.onclose = (event) => this.handleSocketClose(event.code, event.reason);
			ws.onmessage = (event) => this.handleRawMessage(event.data);
		});
	}

	awaitSchemaSync(): Promise<void> {
		return this.schemaSyncPromise;
	}

	_computeBackoffDelay(attempt: number): number {
		const base = this.options.reconnectDelay ?? 1000;
		const maxDelay = this.options.maxReconnectDelay ?? 30_000;
		const preCap = base * 2 ** attempt;
		const jitter =
			(this.options.reconnectJitter ?? true)
				? preCap * (Math.random() * 0.2 - 0.1)
				: 0;
		return Math.min(preCap + jitter, maxDelay);
	}

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

	dispatch(msg: OutboundRequest): Promise<OkResponse> {
		const id = this.pending.nextId();
		const encoded = this.wire.encode(msg, id);

		if (this.options.debug) {
			console.log(
				`[SDK] >> ${encoded.debugMessage.type} (id=${id}):`,
				JSON.stringify(encoded.debugMessage),
			);
		}

		const result = this.pending.register(id, encoded.context);
		try {
			this.send(encoded.bytes);
		} catch (err) {
			this.pending.reject(id, err);
		}
		return result;
	}

	onMessage(handler: MessageHandler): void {
		this.messageHandler = handler;
	}

	onDelta(handler: DeltaHandler): void {
		this.deltaHandler = handler;
	}

	disconnect(): void {
		this.intentionalDisconnect = true;
		if (this.reconnectTimer !== null) {
			clearTimeout(this.reconnectTimer);
			this.reconnectTimer = null;
		}

		if (this.ws) {
			this.ws.onclose = null;
			this.ws.close();
			this.ws = null;
		}

		const err = new ZyncBaseError("Disconnected", {
			code: ErrorCodes.CONNECTION_FAILED,
			category: "network",
			retryable: false,
		});
		this.rejectSchemaSync(err);
		this.pending.rejectAll(err);
		this.setStatus("disconnected");
		this.emit("disconnected");
	}

	on(event: LifecycleEvent, handler: EventHandler): void {
		if (!this.eventListeners.has(event)) {
			this.eventListeners.set(event, []);
		}
		this.eventListeners.get(event)?.push(handler);
	}

	off(event: LifecycleEvent, handler: EventHandler): void {
		const handlers = this.eventListeners.get(event);
		if (!handlers) return;
		const index = handlers.indexOf(handler);
		if (index !== -1) handlers.splice(index, 1);
	}

	private resetSchemaSyncPromise(): void {
		this.schemaSyncPromise = new Promise<void>((resolve, reject) => {
			this.schemaSyncResolve = resolve;
			this.schemaSyncReject = reject;
		});
		this.schemaSyncPromise.catch(() => {});
	}

	private handleSocketError(reject: (reason?: unknown) => void): void {
		const err = new ZyncBaseError("WebSocket error", {
			code: ErrorCodes.CONNECTION_FAILED,
			category: "network",
			retryable: true,
		});
		this.rejectSchemaSync(err);
		this.emit("error", err);
		reject(err);
	}

	private handleSocketClose(code: number, reason: string): void {
		const err = new ZyncBaseError("Connection closed", {
			code: ErrorCodes.CONNECTION_FAILED,
			category: "network",
			retryable: true,
		});
		this.rejectSchemaSync(err);
		this.pending.rejectAll(err);

		if (!this.intentionalDisconnect && (this.options.reconnect ?? true)) {
			this.scheduleReconnect();
			return;
		}

		this.setStatus("disconnected");
		this.emit("disconnected", code, reason);
	}

	private scheduleReconnect(): void {
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
			this.connect().catch(() => {});
		}, delay);
	}

	private emit(event: LifecycleEvent, ...args: unknown[]): void {
		const handlers = this.eventListeners.get(event);
		if (!handlers) return;
		for (const handler of handlers) {
			handler(...args);
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

	private handleRawMessage(data: ArrayBuffer | Uint8Array): void {
		this.processingPromise = this.processingPromise
			.then(() => this.processInbound(data))
			.catch((err) => {
				if (this.options.debug) {
					console.error("[SDK] Error processing inbound message:", err);
				}
			});
	}

	private async processInbound(data: ArrayBuffer | Uint8Array): Promise<void> {
		const msg = this.wire.decode(data);
		if (!msg) return;

		const id = "id" in msg ? msg.id : "push";
		if (this.options.debug) {
			console.log(`[SDK] << ${msg.type} (id=${id}):`, JSON.stringify(msg));
		}

		switch (msg.type) {
			case "Connected":
				this.handleConnected(msg);
				return;
			case "SchemaSync":
				await this.handleSchemaSync(msg);
				return;
			case "ok":
				this.handleOkResponse(msg);
				break;
			case "error":
				this.handleErrorResponse(msg);
				break;
			case "StoreDelta":
				this.handleDeltaPush(msg);
				break;
		}

		this.messageHandler?.(msg);
	}

	private handleConnected(msg: ConnectedMessage): void {
		if (msg.storeNamespace) this.storeNamespace = msg.storeNamespace;
		if (msg.presenceNamespace) this.presenceNamespace = msg.presenceNamespace;
		if (this.options.debug) {
			console.log(`[SDK] Connected as userId=${msg.userId}`);
		}
	}

	private handleOkResponse(ok: OkResponse): void {
		const context = this.pending.context(ok.id);
		if (!context) return;

		try {
			this.pending.resolve(ok.id, this.wire.decodeOkResponse(ok, context));
		} catch (err) {
			this.pending.reject(ok.id, err);
		}
	}

	private handleErrorResponse(err: ErrorResponse): void {
		this.pending.reject(err.id, errorResponseToError(err));
	}

	private async handleSchemaSync(msg: SchemaSync): Promise<void> {
		let schemaChanged: boolean;
		try {
			schemaChanged = await this.wire.applySchemaSync(msg);
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
			this.rejectSchemaSync(error);
			this.emit("error", error);
			throw error;
		}

		if (schemaChanged) {
			this.emit("schemaChange");
		}
		this.resolveSchemaSync();
	}

	private handleDeltaPush(delta: StoreDelta): void {
		this.deltaHandler?.(delta);
	}

	private resolveSchemaSync(): void {
		if (!this.schemaSyncResolve) return;
		this.schemaSyncResolve();
		this.schemaSyncResolve = null;
		this.schemaSyncReject = null;
	}

	private rejectSchemaSync(reason: unknown): void {
		if (!this.schemaSyncReject) return;
		this.schemaSyncReject(reason);
		this.schemaSyncResolve = null;
		this.schemaSyncReject = null;
	}
}
