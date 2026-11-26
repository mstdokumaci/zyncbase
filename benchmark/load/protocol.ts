import * as fs from "node:fs";
import { decode, decodeMulti, encode } from "@msgpack/msgpack";
import { createTestJwt } from "../../tests/e2e/src/harness";

export type ComboCorpus = {
	schemaSync: string;
	setup: {
		storeNamespace: string;
		storeSubscribes: Record<string, Record<"A" | "B", string>>;
		presenceNamespaces: Record<string, string>;
		presenceSubscribe: string;
		presenceSubscribeShared: string;
	};
	storeCreates: Record<string, string>;
	storeUpdates: Record<string, string>;
	presenceUser: Record<string, string[]>;
	presenceShared: Record<string, string[]>;
};

export function loadComboCorpus(file: string): ComboCorpus {
	return JSON.parse(fs.readFileSync(file, "utf8")) as ComboCorpus;
}

export function fromBase64(value: string): Uint8Array {
	return new Uint8Array(Buffer.from(value, "base64"));
}

/** First message type in a single-message server frame, if decodable. */
export function frameType(bytes: Uint8Array | null): number | undefined {
	if (!bytes) return undefined;
	try {
		return messageType(decode(bytes));
	} catch {
		return undefined;
	}
}

/**
 * Rewrites the namespace in a captured namespace frame. Shards reuse the same
 * payload frames behind different namespaces, so only these two setup frames
 * differ per shard.
 */
export function rebaseNamespace(template: string, namespace: string): string {
	const message = decode(fromBase64(template)) as Record<string, unknown>;
	message.namespace = namespace;
	return Buffer.from(encode(message)).toString("base64");
}

/**
 * Gives a captured store write a shard-specific document id. The doc id is a
 * 16-byte binary at `path[1]`; XOR-ing its last byte keeps create/update pairs
 * aligned and avoids the global primary-key collision when the same corpus is
 * replayed in parallel namespaces.
 */
export function rebaseDocId(template: string, shard: number): string {
	if (shard === 0) return template;
	const message = decode(fromBase64(template)) as { path?: unknown };
	const path = message.path;
	if (!Array.isArray(path) || path.length < 2) {
		throw new Error("store frame is missing path");
	}
	const encodedId = path[1];
	if (!(encodedId instanceof Uint8Array) || encodedId.length === 0) {
		throw new Error("store frame is missing document id");
	}
	const id = encodedId.slice();
	id[id.length - 1] ^= shard;
	path[1] = id;
	return Buffer.from(encode(message)).toString("base64");
}

export function makeJwt(secret: string, subject: string): string {
	return createTestJwt(secret, subject);
}

async function acquireTicket(
	host: string,
	port: number,
	jwt: string,
): Promise<string> {
	let lastError: unknown;
	for (let attempt = 0; attempt < 3; attempt++) {
		try {
			const response = await fetch(`http://${host}:${port}/auth/ticket`, {
				method: "POST",
				headers: { Authorization: `Bearer ${jwt}` },
			});
			if (!response.ok) {
				throw new Error(`ticket request failed: ${response.status}`);
			}
			const body = (await response.json()) as { ticket?: string };
			if (!body.ticket) throw new Error("ticket response missing ticket");
			return body.ticket;
		} catch (error) {
			lastError = error;
			if (attempt < 2) await Bun.sleep(20);
		}
	}
	throw lastError;
}

type Waiter = {
	frames: number;
	resolve: () => void;
	reject: (error: Error) => void;
	timer: ReturnType<typeof setTimeout>;
};

type AckWaiter = {
	acks: number;
	resolve: () => void;
	reject: (error: Error) => void;
	timer: ReturnType<typeof setTimeout>;
};

type MessageWaiter = {
	messages: number;
	resolve: () => void;
	reject: (error: Error) => void;
	timer: ReturnType<typeof setTimeout>;
};

