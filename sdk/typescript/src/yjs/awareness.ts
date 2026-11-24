import { Awareness, applyAwarenessUpdate } from "y-protocols/awareness";
import type { Doc } from "yjs";

import type { Presence, PresenceEntry } from "../types.js";

const LOCAL_ORIGIN = "local";
const REMOTE_ORIGIN = Symbol("zyncbase-presence-awareness");
const MAX_CLIENT_ID = 0xffff_ffff;

/** Bridges one Yjs Awareness instance onto the connection's presence namespace. */
export interface AwarenessPresence<P = never> {
	readonly presence: Presence<P>;
	readonly presenceNamespace: string;
}

export interface ZyncBaseYjsAwarenessOptions<P = never> {
	/** Presence namespace for this document. Must match `client.presenceNamespace`. */
	namespace: string;
	/** Existing awareness instance. Default: a new instance attached to the provider's doc. */
	instance?: Awareness;
	/** Presence user field carrying `doc.clientID`. Default: `yjsClientId`. */
	clientIdField?: string;
	/** Local awareness state → presence user patch. Default: identity. */
	toPresence?: (
		state: Record<string, unknown>,
	) => Record<string, unknown> | null;
	/** Presence user payload without the client id → remote awareness state. Default: null leaves removed. */
	fromPresence?: (
		data: Record<string, unknown>,
		entry: PresenceEntry<P>,
	) => Record<string, unknown> | null;
}

interface BridgeConfig<P> {
	doc: Doc;
	client: AwarenessPresence<P>;
	namespace: string;
	instance?: Awareness;
	clientIdField?: string;
	toPresence?: (
		state: Record<string, unknown>,
	) => Record<string, unknown> | null;
	fromPresence?: (
		data: Record<string, unknown>,
		entry: PresenceEntry<P>,
	) => Record<string, unknown> | null;
	onError: (error: unknown) => void;
}

const claimedClients = new WeakMap<object, object>();

/**
 * Keeps a Yjs `Awareness` instance in sync with `presence.user`.
 *
 * Presence is keyed by user, so one awareness state is represented per user:
 * multiple tabs of the same user collapse to the last writer. The presence
 * namespace is per connection, so a client can bridge one document.
 */
export class PresenceAwarenessBridge<P = never> {
	readonly awareness: Awareness;

	private readonly client: AwarenessPresence<P>;
	private readonly namespace: string;
	private readonly clientIdField: string;
	private readonly toPresence: (
		state: Record<string, unknown>,
	) => Record<string, unknown> | null;
	private readonly fromPresence: (
		data: Record<string, unknown>,
		entry: PresenceEntry<P>,
	) => Record<string, unknown> | null;
	private readonly onError: (error: unknown) => void;
	private readonly ownsAwareness: boolean;
	private readonly presenceSet: (
		data: Record<string, unknown>,
	) => Promise<void>;
	private readonly applied = new Map<number, string>();
	private lastSent: Record<string, unknown> | null = null;
	private unsubscribe: (() => Promise<void>) | null = null;
	private subscribeGeneration = 0;
	private subscribing = false;
	private started = false;
	private awarenessDestroyed = false;
	private namespaceMismatchReported = false;

	constructor(config: BridgeConfig<P>) {
		if (config.namespace.length === 0) {
			throw new TypeError("awareness.namespace must be a non-empty string");
		}
		const clientIdField = config.clientIdField ?? "yjsClientId";
		if (clientIdField.length === 0 || clientIdField.includes("__")) {
			throw new TypeError(
				"awareness.clientIdField must be a non-empty top-level presence field",
			);
		}
		if (config.client.presenceNamespace !== config.namespace) {
			throw new Error(
				`Awareness namespace "${config.namespace}" does not match the client presence namespace "${config.client.presenceNamespace}". Set createClient({ presenceNamespace }) to the document room.`,
			);
		}

		this.client = config.client;
		this.namespace = config.namespace;
		this.clientIdField = clientIdField;
		this.toPresence = config.toPresence ?? ((state) => state);
		this.fromPresence = config.fromPresence ?? ((data) => stripNulls(data));
		this.onError = config.onError;
		this.ownsAwareness = config.instance === undefined;
		this.awareness = config.instance ?? new Awareness(config.doc);
		this.presenceSet = this.client.presence.set.bind(this.client.presence) as (
			data: Record<string, unknown>,
		) => Promise<void>;
	}

