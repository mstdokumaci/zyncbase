// Connection Manager

import { acquireTicket } from "./auth.js";
import {
	ConnectionWireCodec,
	errorResponseToError,
	type OutboundRequest,
} from "./connection_wire.js";
import { ErrorCodes, ZyncBaseError } from "./errors.js";
import { PendingRequests } from "./pending_requests.js";
import { RetryPolicy } from "./retry_policy.js";
import type {
	ActionForward,
	ClientOptions,
	ConnectionStatus,
	DisconnectDetail,
	ErrorResponse,
	InboundMessage,
	LifecycleEvent,
	OkResponse,
	SchemaSync,
	StatusDetail,
	StoreDelta,
} from "./types.js";

type EventHandler = (...args: unknown[]) => void;
type MessageHandler = (msg: InboundMessage) => void;
type DeltaHandler = (delta: StoreDelta) => void;
type PresenceBroadcastHandler = (
	msg:
		| import("./types.js").PresenceBroadcast
		| import("./types.js").SharedStateBroadcast,
) => void;

const MAX_TIMER_DELAY_MS = 2_147_483_647;
const SERVER_DISCONNECT_CODES: Readonly<Record<string, string>> = {
	AUTH_FAILED: ErrorCodes.AUTH_FAILED,
	TOKEN_EXPIRED: ErrorCodes.TOKEN_EXPIRED,
	SERVER_SHUTDOWN: ErrorCodes.SERVER_SHUTDOWN,
	BACKPRESSURE_LIMIT: ErrorCodes.BACKPRESSURE_LIMIT,
	MAX_CONNECTIONS: ErrorCodes.MAX_CONNECTIONS,
};
const SOCKET_CLOSE_CODES: Readonly<Record<number, string>> = {
	4001: ErrorCodes.AUTH_FAILED,
	4002: ErrorCodes.SERVER_SHUTDOWN,
	4004: ErrorCodes.BACKPRESSURE_LIMIT,
	4005: ErrorCodes.MAX_CONNECTIONS,
	4006: ErrorCodes.TOKEN_EXPIRED,
};

function serverDisconnectError(code: string, message: string): ZyncBaseError {
	return ZyncBaseError.fromServerResponse({
		code: SERVER_DISCONNECT_CODES[code] ?? ErrorCodes.INTERNAL_ERROR,
		message: message || code,
	});
}

function socketCloseError(code: number, reason: string): ZyncBaseError {
	const errorCode = SOCKET_CLOSE_CODES[code] ?? ErrorCodes.CONNECTION_FAILED;
	return ZyncBaseError.fromServerResponse({
		code: errorCode,
		message:
			reason ||
			(errorCode === ErrorCodes.CONNECTION_FAILED
				? "Connection closed"
				: errorCode),
	});
}

type ResolvedLivenessOptions = Required<NonNullable<ClientOptions["liveness"]>>;

function resolveLivenessOptions(
	options: ClientOptions["liveness"],
): ResolvedLivenessOptions {
	const enabled = options?.enabled ?? true;
	const intervalMs = options?.intervalMs ?? 15_000;
	const timeoutMs = options?.timeoutMs ?? 10_000;
	if (options?.enabled !== undefined && typeof options.enabled !== "boolean") {
		throw new TypeError("liveness.enabled must be a boolean");
	}
	if (!Number.isSafeInteger(intervalMs) || intervalMs < 1_000) {
		throw new RangeError(
			"liveness.intervalMs must be an integer of at least 1000",
		);
	}
	if (
		!Number.isSafeInteger(timeoutMs) ||
		timeoutMs < 1 ||
		timeoutMs > MAX_TIMER_DELAY_MS
	) {
		throw new RangeError(
			"liveness.timeoutMs must be an integer from 1 to 2147483647",
		);
	}
	return { enabled, intervalMs, timeoutMs };
}