function bytesOf(data: unknown): Uint8Array | null {
	if (data instanceof ArrayBuffer) return new Uint8Array(data);
	if (data instanceof Uint8Array) return data;
	return null;
}

function messageId(value: unknown): number | undefined {
	if (Array.isArray(value)) {
		return typeof value[1] === "number" ? value[1] : undefined;
	}
	if (value instanceof Map) {
		const id = value.get("id");
		return typeof id === "number" ? id : undefined;
	}
	if (value && typeof value === "object") {
		const id = (value as Record<string, unknown>).id;
		return typeof id === "number" ? id : undefined;
	}
	return undefined;
}

function messageType(value: unknown): number | undefined {
	if (Array.isArray(value)) {
		return typeof value[0] === "number" ? value[0] : undefined;
	}
	if (value && typeof value === "object") {
		const type = (value as Record<string, unknown>).type;
		return typeof type === "number" ? type : undefined;
	}
	return undefined;
}

export type OpenTiming = {
	ticketMs?: number;
	wsMs?: number;
};

export class RawConnection {
	readonly ws: WebSocket;
	frames = 0;
	messages = 0;
	errors = 0;
	acks = 0;
	bytes = 0;
	closed = false;
	closeCode = 0;
	firstFrame: Uint8Array | null = null;
	lastFrame: Uint8Array | null = null;
	messageTimes = new Map<number, number>();
	messageFrames = new Map<number, number>();
	private waiters: Waiter[] = [];
	private messageWaiters: MessageWaiter[] = [];
	private ackWaiters: AckWaiter[] = [];
	countMessages: boolean;
	private readonly countAcks: boolean;

	private constructor(
		ws: WebSocket,
		countMessages: boolean,
		countAcks: boolean,
	) {
		this.ws = ws;
		this.countMessages = countMessages;
		this.countAcks = countAcks;
		ws.binaryType = "arraybuffer";
		ws.onmessage = (event) => {
			const bytes = bytesOf(event.data);
			if (bytes) this.handleBytes(bytes);
		};
		ws.onclose = (event) => this.handleClose(event.code);
	}

	private handleBytes(bytes: Uint8Array): void {
		this.frames++;
		this.bytes += bytes.byteLength;
		this.firstFrame ??= bytes;
		this.lastFrame = bytes;
		if (this.countMessages || this.countAcks) {
			try {
				const at = performance.now();
				for (const message of decodeMulti(bytes)) {
					if (this.countMessages) this.recordMessage(message, at);
					if (this.countAcks && messageType(message) === 0x19) this.acks++;
				}
			} catch {
				// A partial/malformed frame is not a valid ack; leave it uncounted.
			}
		}
		this.resolveWaiters();
		this.resolveMessageWaiters();
		this.resolveAckWaiters();
	}

	private handleClose(code: number): void {
		this.closed = true;
		this.closeCode = code;
		const error = new Error(`socket closed (${code})`);
		for (const waiter of this.waiters.splice(0)) {
			clearTimeout(waiter.timer);
			waiter.reject(error);
		}
		for (const waiter of this.messageWaiters.splice(0)) {
			clearTimeout(waiter.timer);
			waiter.reject(error);
		}
		for (const waiter of this.ackWaiters.splice(0)) {
			clearTimeout(waiter.timer);
			waiter.reject(error);
		}
	}

	static async open(
		host: string,
		port: number,
		jwt: string,
		expectedSchema?: Uint8Array,
		countMessages = false,
		countAcks = false,
		timing?: OpenTiming,
	): Promise<RawConnection> {
		const ticketStart = performance.now();
		const ticket = await acquireTicket(host, port, jwt);
		if (timing) timing.ticketMs = performance.now() - ticketStart;
		const wsStart = performance.now();
		const url = new URL(`ws://${host}:${port}/v1/ws`);
		url.searchParams.set("ticket", ticket);
		const ws = new WebSocket(url.toString());
		const conn = new RawConnection(ws, countMessages, countAcks);
		await conn.waitFor(1);
		if (timing) timing.wsMs = performance.now() - wsStart;
		if (expectedSchema && conn.firstFrame) {
			if (!buffersEqual(conn.firstFrame, expectedSchema)) {
				conn.close();
				throw new Error("server SchemaSync differs from the corpus");
			}
		}
		return conn;
	}

