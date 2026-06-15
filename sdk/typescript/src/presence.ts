import type { SchemaDictionary } from "./schema_dictionary.js";
import type {
	LifecycleEvent,
	OkResponse,
	Presence,
	PresenceBroadcast,
	PresenceEntry,
	PresenceGetAllOptions,
	SharedStateBroadcast,
} from "./types.js";

const THROTTLE_INTERVAL_MS = 16;

export interface PresenceConnection {
	dispatch(msg: Record<string, unknown>): Promise<OkResponse>;
	onPresenceBroadcast(
		handler: (msg: PresenceBroadcast | SharedStateBroadcast) => void,
	): void;
	on(event: LifecycleEvent, handler: (...args: unknown[]) => void): void;
	schemaDictionary: SchemaDictionary;
}

export class PresenceImpl implements Presence {
	private userCache = new Map<string, PresenceEntry>();
	private sharedCache: Record<string, unknown> | null = null;
	private userSubId: number | null = null;
	private sharedSubId: number | null = null;
	private userSubPromise: Promise<void> | null = null;
	private sharedSubPromise: Promise<void> | null = null;
	private userSubGen = 0;
	private sharedSubGen = 0;
	private userCallbacks = new Set<(users: PresenceEntry[]) => void>();
	private sharedCallbacks = new Set<
		(shared: Record<string, unknown> | null) => void
	>();
	private localUserId: string | null = null;
	private lastSetTime = 0;
	private pendingSetData: Record<string, unknown> | null = null;
	private throttleTimer: ReturnType<typeof setTimeout> | null = null;
	private conn: PresenceConnection;

	constructor(conn: PresenceConnection) {
		this.conn = conn;
		this.conn.onPresenceBroadcast((msg) => this.handleBroadcast(msg));
		this.conn.on("disconnected", () => this.handleDisconnect());
	}

	setLocalUserId(userId: string | null): void {
		this.localUserId = userId;
	}

	set(data: Record<string, unknown>): void {
		const now = Date.now();
		const elapsed = now - this.lastSetTime;

		if (elapsed >= THROTTLE_INTERVAL_MS) {
			this.lastSetTime = now;
			this.sendSet(data);
		} else {
			this.pendingSetData = { ...(this.pendingSetData ?? {}), ...data };
			if (this.throttleTimer === null) {
				this.throttleTimer = setTimeout(() => {
					this.throttleTimer = null;
					if (this.pendingSetData) {
						this.lastSetTime = Date.now();
						this.sendSet(this.pendingSetData);
						this.pendingSetData = null;
					}
				}, THROTTLE_INTERVAL_MS - elapsed);
			}
		}
	}

	setShared(data: Record<string, unknown>): void {
		this.conn.dispatch({ type: "PresenceSetShared", data }).catch(() => {});
	}

	subscribe(callback: (users: PresenceEntry[]) => void): () => void {
		this.userCallbacks.add(callback);

		if (this.userSubId !== null) {
			callback(this.getAll());
		} else if (!this.userSubPromise) {
			const gen = this.userSubGen;
			this.userSubPromise = this.conn
				.dispatch({ type: "PresenceSubscribe" })
				.then((ok) => {
					this.handleUserSubscribeResponse(gen, ok);
				})
				.catch(() => {
					if (gen !== this.userSubGen) return;
					this.userSubPromise = null;
				});
		}

		return () => {
			this.userCallbacks.delete(callback);
			if (
				this.userCallbacks.size === 0 &&
				(this.userSubId !== null || this.userSubPromise !== null)
			) {
				const subId = this.userSubId;
				this.userSubId = null;
				this.userCache.clear();
				if (subId !== null) {
					this.conn
						.dispatch({
							type: "PresenceUnsubscribe",
							subId,
						})
						.catch(() => {});
				}
			}
		};
	}

	private handleUserSubscribeResponse(gen: number, ok: OkResponse): void {
		if (gen !== this.userSubGen) return;
		this.userSubPromise = null;
		if (this.userCallbacks.size === 0) {
			if (ok.subId !== undefined) {
				this.conn
					.dispatch({
						type: "PresenceUnsubscribe",
						subId: ok.subId,
					})
					.catch(() => {});
			}
			return;
		}
		this.userSubId = ok.subId ?? null;
		this.populateUserCacheFromSnapshot(ok);
		this.fireUserCallbacks();
	}

	subscribeShared(
		callback: (shared: Record<string, unknown> | null) => void,
	): () => void {
		this.sharedCallbacks.add(callback);

		if (this.sharedSubId !== null) {
			callback(this.sharedCache);
		} else if (!this.sharedSubPromise) {
			const gen = this.sharedSubGen;
			this.sharedSubPromise = this.conn
				.dispatch({ type: "PresenceSubscribeShared" })
				.then((ok) => {
					if (gen !== this.sharedSubGen) return;
					this.sharedSubPromise = null;
					this.handleSharedSubscribeResponse(ok);
				})
				.catch(() => {
					if (gen !== this.sharedSubGen) return;
					this.sharedSubPromise = null;
				});
		}

		return () => {
			this.sharedCallbacks.delete(callback);
			if (
				this.sharedCallbacks.size === 0 &&
				(this.sharedSubId !== null || this.sharedSubPromise !== null)
			) {
				const subId = this.sharedSubId;
				this.sharedSubId = null;
				this.sharedCache = null;
				if (subId !== null) {
					this.conn
						.dispatch({
							type: "PresenceUnsubscribeShared",
							subId,
						})
						.catch(() => {});
				}
			}
		};
	}