export class ConnectionManager {
	private readonly options: ClientOptions;
	private readonly wire = new ConnectionWireCodec();
	readonly schemaDictionary = this.wire.schema;
	private readonly retryPolicy: RetryPolicy;

	private ws: WebSocket | null = null;
	private readonly pending = new PendingRequests<
		OkResponse,
		ReturnType<ConnectionWireCodec["encode"]>["context"]
	>();
	private readonly eventListeners = new Map<LifecycleEvent, EventHandler[]>();

	private messageHandler: MessageHandler | null = null;
	private deltaHandler: DeltaHandler | null = null;
	private presenceBroadcastHandler: PresenceBroadcastHandler | null = null;
	private presenceUserIdHandler: ((userId: string) => void) | null = null;
	private actionForwardHandler: ((msg: ActionForward) => void) | null = null;

	private reconnectAttempt = 0;
	private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
	private intentionalDisconnect = false;
	private currentStatus: ConnectionStatus = "disconnected";

	private storeNamespace: string;
	private presenceNamespace: string;

	private processingPromise: Promise<void> = Promise.resolve();

	private schemaSyncResolve: (() => void) | null = null;
	private schemaSyncReject: ((reason?: unknown) => void) | null = null;
	private schemaSyncPromise: Promise<void> = new Promise(() => {});

	private _refreshInFlight: Promise<void> | null = null;
	private readonly livenessEnabled: boolean;
	private readonly livenessIntervalMs: number;
	private readonly livenessTimeoutMs: number;
	private livenessTimer: ReturnType<typeof setTimeout> | null = null;
	private livenessPingId: number | null = null;
	private pendingDisconnectError: ZyncBaseError | null = null;

	constructor(options: ClientOptions) {
		this.options = options;
		this.retryPolicy = new RetryPolicy(options);
		const liveness = resolveLivenessOptions(options.liveness);
		this.livenessEnabled = liveness.enabled;
		this.livenessIntervalMs = liveness.intervalMs;
		this.livenessTimeoutMs = liveness.timeoutMs;
		this.storeNamespace = options.storeNamespace ?? "public";
		this.presenceNamespace = options.presenceNamespace ?? this.storeNamespace;
	}

	getStoreNamespace(): string {
		return this.storeNamespace;
	}

	/** Current connection status. */
	get status(): ConnectionStatus {
		return this.currentStatus;
	}

	async setStoreNamespace(ns: string): Promise<void> {
		await this.dispatch({ type: "StoreSetNamespace", namespace: ns });
		this.storeNamespace = ns;
	}

	getPresenceNamespace(): string {
		return this.presenceNamespace;
	}

	onPresenceUserId(handler: (userId: string) => void): void {
		this.presenceUserIdHandler = handler;
	}

	async setPresenceNamespace(ns: string): Promise<void> {
		const ok = await this.dispatch({
			type: "PresenceSetNamespace",
			namespace: ns,
		});
		if (!(ok.userId instanceof Uint8Array)) {
			throw new Error("PresenceSetNamespace response missing binary userId");
		}
		const userId = this.schemaDictionary.decodePresenceUserId(ok.userId);
		this.presenceNamespace = ns;
		this.presenceUserIdHandler?.(userId);
	}

	private handleTicketError(err: unknown): never {
		const error =
			err instanceof ZyncBaseError
				? err
				: new ZyncBaseError(
						err instanceof Error ? err.message : "Ticket acquisition failed",
						{
							code: ErrorCodes.CONNECTION_FAILED,
							category: "network",
							retryable: true,
						},
					);
		this.rejectSchemaSync(error);
		this.setStatus("disconnected", { error });
		this.emit("error", error);
		if (
			!this.intentionalDisconnect &&
			(this.options.reconnect ?? true) &&
			error.retryable
		) {
			this.scheduleReconnect();
		}
		throw error;
	}

