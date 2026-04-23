// ZyncBaseClient and createClient factory

import { ConnectionManager } from "./connection.js";
import type { ZyncBaseError } from "./errors.js";
import { StoreImpl } from "./store.js";
import { SubscriptionTracker } from "./subscriptions.js";
import type {
	ClientOptions,
	JsonValue,
	LifecycleEvent,
	Store,
	StoreDelta,
	StoreSubscribe,
} from "./types.js";
import { generateUUIDv7 } from "./uuid.js";

export class ZyncBaseClient {
	readonly store: Store;
	readonly utils: { id: () => string };

	private readonly conn: ConnectionManager;
	private readonly tracker: SubscriptionTracker;
	/** Error callbacks registered via client.on('error', cb). */
	private readonly errorCallbacks: Array<(err: ZyncBaseError) => void> = [];

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

		this.store = new StoreImpl(this.conn, this.tracker, emitError);
		this.utils = { id: generateUUIDv7 };

		// On reconnect: replay subscriptions
		this.conn.on("connected", () => {
			this._handleReconnect();
		});
	}

	/** Connect to the server. Returns a Promise that resolves when connected and SchemaSync is received. */
	connect(): Promise<void> {
		return this.conn.connect().then(() => this.conn.awaitSchemaSync());
	}

	/** Disconnect from the server and cancel all pending timers. */
	disconnect(): void {
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

		this.conn.setStoreNamespace(namespace);

		// Spec: "Active store subscriptions are invalidated — the client must re-subscribe."
		// We replay all active subscriptions with the new namespace context.
		await this._handleReconnect();
	}

	/** Switch the active presence namespace. */
	async setPresenceNamespace(namespace: string): Promise<void> {
		this.conn.setPresenceNamespace(namespace);
		// TODO: Clear presence in old namespace and join new one once Presence API is implemented.
	}

	/**
	 * Register a lifecycle event listener.
	 * 'error' events from fire-and-forget store operations are also routed here.
	 */
	on(event: LifecycleEvent, callback: (...args: unknown[]) => void): void {
		if (event === "error") {
			this.errorCallbacks.push(callback as (err: ZyncBaseError) => void);
		}
		// Always delegate to ConnectionManager so connection-level errors are covered too
		this.conn.on(event, callback);
	}

	/**
	 * Remove a lifecycle event listener.
	 */
	off(event: LifecycleEvent, callback: (...args: unknown[]) => void): void {
		if (event === "error") {
			const idx = this.errorCallbacks.indexOf(
				callback as (err: ZyncBaseError) => void,
			);
			if (idx !== -1) this.errorCallbacks.splice(idx, 1);
		}
		this.conn.off(event, callback);
	}

	// ─── Private ───────────────────────────────────────────────────────────────

	/**
	 * Called each time the ConnectionManager emits "connected" or after a namespace switch.
	 */
	private async _handleReconnect(): Promise<void> {
		const subIds = this.tracker.allSubIds();
		if (subIds.length === 0) return;

		const oldToNew = new Map<number, number>();
		const replaySnapshots = new Map<
			number,
			{ collection: string; value: JsonValue[] }
		>();

		// Replay all subscriptions and map old subIds to new ones.
		await this.tracker.replayAll(async (params, oldId) => {
			await this._replaySubscription(params, oldId, oldToNew, replaySnapshots);
		});

		this.tracker.reconnect(oldToNew);

		// Feed initial snapshots for materialized views
		for (const [newSubId, snapshot] of replaySnapshots) {
			this._repopulateMaterializedView(newSubId, snapshot);
		}
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

	private _repopulateMaterializedView(
		newSubId: number,
		snapshot: { collection: string; value: JsonValue[] },
	): void {
		const entry = this.tracker.get(newSubId);
		if (!entry?.materializedView) return;

		const delta: StoreDelta = { type: "StoreDelta", subId: newSubId, ops: [] };
		for (const row of snapshot.value) {
			if (row && typeof row === "object" && !Array.isArray(row)) {
				const r = row as Record<string, JsonValue>;
				const id = r.id as string;
				if (id) {
					delta.ops.push({
						op: "set",
						path: [snapshot.collection, id],
						value: row,
					});
				}
			}
		}
		if (delta.ops.length > 0) {
			this.tracker.dispatch(delta);
		}
	}
}

/**
 * Create a new ZyncBaseClient instance.
 * Does not connect immediately — call `client.connect()` to establish the WebSocket.
 */
export function createClient(options: ClientOptions): ZyncBaseClient {
	return new ZyncBaseClient(options);
}