	private handleSharedSubscribeResponse(ok: OkResponse): void {
		if (this.sharedCallbacks.size === 0) {
			if (ok.subId !== undefined) {
				this.conn
					.dispatch({
						type: "PresenceUnsubscribeShared",
						subId: ok.subId,
					})
					.catch(() => {});
			}
			return;
		}
		this.sharedSubId = ok.subId ?? null;
		if (ok.shared != null) {
			this.sharedCache = ok.shared as Record<string, unknown>;
		} else {
			this.sharedCache = null;
		}
		this.fireSharedCallbacks();
	}

	get(userId: string): PresenceEntry | undefined {
		return this.userCache.get(userId);
	}

	getAll(options?: PresenceGetAllOptions): PresenceEntry[] {
		const entries = Array.from(this.userCache.values());
		if (!options?.includeSelf && this.localUserId) {
			return entries.filter((e) => e.userId !== this.localUserId);
		}
		return entries;
	}

	getShared(): Record<string, unknown> | null {
		return this.sharedCache;
	}

	remove(): void {
		this.conn.dispatch({ type: "PresenceRemove" }).catch(() => {});
	}

	invalidate(): void {
		this.userSubGen++;
		this.sharedSubGen++;
		this.userCache.clear();
		this.sharedCache = null;
		this.userSubId = null;
		this.sharedSubId = null;
		this.userSubPromise = null;
		this.sharedSubPromise = null;
		this.clearThrottle();
	}

	replaySubscriptions(): void {
		if (this.userCallbacks.size > 0 && !this.userSubPromise) {
			this.userSubId = null;
			const gen = this.userSubGen;
			this.userSubPromise = this.conn
				.dispatch({ type: "PresenceSubscribe" })
				.then((ok) => {
					if (gen !== this.userSubGen) return;
					this.userSubPromise = null;
					this.userSubId = ok.subId ?? null;
					this.populateUserCacheFromSnapshot(ok);
					this.fireUserCallbacks();
				})
				.catch(() => {
					if (gen !== this.userSubGen) return;
					this.userSubPromise = null;
				});
		}

		if (this.sharedCallbacks.size > 0 && !this.sharedSubPromise) {
			this.sharedSubId = null;
			const gen = this.sharedSubGen;
			this.sharedSubPromise = this.conn
				.dispatch({ type: "PresenceSubscribeShared" })
				.then((ok) => {
					if (gen !== this.sharedSubGen) return;
					this.sharedSubPromise = null;
					this.sharedSubId = ok.subId ?? null;
					if (ok.shared != null) {
						this.sharedCache = ok.shared as Record<string, unknown>;
					} else {
						this.sharedCache = null;
					}
					this.fireSharedCallbacks();
				})
				.catch(() => {
					if (gen !== this.sharedSubGen) return;
					this.sharedSubPromise = null;
				});
		}
	}

	private sendSet(data: Record<string, unknown>): void {
		this.conn.dispatch({ type: "PresenceSet", data }).catch(() => {});
	}

	private handleBroadcast(msg: PresenceBroadcast | SharedStateBroadcast): void {
		if (msg.type === "PresenceBroadcast") {
			this.handlePresenceBroadcast(msg);
		} else if (msg.type === "SharedStateBroadcast") {
			this.handleSharedStateBroadcast(msg);
		}
	}

	private handlePresenceBroadcast(msg: PresenceBroadcast): void {
		if (msg.subId !== this.userSubId) return;

		for (const entry of msg.users) {
			this.applyBroadcastEntry(entry);
		}

		this.fireUserCallbacks();
	}

	private applyBroadcastEntry(entry: {
		userId: Uint8Array;
		event: "join" | "update" | "leave";
		data?: Record<string, unknown>;
		joinedAt?: number;
	}): void {
		const userId = this.conn.schemaDictionary.decodePresenceUserId(
			entry.userId,
		);

		if (entry.event === "leave") {
			this.userCache.delete(userId);
			return;
		}

		if (entry.event === "join") {
			this.userCache.set(userId, {
				userId,
				data: entry.data ?? {},
				joinedAt: entry.joinedAt ?? 0,
			});
			return;
		}

		const existing = this.userCache.get(userId);
		if (existing) {
			this.userCache.set(userId, {
				userId,
				joinedAt: existing.joinedAt,
				data: { ...existing.data, ...(entry.data ?? {}) },
			});
		} else {
			this.userCache.set(userId, {
				userId,
				data: entry.data ?? {},
				joinedAt: entry.joinedAt ?? 0,
			});
		}
	}

	private handleSharedStateBroadcast(msg: SharedStateBroadcast): void {
		if (msg.subId !== this.sharedSubId) return;

		if (Array.isArray(msg.data)) {
			for (const patch of msg.data) {
				this.sharedCache = { ...(this.sharedCache ?? {}), ...patch };
			}
		} else {
			this.sharedCache = { ...(this.sharedCache ?? {}), ...msg.data };
		}

		this.fireSharedCallbacks();
	}

	private populateUserCacheFromSnapshot(ok: OkResponse): void {
		this.userCache.clear();
		if (!Array.isArray(ok.users)) return;

		for (const user of ok.users) {
			const userId = this.conn.schemaDictionary.decodePresenceUserId(
				user.userId,
			);
			this.userCache.set(userId, {
				userId,
				data: user.data as Record<string, unknown>,
				joinedAt: user.joinedAt ?? 0,
			});
		}
	}

	private fireUserCallbacks(): void {
		const users = this.getAll();
		for (const cb of this.userCallbacks) {
			cb(users);
		}
	}

	private fireSharedCallbacks(): void {
		for (const cb of this.sharedCallbacks) {
			cb(this.sharedCache);
		}
	}

	private handleDisconnect(): void {
		this.invalidate();
	}

	private clearThrottle(): void {
		if (this.throttleTimer !== null) {
			clearTimeout(this.throttleTimer);
			this.throttleTimer = null;
		}
		this.pendingSetData = null;
	}
}
