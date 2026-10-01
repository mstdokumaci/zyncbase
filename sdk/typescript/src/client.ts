// ZyncBaseClient and createClient factory

import { ActionsImpl } from "./actions.js";
import { ConnectionManager } from "./connection.js";
import { ErrorCodes, ZyncBaseError } from "./errors.js";
import { PresenceImpl } from "./presence.js";
import { StoreImpl } from "./store.js";
import { SubscriptionTracker } from "./subscriptions.js";
import type {
	Actions,
	ClientEvents,
	ClientOptions,
	ConnectionStatus,
	DisconnectDetail,
	JsonValue,
	LifecycleEvent,
	Presence,
	Store,
	StoreSubscribe,
} from "./types.js";
import { generateUUIDv7 } from "./uuid.js";

export class ZyncBaseClient {
	readonly store: Store;
	readonly presence: Presence;
	readonly actions: Actions;
	readonly utils: { id: () => string };

	private readonly conn: ConnectionManager;
	private readonly tracker: SubscriptionTracker;
	private readonly presenceImpl: PresenceImpl;
	private readonly actionsImpl: ActionsImpl;
	private readonly storeImpl: StoreImpl;
	/** Error callbacks registered via client.on('error', cb). */
	private readonly errorCallbacks: Array<(err: ZyncBaseError) => void> = [];
	/** Forwards restore failures to the error callbacks. */
	private readonly emitError: (err: ZyncBaseError) => void;
	/** Locally emitted events (`synced`, `reconnected`) — no connection-layer source. */
	private readonly localListeners = new Map<
		string,
		Array<(...args: unknown[]) => void>
	>();
	/** Whether a connection existed earlier in this process. */
	private hasConnectedOnce = false;
	/** Backoff state for retrying a failed restore. */
	private restoreAttempt = 0;
	private restoreTimer: ReturnType<typeof setTimeout> | null = null;

	constructor(options: ClientOptions) {
		this.conn = new ConnectionManager(options);
		this.tracker = new SubscriptionTracker();
		if (options.debug) this.tracker.setDebug(true);

		// Wire the delta handler: tracker dispatches StoreDelta messages
		this.conn.onDelta((delta) => {
			this.tracker.dispatch(delta);
		});

		// emitError is passed to StoreImpl for fire-and-forget error propagation.
		// It forwards to any callbacks registered via client.on('error', cb).
		const emitError = (err: ZyncBaseError) => {
			for (const cb of this.errorCallbacks) {
				cb(err);
			}
		};
		this.emitError = emitError;

		this.storeImpl = new StoreImpl(this.conn, this.tracker, emitError);
		this.store = this.storeImpl;
		this.presenceImpl = new PresenceImpl(this.conn, emitError);
		this.presence = this.presenceImpl;
		this.actionsImpl = new ActionsImpl(this.conn, emitError);
		this.actions = this.actionsImpl;

		// Presence scope resolution returns the same internal UUID used by entries.
		this.conn.onPresenceUserId((userId) => {
			this.presenceImpl.setLocalUserId(userId);
		});

		this.utils = { id: generateUUIDv7 };

		// On connect/reconnect: restore everything, then emit `synced`.
		this.conn.on("connected", () => {
			if (this.hasConnectedOnce) {
				queueMicrotask(() => this.emitLocal("reconnected"));
			}
			this.hasConnectedOnce = true;
			this.scheduleRestore();
		});
	}

	/** Current connection status, readable synchronously at any time. */
	get status(): ConnectionStatus {
		return this.conn.status;
	}

	/**
	 * Connect to the server. The promise resolves at `synced`, once replay has
	 * restored subscriptions and registrations. It rejects when recovery can no
	 * longer complete: a non-retryable handshake failure or a terminal
	 * disconnect (non-retryable) before the first `synced`.
	 */
	connect(): Promise<void> {
		return new Promise<void>((resolve, reject) => {
			let settled = false;
			const onSynced = (): void => {
				if (settled) return;
				settled = true;
				this.off("synced", onSynced);
				this.off("disconnected", onDisconnected);
				resolve();
			};
			const onDisconnected = (detail: DisconnectDetail): void => {
				if (settled || detail.retryable) return;
				settled = true;
				this.off("synced", onSynced);
				this.off("disconnected", onDisconnected);
				reject(
					ZyncBaseError.fromServerResponse({
						code: detail.code,
						message: detail.reason,
					}),
				);
			};
			this.on("synced", onSynced);
			this.on("disconnected", onDisconnected);
			this.conn.connect().catch((err: unknown) => {
				if (settled) return;
				// A scheduled retry may still reach `synced`; only a state with
				// no recovery left settles the promise.
				if (this.conn.status === "reconnecting") return;
				settled = true;
				this.off("synced", onSynced);
				this.off("disconnected", onDisconnected);
				reject(err);
			});
		});
	}