	private async acquireTicket(): Promise<string> {
		const auth = this.options.auth ?? { anonymous: true as const };
		try {
			const ticketResponse = await acquireTicket(this.options.url, auth);
			return ticketResponse.ticket;
		} catch (err) {
			return this.handleTicketError(err);
		}
	}

	private teardownSocket(): void {
		if (this.ws) {
			const ws = this.ws;
			this.ws = null;
			ws.onclose = null;
			ws.onerror = null;
			ws.onmessage = null;
			ws.close();
		}
	}

	private shouldReconnectAfterHandshake(err: unknown): boolean {
		return (
			!this.intentionalDisconnect &&
			(this.options.reconnect ?? true) &&
			(err instanceof ZyncBaseError ? err.retryable : true)
		);
	}

	private handleHandshakeFailure(
		err: unknown,
		reject: (reason?: unknown) => void,
	): void {
		this.stopLiveness();
		this.teardownSocket();
		this.pending.rejectAll(err);
		this.rejectSchemaSync(err);
		this.setStatus("disconnected", { error: err as ZyncBaseError });
		this.emit("error", err);
		// A failed handshake (e.g. the socket dropped while the
		// namespace messages were in flight) must keep the
		// reconnect loop alive — only an intentional disconnect
		// may end it.
		if (
			this.reconnectTimer === null &&
			this.shouldReconnectAfterHandshake(err)
		) {
			this.scheduleReconnect(err as ZyncBaseError);
		}
		reject(err);
	}

	async connect(): Promise<void> {
		this.intentionalDisconnect = false;
		this.pendingDisconnectError = null;
		this.stopLiveness();
		this.setStatus("connecting");
		this.processingPromise = Promise.resolve();
		this.resetSchemaSyncPromise();

		const ticket = await this.acquireTicket();

		return new Promise((resolve, reject) => {
			const url = new URL(this.options.url);
			url.searchParams.set("ticket", ticket);
			const ws = new WebSocket(url.toString());
			ws.binaryType = "arraybuffer";
			this.ws = ws;

			ws.onopen = () => {
				this.startLiveness();
				this.setStoreNamespace(this.storeNamespace)
					.then(() => this.setPresenceNamespace(this.presenceNamespace))
					.then(() => {
						this.reconnectAttempt = 0;
						this.setStatus("connected");
						this.emit("connected");
						resolve();
					})
					.catch((err) => this.handleHandshakeFailure(err, reject));
			};

			ws.onerror = () => this.handleSocketError(reject);
			ws.onclose = (event) => this.handleSocketClose(event.code, event.reason);
			ws.onmessage = (event) => this.handleRawMessage(event.data);
		});
	}

	awaitSchemaSync(): Promise<void> {
		return this.schemaSyncPromise;
	}

	isSchemaReady(): boolean {
		return (
			this.currentStatus === "connected" &&
			this.schemaSyncResolve === null &&
			this.schemaDictionary.isReady()
		);
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
		this.ws.send(data as Uint8Array<ArrayBuffer>);
	}

	private startLiveness(): void {
		this.stopLiveness();
		if (this.livenessEnabled) {
			this.scheduleLivenessProbe(Math.random() * this.livenessIntervalMs);
		}
	}

	private stopLiveness(): void {
		if (this.livenessTimer !== null) clearTimeout(this.livenessTimer);
		this.livenessTimer = null;
		this.livenessPingId = null;
	}

	private scheduleLivenessProbe(delayMs: number): void {
		if (!this.livenessEnabled || !this.ws || this.intentionalDisconnect) return;
		if (this.livenessTimer !== null) clearTimeout(this.livenessTimer);

		const schedule = (remaining: number): void => {
			const waitMs = Math.min(remaining, MAX_TIMER_DELAY_MS);
			this.livenessTimer = setTimeout(() => {
				this.livenessTimer = null;
				if (remaining > waitMs) {
					schedule(remaining - waitMs);
				} else {
					this.sendLivenessPing();
				}
			}, waitMs);
		};
		schedule(delayMs);
	}