	waitFor(frames: number, timeoutMs = 20_000): Promise<void> {
		if (this.frames >= frames) return Promise.resolve();
		if (this.closed) return Promise.reject(new Error("socket is closed"));
		return new Promise((resolve, reject) => {
			const timer = setTimeout(() => {
				this.waiters = this.waiters.filter((waiter) => waiter.timer !== timer);
				reject(new Error(`timed out waiting for frame ${frames}`));
			}, timeoutMs);
			this.waiters.push({ frames, resolve, reject, timer });
		});
	}

	waitForMessages(messages: number, timeoutMs = 20_000): Promise<void> {
		if (this.messages >= messages) return Promise.resolve();
		if (this.closed) return Promise.reject(new Error("socket is closed"));
		return new Promise((resolve, reject) => {
			const timer = setTimeout(() => {
				this.messageWaiters = this.messageWaiters.filter(
					(waiter) => waiter.timer !== timer,
				);
				reject(new Error(`timed out waiting for message ${messages}`));
			}, timeoutMs);
			this.messageWaiters.push({ messages, resolve, reject, timer });
		});
	}

	waitForAcks(acks: number, timeoutMs = 20_000): Promise<void> {
		if (this.acks >= acks) return Promise.resolve();
		if (this.closed) return Promise.reject(new Error("socket is closed"));
		return new Promise((resolve, reject) => {
			const timer = setTimeout(() => {
				this.ackWaiters = this.ackWaiters.filter(
					(waiter) => waiter.timer !== timer,
				);
				reject(new Error(`timed out waiting for ${acks} acks`));
			}, timeoutMs);
			this.ackWaiters.push({ acks, resolve, reject, timer });
		});
	}

	send(bytes: Uint8Array): void {
		this.ws.send(bytes);
	}

	sendBase64(value: string): void {
		this.send(fromBase64(value));
	}

	close(): void {
		this.ws.close();
	}

	private recordMessage(message: unknown, at: number): void {
		this.messages++;
		if (messageType(message) === 0x01) this.errors++;
		const id = messageId(message);
		if (id === undefined) return;
		this.messageTimes.set(id, at);
		this.messageFrames.set(id, this.frames);
	}

	private resolveWaiters(): void {
		const ready = this.waiters.filter((waiter) => this.frames >= waiter.frames);
		if (ready.length === 0) return;
		this.waiters = this.waiters.filter((waiter) => this.frames < waiter.frames);
		for (const waiter of ready) {
			clearTimeout(waiter.timer);
			waiter.resolve();
		}
	}

	private resolveMessageWaiters(): void {
		const ready = this.messageWaiters.filter(
			(waiter) => this.messages >= waiter.messages,
		);
		if (ready.length === 0) return;
		this.messageWaiters = this.messageWaiters.filter(
			(waiter) => this.messages < waiter.messages,
		);
		for (const waiter of ready) {
			clearTimeout(waiter.timer);
			waiter.resolve();
		}
	}

	private resolveAckWaiters(): void {
		const ready = this.ackWaiters.filter((waiter) => this.acks >= waiter.acks);
		if (ready.length === 0) return;
		this.ackWaiters = this.ackWaiters.filter(
			(waiter) => this.acks < waiter.acks,
		);
		for (const waiter of ready) {
			clearTimeout(waiter.timer);
			waiter.resolve();
		}
	}
}

function buffersEqual(a: Uint8Array, b: Uint8Array): boolean {
	if (a.byteLength !== b.byteLength) return false;
	for (let i = 0; i < a.byteLength; i++) if (a[i] !== b[i]) return false;
	return true;
}
