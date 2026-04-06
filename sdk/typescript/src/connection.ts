// Connection Manager
import { encode, decode } from "@msgpack/msgpack";
import { ZyncBaseError, ErrorCodes } from "./errors";
import type {
  ClientOptions,
  LifecycleEvent,
  InboundMessage,
  OkResponse,
  ErrorResponse,
  StoreDelta,
  StatusDetail,
} from "./types";

type EventHandler = (...args: any[]) => void;
type MessageHandler = (msg: InboundMessage) => void;
type DeltaHandler = (delta: StoreDelta) => void;

type ConnectionStatus = "connecting" | "connected" | "reconnecting" | "disconnected";

export class ConnectionManager {
  private options: ClientOptions;
  private ws: WebSocket | null = null;

  // msg_id counter and pending queue
  private nextMsgId = 1;
  private pendingQueue: Map<number, { resolve: (value: any) => void; reject: (reason: any) => void }> = new Map();

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

  constructor(options: ClientOptions) {
    this.options = options;
    this.storeNamespace = options.storeNamespace ?? "public";
    this.presenceNamespace = options.presenceNamespace ?? this.storeNamespace;
  }

  getStoreNamespace(): string { return this.storeNamespace; }
  setStoreNamespace(ns: string) { this.storeNamespace = ns; }
  getPresenceNamespace(): string { return this.presenceNamespace; }
  setPresenceNamespace(ns: string) { this.presenceNamespace = ns; }

  /** Open the WebSocket and resolve when connected. */
  connect(): Promise<void> {
    this.intentionalDisconnect = false;
    this.setStatus("connecting");

    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.options.url);
      ws.binaryType = "arraybuffer";
      this.ws = ws;

      ws.onopen = () => {
        this.reconnectAttempt = 0;
        this.setStatus("connected");
        this.emit("connected");
        resolve();
      };

      ws.onerror = (_event) => {
        const err = new ZyncBaseError("WebSocket error", {
          code: ErrorCodes.CONNECTION_FAILED,
          category: "network",
          retryable: true,
        });
        this.emit("error", err);
        reject(err);
      };

      ws.onclose = (_event) => {
        // Reject all pending requests
        for (const [_id, { reject: rej }] of this.pendingQueue) {
          rej(new ZyncBaseError("Connection closed", {
            code: ErrorCodes.CONNECTION_FAILED,
            category: "network",
            retryable: true,
          }));
        }
        this.pendingQueue.clear();

        if (!this.intentionalDisconnect && (this.options.reconnect ?? true)) {
          this._scheduleReconnect();
        } else {
          this.setStatus("disconnected");
          this.emit("disconnected", _event.code, _event.reason);
        }
      };

      ws.onmessage = (event) => {
        this._handleRawMessage(event.data);
      };
    });
  }

  /** Compute the backoff delay for a given attempt number. Exported for testing. */
  _computeBackoffDelay(attempt: number): number {
    const base = this.options.reconnectDelay ?? 1000;
    const maxDelay = this.options.maxReconnectDelay ?? 30_000;
    const preCap = base * Math.pow(2, attempt);
    const jitter = (this.options.reconnectJitter ?? true) 
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

    this.setStatus("reconnecting", { retryCount: this.reconnectAttempt, retryIn: delay });
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
  dispatch(msg: Record<string, any>): Promise<OkResponse> {
    const id = this.nextMsgId++;
    
    const msgWithId: any = { ...msg, id };
    if (!msgWithId.namespace) {
      if (msgWithId.type?.startsWith("Store")) {
        msgWithId.namespace = this.storeNamespace;
      } else if (msgWithId.type?.startsWith("Presence")) {
        msgWithId.namespace = this.presenceNamespace;
      }
    }

    console.log(`[SDK] >> ${msgWithId.type} (id=${id}):`, JSON.stringify(msgWithId));
    const encoded = encode(msgWithId) as Uint8Array;

    return new Promise((resolve, reject) => {
      this.pendingQueue.set(id, { resolve, reject });
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
    for (const [, { reject: rej }] of this.pendingQueue) {
      rej(new ZyncBaseError("Disconnected", {
        code: ErrorCodes.CONNECTION_FAILED,
        category: "network",
        retryable: false,
      }));
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
    this.eventListeners.get(event)!.push(handler);
  }

  /** Remove a lifecycle event listener. */
  off(event: LifecycleEvent, handler: EventHandler): void {
    const handlers = this.eventListeners.get(event);
    if (handlers) {
      const idx = handlers.indexOf(handler);
      if (idx !== -1) handlers.splice(idx, 1);
    }
  }

  private emit(event: LifecycleEvent, ...args: any[]): void {
    const handlers = this.eventListeners.get(event);
    if (handlers) {
      for (const h of handlers) {
        h(...args);
      }
    }
  }

  private setStatus(status: ConnectionStatus, detail?: Partial<StatusDetail>): void {
    const previousStatus = this.status as LifecycleEvent;
    this.status = status;
    
    const fullDetail: StatusDetail = {
      previousStatus: previousStatus === "disconnected" && status === "connecting" ? null : previousStatus,
      retryCount: detail?.retryCount ?? this.reconnectAttempt,
      retryIn: detail?.retryIn ?? null,
      error: detail?.error,
    };

    this.emit("statusChange", status, fullDetail);
  }

  private _handleRawMessage(data: ArrayBuffer | Uint8Array): void {
    let msg: InboundMessage;
    try {
      msg = decode(data instanceof ArrayBuffer ? new Uint8Array(data) : data) as InboundMessage;
    } catch {
      // Malformed frame — discard silently
      return;
    }

    if (!msg || typeof msg !== "object" || !("type" in msg)) {
      return;
    }

    const type = (msg as any).type as string;
    console.log(`[SDK] << ${type} (id=${(msg as any).id || "push"}):`, JSON.stringify(msg));

    if (type === "ok") {
      const ok = msg as OkResponse;
      const entry = this.pendingQueue.get(ok.id);
      if (entry) {
        this.pendingQueue.delete(ok.id);
        entry.resolve(ok);
      }
      // unknown id → discard silently
    } else if (type === "error") {
      const err = msg as ErrorResponse;
      const entry = this.pendingQueue.get(err.id);
      if (entry) {
        this.pendingQueue.delete(err.id);
        entry.reject(ZyncBaseError.fromServerResponse(err));
      }
      // unknown id → discard silently
    } else if (type === "StoreDelta") {
      const delta = msg as StoreDelta;
      if (this.deltaHandler) {
        this.deltaHandler(delta);
      }
    }
    // Any other type → discard silently

    // Also forward to generic message handler if registered
    if (this.messageHandler) {
      this.messageHandler(msg);
    }
  }
}