	/** Starts syncing local updates and remote presence snapshots. */
	start(): void {
		if (this.started) return;
		const claimed = claimedClients.get(this.client);
		if (claimed !== undefined && claimed !== this) {
			this.onError(
				new Error(
					"Another awareness-enabled Yjs provider is active on this client",
				),
			);
			return;
		}
		claimedClients.set(this.client, this);
		this.started = true;
		this.awareness.on("update", this.handleLocalUpdate);
		this.awareness.on("destroy", this.handleAwarenessDestroy);
		this.subscribe();
		this.pushLocal();
	}

	/** Stops syncing, clears this bridge's presence fields and remote states. */
	stop(): void {
		if (!this.started) return;
		this.started = false;
		this.subscribeGeneration += 1;
		this.awareness.off("update", this.handleLocalUpdate);
		this.awareness.off("destroy", this.handleAwarenessDestroy);
		this.clearPresenceFields();
		this.clearRemoteStates();
		this.applied.clear();
		this.lastSent = null;

		const unsubscribe = this.unsubscribe;
		this.unsubscribe = null;
		if (unsubscribe !== null) void unsubscribe().catch(() => {});
		if (claimedClients.get(this.client) === this) {
			claimedClients.delete(this.client);
		}
	}

	/** Discards remote states after a transport loss without writing presence. */
	pause(): void {
		if (!this.started) return;
		this.clearRemoteStates();
		this.applied.clear();
		// The server dropped the record with the connection; the next push must
		// recreate every field.
		this.lastSent = null;
	}

	/** Re-publishes the local state after a reconnect. */
	resume(): void {
		if (!this.started) return;
		if (this.unsubscribe === null && !this.subscribing) this.subscribe();
		this.pushLocal();
	}

	/** Stops the bridge and destroys the awareness instance it created. */
	destroy(): void {
		this.stop();
		if (this.ownsAwareness && !this.awarenessDestroyed) {
			this.awareness.destroy();
		}
	}

	private subscribe(): void {
		const generation = ++this.subscribeGeneration;
		this.subscribing = true;
		this.client.presence.subscribe(this.handleSnapshot).then(
			(unsubscribe) => {
				this.subscribing = false;
				if (!this.started || generation !== this.subscribeGeneration) {
					void unsubscribe().catch(() => {});
					return;
				}
				this.unsubscribe = unsubscribe;
			},
			(error) => {
				this.subscribing = false;
				if (generation === this.subscribeGeneration) this.onError(error);
			},
		);
	}

	private handleLocalUpdate = (_changes: unknown, origin: unknown): void => {
		if (origin !== LOCAL_ORIGIN) return;
		this.pushLocal();
	};

	private handleAwarenessDestroy = (): void => {
		this.awarenessDestroyed = true;
		this.stop();
	};

	private pushLocal(): void {
		if (!this.started) return;
		if (!this.namespaceMatches()) return;

		const local = this.awareness.getLocalState() as Record<
			string,
			unknown
		> | null;
		let patch: Record<string, unknown> | null;
		try {
			patch = this.buildPatch(local);
		} catch (error) {
			this.onError(error);
			return;
		}
		if (patch === null) return;
		this.presenceSet(patch).catch(() => {
			// Presence failures are surfaced through the client's `error` event.
		});
	}