	/** Disconnect from the server and cancel all pending timers. */
	disconnect(): void {
		this.storeImpl.rejectPending();
		this.tracker.setDisconnected();
		if (this.restoreTimer !== null) {
			clearTimeout(this.restoreTimer);
			this.restoreTimer = null;
		}
		this.conn.disconnect();
	}

	/**
	 * Restores subscriptions for the current connection. A retryable failure
	 * is retried with backoff while the connection stays up; a non-retryable
	 * one is surfaced to the error callbacks instead of retrying forever.
	 */
	private scheduleRestore(): void {
		this._restore()
			.then(() => {
				this.restoreAttempt = 0;
				this.emitLocal("synced");
			})
			.catch((err: unknown) => {
				if (err instanceof ZyncBaseError && err.retryable) {
					this.retryRestoreLater();
					return;
				}
				// A non-retryable replay failure is surfaced instead of retried
				// forever: a restore that can never succeed must not hold
				// readiness hostage silently.
				this.emitError(
					err instanceof ZyncBaseError
						? err
						: new ZyncBaseError(
								err instanceof Error ? err.message : "Restore failed",
								{
									code: ErrorCodes.INTERNAL_ERROR,
									category: "server",
									retryable: false,
								},
							),
				);
			});
	}

	private retryRestoreLater(): void {
		if (this.restoreTimer !== null || this.conn.status !== "connected") return;
		const delay = Math.min(250 * 2 ** this.restoreAttempt, 5_000);
		this.restoreAttempt++;
		this.restoreTimer = setTimeout(() => {
			this.restoreTimer = null;
			if (this.conn.status === "connected") this.scheduleRestore();
		}, delay);
	}

	/**
	 * Switch the active store namespace.
	 * returns a Promise that resolves when the switch is complete
	 * (including re-subscribing active listeners).
	 */
	async setStoreNamespace(namespace: string): Promise<void> {
		const oldNs = this.conn.getStoreNamespace();
		if (oldNs === namespace) return;

		// Gate establishments without invalidating scope: until the outcome is
		// known, in-flight acknowledgements still belong to the current scope.
		this.storeImpl.beginNamespaceSwitch();
		try {
			await this.conn.setStoreNamespace(namespace);
		} catch (err) {
			// The switch never happened — subscriptions were not invalidated,
			// so just release the gate; readiness itself was never touched.
			this.storeImpl.rollbackNamespaceSwitch();
			throw err;
		}

		// Spec: "Active store subscriptions are invalidated — the client must re-subscribe."
		// We replay all active subscriptions with the new namespace context.
		this.storeImpl.commitNamespaceSwitch();
		await this._restoreStore();
	}

	/** Switch the active presence namespace. */
	async setPresenceNamespace(namespace: string): Promise<void> {
		const oldNs = this.conn.getPresenceNamespace();
		if (oldNs === namespace) return;

		this.presenceImpl.invalidate();
		await this.conn.setPresenceNamespace(namespace);
		await this.presenceImpl.replaySubscriptions();
		this.actionsImpl.replayRegistrations();
	}

	/**
	 * Refresh the session with a new external JWT without disconnecting.
	 * Active scopes temporarily become not ready and are re-resolved before the promise resolves.
	 */
	authRefresh(token: string): Promise<void> {
		return this.conn.authRefresh(token);
	}

	/**
	 * Register a lifecycle event listener.
	 * 'error' events from fire-and-forget store operations are also routed here.
	 * `synced` and `reconnected` are emitted locally by the client.
	 */
	on<E extends LifecycleEvent>(event: E, callback: ClientEvents[E]): void {
		if (event === "synced" || event === "reconnected") {
			let handlers = this.localListeners.get(event);
			if (!handlers) {
				handlers = [];
				this.localListeners.set(event, handlers);
			}
			handlers.push(callback as (...args: unknown[]) => void);
			return;
		}
		if (event === "error") {
			this.errorCallbacks.push(callback as (err: ZyncBaseError) => void);
		}
		// Always delegate to ConnectionManager so connection-level errors are covered too
		this.conn.on(event, callback as unknown as (...args: unknown[]) => void);
	}