	private sendLivenessPing(): void {
		const ws = this.ws;
		if (!ws || ws.readyState !== WebSocket.OPEN || this.intentionalDisconnect)
			return;

		const id = this.pending.nextId();
		let bytes: Uint8Array;
		try {
			bytes = this.wire.encode({ type: "Ping" }, id).bytes;
		} catch (err) {
			this.emit("error", err);
			ws.close();
			return;
		}

		this.livenessPingId = id;
		try {
			this.send(bytes);
		} catch {
			ws.close();
			return;
		}

		this.livenessTimer = setTimeout(() => {
			this.livenessTimer = null;
			if (this.livenessPingId !== id) return;
			this.livenessPingId = null;
			ws.close();
		}, this.livenessTimeoutMs);
	}

	dispatch(
		msg: OutboundRequest,
		responseTableIndex?: number,
	): Promise<OkResponse> {
		return this.dispatchWithRetry(msg, 0, responseTableIndex);
	}

	/**
	 * Dispatch a request without any automatic retry. Used by action calls,
	 * which must never be retried because the first attempt may have executed.
	 */
	dispatchNoRetry(msg: OutboundRequest): Promise<OkResponse> {
		return this.sendRequest(msg).result;
	}

	/** Encode a one-way outbound message (ActionReply). The request id is unused. */
	encodeOutbound(msg: OutboundRequest): Uint8Array {
		return this.wire.encode(msg, 0).bytes;
	}

	private sendRequest(
		msg: OutboundRequest,
		responseTableIndex?: number,
	): {
		id: number;
		result: Promise<OkResponse>;
		debugType: string;
	} {
		const id = this.pending.nextId();
		const encoded = this.wire.encode(msg, id, responseTableIndex);

		if (this.options.debug) {
			console.log(
				`[SDK] >> ${encoded.debugMessage.type} (id=${id}):`,
				JSON.stringify(encoded.debugMessage),
			);
		}

		const result = this.pending.register(id, encoded.context);
		const isNamespaceSetup =
			msg.type === "StoreSetNamespace" || msg.type === "PresenceSetNamespace";
		if (!isNamespaceSetup && this.currentStatus !== "connected") {
			// The server session does not exist yet (socket opening, namespace
			// handshake running, or reconnect pending). Sending now makes the
			// server answer SESSION_NOT_READY; surface a retryable network error
			// instead so callers retry once the session is live.
			this.pending.reject(
				id,
				new ZyncBaseError("Connection is not ready", {
					code: ErrorCodes.CONNECTION_FAILED,
					category: "network",
					retryable: true,
				}),
			);
			return { id, result, debugType: encoded.debugMessage.type };
		}
		try {
			this.send(encoded.bytes);
		} catch (err) {
			this.pending.reject(id, err);
		}

		return { id, result, debugType: encoded.debugMessage.type };
	}

	private async dispatchWithRetry(
		msg: OutboundRequest,
		attempt: number,
		responseTableIndex?: number,
	): Promise<OkResponse> {
		const { result, debugType } = this.sendRequest(msg, responseTableIndex);

		try {
			return await result;
		} catch (err) {
			if (this.intentionalDisconnect) throw err;
			return this.handleRetryOrThrow(
				msg,
				attempt,
				err,
				debugType,
				responseTableIndex,
			);
		}
	}

	private async handleRetryOrThrow(
		msg: OutboundRequest,
		attempt: number,
		err: unknown,
		debugType: string,
		responseTableIndex?: number,
	): Promise<OkResponse> {
		if (!this.retryPolicy.shouldRetry(err, attempt)) throw err;

		const delay = this.retryPolicy.getDelay(err, attempt);
		if (this.options.debug) {
			console.log(
				`[SDK] Retrying ${debugType} in ${delay}ms (attempt ${attempt + 1})`,
			);
		}
		await sleep(delay);
		if (this.intentionalDisconnect) throw err;
		return this.dispatchWithRetry(msg, attempt + 1, responseTableIndex);
	}

