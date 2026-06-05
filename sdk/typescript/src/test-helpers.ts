import { encode } from "@msgpack/msgpack";
import { ConnectionManager } from "./connection";
import type { AuthConfig, ClientOptions } from "./types";

/** Encode a message to an exact-size ArrayBuffer. */
export function encodeToBuffer(msg: unknown): ArrayBuffer {
	const encoded = encode(msg);
	return encoded.buffer.slice(
		encoded.byteOffset,
		encoded.byteOffset + encoded.byteLength,
	) as ArrayBuffer;
}

/** Mock WebSocket that captures the URL for ticket assertion. */
export class MockWebSocket {
	static OPEN = 1;
	static CLOSING = 2;
	static CLOSED = 3;

	readyState = MockWebSocket.OPEN;
	binaryType: string = "";
	sentMessages: Uint8Array[] = [];
	url: string;

	onopen: ((event: Record<string, unknown>) => void) | null = null;
	onclose: ((event: Record<string, unknown>) => void) | null = null;
	onerror: ((event: Record<string, unknown>) => void) | null = null;
	onmessage: ((event: Record<string, unknown>) => void) | null = null;

	constructor(url = "") {
		this.url = url;
	}

	send(data: Uint8Array | ArrayBuffer) {
		const bytes = data instanceof ArrayBuffer ? new Uint8Array(data) : data;
		this.sentMessages.push(bytes);
	}

	close() {
		this.readyState = MockWebSocket.CLOSED;
	}

	triggerOpen() {
		this.onopen?.({});
	}

	triggerMessage(data: ArrayBuffer) {
		this.onmessage?.({ data });
	}

	triggerClose(code = 1000, reason = "") {
		this.readyState = MockWebSocket.CLOSED;
		this.onclose?.({ code, reason });
	}

	triggerError() {
		this.onerror?.({});
	}
}

/** MockWebSocket that auto-triggers open and auto-responds to StoreSetNamespace. */
export class AutoMockWebSocket {
	static readonly OPEN = 1;
	static readonly CLOSED = 3;

	binaryType: string = "arraybuffer";
	readyState: number = 1;
	sentMessages: Uint8Array[] = [];
	url: string;

	onopen: (() => void) | null = null;
	onclose: ((event: unknown) => void) | null = null;
	onerror: ((event: unknown) => void) | null = null;
	onmessage: ((event: unknown) => void) | null = null;

	constructor(url: string) {
		this.url = url;
		Promise.resolve().then(() => {
			if (this.onopen) this.onopen();
			this._autoRespondOk(1);
		});
	}

	private _autoRespondOk(id: number): void {
		const encoded = encode({ type: "ok", id }) as Uint8Array;
		const buf = encoded.buffer.slice(
			encoded.byteOffset,
			encoded.byteOffset + encoded.byteLength,
		) as ArrayBuffer;
		if (this.onmessage) {
			this.onmessage({ data: buf });
		}
	}

	send(data: ArrayBuffer | Uint8Array): void {
		const bytes = data instanceof ArrayBuffer ? new Uint8Array(data) : data;
		this.sentMessages.push(bytes);
	}

	close(): void {
		this.readyState = 3;
	}
}

const originalWebSocket = globalThis.WebSocket;
const originalFetch = globalThis.fetch;

/** Patch global WebSocket to return the given mock instance. */
export function installMockWs(mockWs: MockWebSocket) {
	function wsFactory(url: string) {
		mockWs.url = url;
		return mockWs;
	}
	(globalThis as Record<string, unknown>).WebSocket = Object.assign(wsFactory, {
		OPEN: MockWebSocket.OPEN,
	});
}

/** Patch global WebSocket to use the AutoMockWebSocket class. */
export function installAutoMockWs() {
	(globalThis as Record<string, unknown>).WebSocket = AutoMockWebSocket;
}

/** Restore the original WebSocket. */
export function restoreWebSocket() {
	(globalThis as Record<string, unknown>).WebSocket = originalWebSocket;
}

export interface FetchTicketOptions {
	ticket?: string;
	expiresAt?: number;
	status?: number;
	body?: Record<string, unknown>;
}

/** Install a mock fetch that responds to POST /auth/ticket. */
export function installMockFetchTicket(options: FetchTicketOptions = {}) {
	const ticket = options.ticket ?? "zyc_tk_test_ticket_123";
	const expiresAt = options.expiresAt ?? Math.floor(Date.now() / 1000) + 60;
	const status = options.status ?? 200;
	const body = options.body ?? JSON.stringify({ ticket, expiresAt });

	(globalThis as Record<string, unknown>).fetch = async (
		input: RequestInfo | URL,
		init?: RequestInit,
	) => {
		const url = typeof input === "string" ? input : input.toString();
		if (url.endsWith("/auth/ticket") && init?.method === "POST") {
			return new Response(body, {
				status,
				headers: { "Content-Type": "application/json" },
			});
		}
		return originalFetch(input, init);
	};
}

/** Restore the original fetch. */
export function restoreFetch() {
	(globalThis as Record<string, unknown>).fetch = originalFetch;
}

/** Default options for test managers. */
export const defaultOptions: ClientOptions = {
	url: "ws://localhost:3000",
	auth: { anonymous: true } as AuthConfig,
	reconnect: false,
};

/** Create a manager with a patched mock WebSocket and pre-seeded schema. */
export function makeManager(options?: Partial<ClientOptions>): {
	manager: ConnectionManager;
	mockWs: MockWebSocket;
} {
	const mockWs = new MockWebSocket("");
	installMockWs(mockWs);
	installMockFetchTicket();
	const opts: ClientOptions = { ...defaultOptions, ...options };
	const manager = new ConnectionManager(opts);
	manager.schemaDictionary.processSchemaSync({
		tables: ["a", "users", "tasks"],
		fields: [
			["b", "c"],
			["name", "age"],
			["title", "meta"],
		],
		fieldFlags: [
			[0b00, 0b00],
			[0b00, 0b00],
			[0b00, 0b00],
		],
	});
	return { manager, mockWs };
}

/** Trigger the ok response for the initial StoreSetNamespace (id=1). */
export function triggerNamespaceOk(mockWs: MockWebSocket) {
	mockWs.triggerMessage(encodeToBuffer({ type: "ok", id: 1 }));
}

/** Full connect flow: acquire ticket + open + namespace ok. */
export async function connectManager(
	manager: ConnectionManager,
	mockWs: MockWebSocket,
): Promise<void> {
	const p = manager.connect();
	await new Promise((r) => setTimeout(r, 0));
	mockWs.triggerOpen();
	triggerNamespaceOk(mockWs);
	await p;
}

/** Trigger a SchemaSync message with a default schema. */
export function triggerSchemaSync(mockWs: MockWebSocket) {
	mockWs.triggerMessage(
		encodeToBuffer({
			type: "SchemaSync",
			tables: ["users"],
			fields: [["id", "namespace_id", "name", "created_at", "updated_at"]],
			fieldFlags: [[0b11, 0b01, 0b00, 0b01, 0b01]],
		}),
	);
}