	/**
	 * Remove a lifecycle event listener.
	 */
	off<E extends LifecycleEvent>(event: E, callback: ClientEvents[E]): void {
		if (event === "synced" || event === "reconnected") {
			const handlers = this.localListeners.get(event);
			if (handlers) {
				const idx = handlers.indexOf(callback as (...args: unknown[]) => void);
				if (idx !== -1) handlers.splice(idx, 1);
			}
			return;
		}
		if (event === "error") {
			const idx = this.errorCallbacks.indexOf(
				callback as (err: ZyncBaseError) => void,
			);
			if (idx !== -1) this.errorCallbacks.splice(idx, 1);
		}
		this.conn.off(event, callback as unknown as (...args: unknown[]) => void);
	}

	// ─── Private ───────────────────────────────────────────────────────────────

	private emitLocal(event: "synced" | "reconnected"): void {
		const handlers = this.localListeners.get(event);
		if (!handlers) return;
		for (const handler of [...handlers]) handler();
	}

	/**
	 * Replay everything after a connect or reconnect, then release the
	 * readiness queue. On a connection cycle this ends with `synced`.
	 */
	private async _restore(): Promise<void> {
		await this.presenceImpl.replaySubscriptions();
		this.actionsImpl.replayRegistrations();
		await this._restoreStore();
	}

	/**
	 * Replay store subscriptions against the current connection, then release
	 * the readiness queue. Runs on connect/reconnect and on a store namespace
	 * switch — the flows that invalidate store subscriptions.
	 */
	private async _restoreStore(): Promise<void> {
		const oldToNew = new Map<number, number>();
		const replaySnapshots = new Map<
			number,
			{ collection: string; value: JsonValue[] }
		>();

		await this.tracker.replayAll(async (params, oldId) => {
			await this._replaySubscription(params, oldId, oldToNew, replaySnapshots);
		});

		// Always reconnect: with no subscriptions this still re-enables delta
		// delivery after an explicit disconnect().
		this.tracker.reconnect(oldToNew, () => {
			for (const [newSubId, snapshot] of replaySnapshots) {
				this._repopulateSubscription(newSubId, snapshot);
			}
		});

		await this.conn.awaitSchemaSync();
		await this.storeImpl.markSessionReady();
	}

	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: retry loop, response shaping, and transient classification are one replay story; splitting them scatters the retry conditions.
	private async _replaySubscription(
		params: Omit<StoreSubscribe, "id">,
		oldId: number,
		oldToNew: Map<number, number>,
		replaySnapshots: Map<number, { collection: string; value: JsonValue[] }>,
	): Promise<void> {
		for (;;) {
			try {
				const ok = await this.conn.dispatch(params);
				if (ok.subId !== undefined) {
					oldToNew.set(oldId, ok.subId);
					if (Array.isArray(ok.value)) {
						const collection = String(params.table_index);
						replaySnapshots.set(ok.subId, {
							collection,
							value: ok.value as JsonValue[],
						});
					}
				}
				return;
			} catch (err) {
				console.error(
					`[ZyncBase SDK] Failed to replay subscription (oldId=${oldId}) on reconnect:`,
					err,
				);
				const transient =
					typeof err === "object" &&
					err !== null &&
					(err as { retryable?: unknown }).retryable === true;
				if (!transient || this.conn.status !== "connected") throw err;
				await new Promise((resolve) => setTimeout(resolve, 100));
			}
		}
	}

	// Replayed snapshots must reach every subscription kind: collection views
	// rebuild their materialized view, document listens re-emit the record.
	private _repopulateSubscription(
		newSubId: number,
		snapshot: { collection: string; value: JsonValue[] },
	): void {
		const entry = this.tracker.get(newSubId);
		if (!entry) return;

		this.tracker.dispatchInitialSnapshot(
			newSubId,
			[snapshot.collection],
			snapshot.value,
		);
	}
}

/**
 * Create a new ZyncBaseClient instance.
 * Does not connect immediately — call `client.connect()` to establish the WebSocket.
 */
export function createClient(options: ClientOptions): ZyncBaseClient {
	return new ZyncBaseClient(options);
}