	private buildPatch(
		local: Record<string, unknown> | null,
	): Record<string, unknown> | null {
		const mapped = local === null ? null : this.toPresence(local);
		if (mapped === null) {
			if (this.lastSent === null) return null;
			const patch = nullPatch(this.lastSent);
			this.lastSent = null;
			return Object.keys(patch).length > 0 ? patch : null;
		}

		const normalized = normalizeAgainst(mapped, this.lastSent) as Record<
			string,
			unknown
		>;
		const next: Record<string, unknown> = {
			...normalized,
			[this.clientIdField]: this.awareness.clientID,
		};
		const patch: Record<string, unknown> = { ...next };
		if (this.lastSent !== null) {
			for (const key of Object.keys(this.lastSent)) {
				if (!(key in next)) patch[key] = nullify(this.lastSent[key]);
			}
		}
		this.lastSent = cloneValue(next) as Record<string, unknown>;
		return patch;
	}
	private clearPresenceFields(): void {
		if (!this.namespaceMatches()) return;
		if (this.lastSent === null) return;
		const patch = nullPatch(this.lastSent);
		this.lastSent = null;
		if (Object.keys(patch).length === 0) return;
		this.presenceSet(patch).catch(() => {});
	}

	private handleSnapshot = (entries: PresenceEntry<P>[]): void => {
		if (!this.started) return;
		if (!this.namespaceMatches()) return;

		const seen = new Set<number>();
		for (const entry of entries) {
			const clientId = this.remoteClientId(entry);
			if (clientId === null || seen.has(clientId)) continue;
			seen.add(clientId);
			this.applyEntry(clientId, entry);
		}

		for (const clientId of [...this.applied.keys()]) {
			if (!seen.has(clientId)) this.removeRemoteState(clientId);
		}
	};

	private remoteClientId(entry: PresenceEntry<P>): number | null {
		const raw = (entry.data as Record<string, unknown>)[this.clientIdField];
		if (
			typeof raw !== "number" ||
			!Number.isInteger(raw) ||
			raw < 0 ||
			raw > MAX_CLIENT_ID
		) {
			return null;
		}
		return raw === this.awareness.clientID ? null : raw;
	}

	private applyEntry(clientId: number, entry: PresenceEntry<P>): void {
		const data = { ...(entry.data as Record<string, unknown>) };
		delete data[this.clientIdField];
		try {
			const state = this.fromPresence(data, entry);
			if (state === null) {
				this.removeRemoteState(clientId);
			} else {
				this.applyRemoteState(clientId, state);
			}
		} catch (error) {
			this.onError(error);
		}
	}

	private applyRemoteState(
		clientId: number,
		state: Record<string, unknown>,
	): void {
		const key = stableStringify(state);
		const previous = this.applied.get(clientId);
		if (previous === key) {
			// Remote presence only pushes when someone changed, so this keeps the
			// awareness timeout fed without emitting spurious update events.
			const meta = this.awareness.meta.get(clientId);
			if (meta !== undefined) meta.lastUpdated = Date.now();
			return;
		}
		const clock = (this.awareness.meta.get(clientId)?.clock ?? 0) + 1;
		applyAwarenessUpdate(
			this.awareness,
			encodeAwarenessState(clientId, clock, state),
			REMOTE_ORIGIN,
		);
		this.applied.set(clientId, key);
	}

	private removeRemoteState(clientId: number): void {
		if (!this.applied.delete(clientId)) return;
		if (!this.awareness.states.has(clientId)) return;
		const clock = (this.awareness.meta.get(clientId)?.clock ?? 0) + 1;
		applyAwarenessUpdate(
			this.awareness,
			encodeAwarenessState(clientId, clock, null),
			REMOTE_ORIGIN,
		);
	}

	private clearRemoteStates(): void {
		for (const clientId of [...this.applied.keys()]) {
			this.removeRemoteState(clientId);
		}
	}

	private namespaceMatches(): boolean {
		if (this.client.presenceNamespace === this.namespace) {
			this.namespaceMismatchReported = false;
			return true;
		}
		if (!this.namespaceMismatchReported) {
			this.namespaceMismatchReported = true;
			this.onError(
				new Error(
					`Presence namespace changed from "${this.namespace}" to "${this.client.presenceNamespace}"; awareness sync is paused`,
				),
			);
		}
		return false;
	}
}