	authRefresh(token: string): Promise<void> {
		return this.dispatch({ type: "AuthRefresh" as const, token }).then(
			() => {},
		);
	}

	onMessage(handler: MessageHandler): void {
		this.messageHandler = handler;
	}

	onDelta(handler: DeltaHandler): void {
		this.deltaHandler = handler;
	}

	onPresenceBroadcast(handler: PresenceBroadcastHandler): void {
		this.presenceBroadcastHandler = handler;
	}

	onActionForward(handler: (msg: ActionForward) => void): void {
		this.actionForwardHandler = handler;
	}

	disconnect(): void {
		this.intentionalDisconnect = true;
		this.stopLiveness();
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
		this.emit("disconnected", {
			code: ErrorCodes.CLIENT_DISCONNECT,
			reason: err.message,
			category: err.category,
			retryable: false,
			attempt: this.reconnectAttempt,
		} satisfies DisconnectDetail);
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
		this.stopLiveness();
		const closeError = socketCloseError(code, reason);
		const messageError = this.pendingDisconnectError;
		const err =
			closeError.code === ErrorCodes.CONNECTION_FAILED
				? (messageError ?? closeError)
				: messageError?.code === closeError.code
					? messageError
					: closeError;
		this.pendingDisconnectError = null;
		this.rejectSchemaSync(err);
		this.pending.rejectAll(err);

		const willRetry = this.willRetryAfter(err);
		// Established connections and terminal closes surface a `disconnected`
		// event; a failed reconnect attempt that will simply be retried does not.
		if (this.currentStatus === "connected" || !willRetry) {
			this.setStatus("disconnected", { error: err });
			this.emit("disconnected", this.disconnectDetail(err, willRetry));
		}
		if (willRetry) {
			this.scheduleReconnect(err);
			return;
		}
		this.emit("error", err);
	}

	private willRetryAfter(err: ZyncBaseError): boolean {
		return (
			!this.intentionalDisconnect &&
			err.retryable &&
			(this.options.reconnect ?? true) &&
			this.reconnectAttempt < (this.options.maxReconnectAttempts ?? Infinity)
		);
	}

	private disconnectDetail(
		err: ZyncBaseError,
		willRetry: boolean,
	): DisconnectDetail {
		const attemptsExhausted =
			err.retryable &&
			(this.options.reconnect ?? true) &&
			this.reconnectAttempt >= (this.options.maxReconnectAttempts ?? Infinity);
		return {
			code: attemptsExhausted ? ErrorCodes.RETRIES_EXHAUSTED : err.code,
			reason: err.message,
			category: err.category,
			retryable: willRetry,
			attempt: this.reconnectAttempt,
		};
	}

