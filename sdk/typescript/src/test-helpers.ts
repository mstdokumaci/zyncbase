import { encode } from "@msgpack/msgpack";
import { ConnectionManager } from "./connection";
import type { ClientOptions } from "./types";

/** Encode a message to an exact-size ArrayBuffer. */
export function encodeToBuffer(msg: unknown): ArrayBuffer {
	const encoded = encode(msg);
	return encoded.buffer.slice(
		encoded.byteOffset,
		encoded.byteOffset + encoded.byteLength,
	) as ArrayBuffer;
}

/** Minimal mock WebSocket for unit testing. */
export class MockWebSocket {
	static OPEN = 1;
	static CLOSING = 2;
	static CLOSED = 3;

	readyState = MockWebSocket.OPEN;
	binaryType: string = "";
	sentMessages: Uint8Array[] = [];

	onopen: ((event: Record<string, unknown>) => void) | null = null;
	onclose: ((event: Record<string, unknown>) => void) | null = null;
	onerror: ((event: Record<string, unknown>) => void) | null = null;
	onmessage: ((event: Record<string, unknown>) => void) | null = null;

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

	onopen: (() => void) | null = null;
	onclose: ((event: unknown) => void) | null = null;
	onerror: ((event: unknown) => void) | null = null;
	onmessage: ((event: unknown) => void) | null = null;

	constructor(_url: string) {
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

/** Patch global WebSocket to return the given mock instance. */
export function installMockWs(mockWs: MockWebSocket) {
	function wsFactory() {
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

/** Default options for test managers. */
export const defaultOptions: ClientOptions = {
	url: "ws://localhost:3000",
	reconnect: false,
};

/** Create a manager with a patched mock WebSocket and pre-seeded schema. */
export function makeManager(options?: Partial<ClientOptions>): {
	manager: ConnectionManager;
	mockWs: MockWebSocket;
} {
	const mockWs = new MockWebSocket();
	installMockWs(mockWs);
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

/** Full connect flow: open + namespace ok. */
export async function connectManager(
	manager: ConnectionManager,
	mockWs: MockWebSocket,
): Promise<void> {
	const p = manager.connect();
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