/**
 * Encodes a single awareness update. `y-protocols`' encoder stamps the
 * receiver's current clock, so an incoming presence state would be rejected as
 * stale; the clock must be one past the receiver's known clock.
 */
export function encodeAwarenessState(
	clientId: number,
	clock: number,
	state: Record<string, unknown> | null,
): Uint8Array {
	const json = new TextEncoder().encode(JSON.stringify(state));
	const bytes: number[] = [];
	writeVarUint(bytes, 1);
	writeVarUint(bytes, clientId);
	writeVarUint(bytes, clock);
	writeVarUint(bytes, json.length);
	for (const byte of json) bytes.push(byte);
	return Uint8Array.from(bytes);
}

function writeVarUint(out: number[], value: number): void {
	let remaining = value;
	while (remaining > 0x7f) {
		out.push((remaining % 128) | 0x80);
		remaining = Math.floor(remaining / 128);
	}
	out.push(remaining);
}

function nullPatch(state: Record<string, unknown>): Record<string, unknown> {
	const patch: Record<string, unknown> = {};
	for (const [key, value] of Object.entries(state)) {
		patch[key] = nullify(value);
	}
	return patch;
}

/** Replaces every leaf with null so the server clears the field. */
function nullify(value: unknown): unknown {
	if (Array.isArray(value)) return null;
	if (isPlainRecord(value)) {
		const out: Record<string, unknown> = {};
		for (const [key, nested] of Object.entries(value)) {
			out[key] = nullify(nested);
		}
		return out;
	}
	return null;
}

const OMIT = Symbol("omit");

/**
 * Expands `null` leaves against the previously sent shape. Presence field ids
 * are leaves, so clearing an object must clear each leaf it owned.
 */
function normalizeAgainst(
	value: unknown,
	previous: unknown,
): unknown | typeof OMIT {
	if (value === null || value === undefined) {
		return previous === undefined ? OMIT : nullify(previous);
	}
	if (!isPlainRecord(value)) return value;
	const prior = isPlainRecord(previous) ? previous : undefined;
	const out: Record<string, unknown> = {};
	for (const [key, nested] of Object.entries(value)) {
		const normalized = normalizeAgainst(nested, prior?.[key]);
		if (normalized !== OMIT) out[key] = normalized;
	}
	return out;
}

function stripNulls(value: Record<string, unknown>): Record<string, unknown> {
	const out: Record<string, unknown> = {};
	for (const [key, nested] of Object.entries(value)) {
		if (nested === null || nested === undefined) continue;
		if (isPlainRecord(nested)) {
			const child = stripNulls(nested);
			if (Object.keys(child).length > 0) out[key] = child;
		} else {
			out[key] = nested;
		}
	}
	return out;
}

function cloneValue(value: unknown): unknown {
	if (Array.isArray(value)) return value.map(cloneValue);
	if (isPlainRecord(value)) {
		const out: Record<string, unknown> = {};
		for (const [key, nested] of Object.entries(value)) {
			out[key] = cloneValue(nested);
		}
		return out;
	}
	return value;
}

function isPlainRecord(value: unknown): value is Record<string, unknown> {
	return (
		value !== null &&
		typeof value === "object" &&
		!Array.isArray(value) &&
		!(value instanceof Uint8Array)
	);
}

function stableStringify(value: unknown): string {
	if (value === null || typeof value !== "object") {
		return JSON.stringify(value) ?? "null";
	}
	if (Array.isArray(value)) {
		return `[${value.map(stableStringify).join(",")}]`;
	}
	const record = value as Record<string, unknown>;
	const keys = Object.keys(record).sort();
	return `{${keys
		.map((key) => `${JSON.stringify(key)}:${stableStringify(record[key])}`)
		.join(",")}}`;
}