	private scheduleReconnect(error?: ZyncBaseError): void {
		const maxAttempts = this.options.maxReconnectAttempts ?? Infinity;
		if (this.reconnectAttempt >= maxAttempts) {
			this.setStatus("disconnected", { error });
			this.emit("disconnected", {
				code: ErrorCodes.RETRIES_EXHAUSTED,
				reason: error?.message ?? "Retries exhausted",
				category: error?.category ?? "network",
				retryable: false,
				attempt: this.reconnectAttempt,
			} satisfies DisconnectDetail);
			return;
		}

		const delay = this._computeBackoffDelay(this.reconnectAttempt);
		this.reconnectAttempt++;

		// Overlapping failure paths can both request a reconnect; keep one timer.
		if (this.reconnectTimer !== null) clearTimeout(this.reconnectTimer);

		this.setStatus("reconnecting", {
			retryCount: this.reconnectAttempt,
			retryIn: delay,
			error,
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
		// Snapshot: a handler may unsubscribe itself (or others) mid-emission.
		for (const handler of [...handlers]) {
			handler(...args);
		}
	}

	private setStatus(
		status: ConnectionStatus,
		detail?: Partial<StatusDetail>,
	): void {
		const previousStatus = this.currentStatus;
		this.currentStatus = status;

		const fullDetail: StatusDetail = {
			previousStatus,
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
		const arr = data instanceof ArrayBuffer ? new Uint8Array(data) : data;
		try {
			// A frame may carry one or more complete messages (the server
			// concatenates per-connection deltas); dispatch each in order.
			for (const msg of this.wire.decodeMulti(arr)) {
				const pending = this.dispatchInbound(msg);
				if (pending) await pending;
			}
		} catch (err) {
			if (this.options.debug) {
				console.error("[SDK] Error processing inbound frame:", err);
			}
		}
	}

	private dispatchInbound(msg: InboundMessage): Promise<void> | undefined {
		const id = "id" in msg ? msg.id : "push";
		if (this.options.debug) {
			console.log(`[SDK] << ${msg.type} (id=${id}):`, JSON.stringify(msg));
		}

		switch (msg.type) {
			case "SchemaSync":
				return this.handleSchemaSync(msg);
			case "ok":
				if (this.handleOkResponse(msg)) return;
				break;
			case "error":
				if (this.handleErrorResponse(msg)) return;
				if (msg.code === ErrorCodes.TOKEN_EXPIRED) {
					this.handleTokenExpired();
				}
				break;
			case "ServerDisconnect":
				this.pendingDisconnectError = serverDisconnectError(
					msg.code,
					msg.message,
				);
				break;
			case "StoreDelta":
				this.handleDeltaPush(msg);
				break;
			case "PresenceBroadcast":
			case "SharedStateBroadcast":
				this.presenceBroadcastHandler?.(msg);
				break;
			case "ActionForward":
				this.actionForwardHandler?.(msg);
				break;
		}

		this.messageHandler?.(msg);
	}

	private handleOkResponse(ok: OkResponse): boolean {
		if (this.livenessPingId === ok.id) {
			this.noteCorrelatedResponse(ok.id);
			return true;
		}
		const context = this.pending.context(ok.id);
		if (!context) return false;
		this.noteCorrelatedResponse(ok.id);

		try {
			this.pending.resolve(ok.id, this.wire.decodeOkResponse(ok, context));
		} catch (err) {
			this.pending.reject(ok.id, err);
		}
		return false;
	}

	private handleErrorResponse(err: ErrorResponse): boolean {
		if (err.id === undefined) return false;
		if (this.livenessPingId === err.id) {
			this.noteCorrelatedResponse(err.id);
			return true;
		}
		if (this.pending.reject(err.id, errorResponseToError(err))) {
			this.noteCorrelatedResponse(err.id);
		}
		return false;
	}

	private noteCorrelatedResponse(id: number): boolean {
		const isPingResponse = this.livenessPingId === id;
		if (!isPingResponse && this.pending.context(id) === undefined) return false;
		if (!this.livenessEnabled) return isPingResponse;
		if (this.livenessTimer !== null) clearTimeout(this.livenessTimer);
		this.livenessTimer = null;
		this.livenessPingId = null;
		this.scheduleLivenessProbe(this.livenessIntervalMs);
		return isPingResponse;
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

	private handleTokenExpired(): void {
		const auth = this.options.auth;
		if (auth && "tokenProvider" in auth) {
			if (this._refreshInFlight) {
				return;
			}
			this._refreshInFlight = auth
				.tokenProvider()
				.then((newToken) => this.authRefresh(newToken))
				.catch((err) => {
					if (this.options.debug) {
						console.error("[SDK] Auto-refresh failed:", err);
					}
					this.emit("tokenExpired");
				})
				.finally(() => {
					this._refreshInFlight = null;
				});
		} else {
			this.emit("tokenExpired");
		}
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

function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}
