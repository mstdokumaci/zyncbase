// ZyncBaseClient and createClient factory

import { ActionsImpl } from "./actions.js";
import { ConnectionManager } from "./connection.js";
import type { ZyncBaseError } from "./errors.js";
import { PresenceImpl } from "./presence.js";
import { StoreImpl } from "./store.js";
import { SubscriptionTracker } from "./subscriptions.js";
import type {
	Actions,
	ClientEvents,
	ClientOptions,
	ConnectionStatus,
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
	/** Locally emitted events (`synced`, `reconnected`) — no connection-layer source. */
	private readonly localListeners = new Map<
		string,
		Array<(...args: unknown[]) => void>
	>();
	/** Whether a connection existed earlier in this process. */
	private hasConnectedOnce = false;
	/** Replay + queue flush for the current connection cycle. */
	private replayPromise: Promise<void> = Promise.resolve();

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
			this.replayPromise = this._restore()
				.then(() => this.emitLocal("synced"))
				.catch(() => {});
		});
	}

	/** Current connection status, readable synchronously at any time. */
	get status(): ConnectionStatus {
		return this.conn.status;
	}

	/** Connect to the server. Returns a Promise that resolves when connected and SchemaSync is received. */
	connect(): Promise<void> {
		return this.conn
			.connect()
			.then(() => this.conn.awaitSchemaSync())
			.then(() => this.replayPromise);
	}

	/** Disconnect from the server and cancel all pending timers. */
	disconnect(): void {
		this.storeImpl.rejectPending();
		this.tracker.setDisconnected();
		this.conn.disconnect();
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
		await this._restore();
	}

	/** Switch the active presence namespace. */
	async setPresenceNamespace(namespace: string): Promise<void> {
		const oldNs = this.conn.getPresenceNamespace();
		if (oldNs === namespace) return;

		this.presenceImpl.invalidate();
		await this.conn.setPresenceNamespace(namespace);
		this.presenceImpl.replaySubscriptions();
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
	 * Replay everything after a connect or namespace switch, then release the
	 * readiness queue. On a connection cycle this ends with `synced`.
	 */
	private async _restore(): Promise<void> {
		this.presenceImpl.replaySubscriptions();
		this.actionsImpl.replayRegistrations();

		const subIds = this.tracker.allSubIds();
		if (subIds.length > 0) {
			const oldToNew = new Map<number, number>();
			const replaySnapshots = new Map<
				number,
				{ collection: string; value: JsonValue[] }
			>();

			// Replay all subscriptions and map old subIds to new ones.
			await this.tracker.replayAll(async (params, oldId) => {
				await this._replaySubscription(
					params,
					oldId,
					oldToNew,
					replaySnapshots,
				);
			});

			this.tracker.reconnect(oldToNew, () => {
				for (const [newSubId, snapshot] of replaySnapshots) {
					this._repopulateSubscription(newSubId, snapshot);
				}
			});
		}

		await this.conn.awaitSchemaSync();
		await this.storeImpl.markSessionReady();
	}

	private async _replaySubscription(
		params: Omit<StoreSubscribe, "id">,
		oldId: number,
		oldToNew: Map<number, number>,
		replaySnapshots: Map<number, { collection: string; value: JsonValue[] }>,
	): Promise<void> {
		try {
			const ok = await this.conn.dispatch({ ...params });
			if (ok.subId !== undefined) {
				oldToNew.set(oldId, ok.subId);
				if (Array.isArray(ok.value)) {
					const collection =
						typeof params.table_index === "string"
							? (params.table_index as string)
							: String(params.table_index);
					replaySnapshots.set(ok.subId, {
						collection,
						value: ok.value as JsonValue[],
					});
				}
			}
		} catch (err) {
			console.error(
				`[ZyncBase SDK] Failed to replay subscription (oldId=${oldId}) on reconnect:`,
				err,
			);
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
