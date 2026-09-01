import { ErrorCodes, ZyncBaseError } from "./errors.js";
import type { SchemaDictionary } from "./schema_dictionary.js";
import type {
	LifecycleEvent,
	OkResponse,
	Presence,
	PresenceBroadcast,
	PresenceBroadcastEntry,
	PresenceChange,
	PresenceChangeBatch,
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
	private userEntries: PresenceEntry[] = [];
	private userIndexes = new Map<string, number>();
	private sharedCache: Record<string, unknown> | null = null;
	private userSubId: number | null = null;
	private sharedSubId: number | null = null;
	private userSubPromise: Promise<void> | null = null;
	private sharedSubPromise: Promise<void> | null = null;
	private userSubGen = 0;
	private sharedSubGen = 0;
	private userCallbacks = new Set<(users: PresenceEntry[]) => void>();
	private userChangeCallbacks = new Set<(batch: PresenceChangeBatch) => void>();
	private sharedCallbacks = new Set<
		(shared: Record<string, unknown> | null) => void
	>();
	private localUserId: string | null = null;
	private lastSetTime = 0;
	private pendingSetData: Record<string, unknown> | null = null;
	private throttleTimer: ReturnType<typeof setTimeout> | null = null;
	private conn: PresenceConnection;
	private readonly emitError: (err: ZyncBaseError) => void;

	constructor(
		conn: PresenceConnection,
		emitError: (err: ZyncBaseError) => void = () => {},
	) {
		this.conn = conn;
		this.emitError = emitError;
		this.conn.onPresenceBroadcast((msg) => this.handleBroadcast(msg));
		this.conn.on("disconnected", () => this.handleDisconnect());
	}

	setLocalUserId(userId: string | null): void {
		this.localUserId = userId;
	}

	set(data: Record<string, unknown>): void {
		const now = performance.now();
		const elapsed = now - this.lastSetTime;

		if (elapsed >= THROTTLE_INTERVAL_MS) {
			if (this.throttleTimer !== null) {
				clearTimeout(this.throttleTimer);
				this.throttleTimer = null;
			}
			const pending = this.pendingSetData;
			this.pendingSetData = null;
			this.lastSetTime = now;
			this.sendSet(pending ? { ...pending, ...data } : data);
		} else {
			this.pendingSetData = { ...(this.pendingSetData ?? {}), ...data };
			if (this.throttleTimer === null) {
				this.throttleTimer = setTimeout(() => {
					this.throttleTimer = null;
					if (this.pendingSetData) {
						this.lastSetTime = performance.now();
						this.sendSet(this.pendingSetData);
						this.pendingSetData = null;
					}
				}, THROTTLE_INTERVAL_MS - elapsed);
			}
		}
	}

	setShared(data: Record<string, unknown>): void {
		this.conn.dispatch({ type: "PresenceSetShared", data }).catch((err) => {
			this.emitError(this.normalizeError(err, "Presence setShared failed"));
		});
	}

	private hasUserSubscribers(): boolean {
		return this.userCallbacks.size > 0 || this.userChangeCallbacks.size > 0;
	}

	private ensureUserSubscription(): void {
		if (this.userSubId !== null || this.userSubPromise !== null) return;
		const gen = this.userSubGen;
		this.userSubPromise = this.conn
			.dispatch({ type: "PresenceSubscribe" })
			.then((ok) => {
				this.handleUserSubscribeResponse(gen, ok);
			})
			.catch((err) => {
				if (gen !== this.userSubGen) return;
				this.userSubPromise = null;
				this.emitError(this.normalizeError(err, "Presence subscribe failed"));
			});
	}

	private cleanupUserSubscription(): void {
		if (
			!this.hasUserSubscribers() &&
			(this.userSubId !== null || this.userSubPromise !== null)
		) {
			const subId = this.userSubId;
			this.userSubId = null;
			this.clearUserCache();
			if (subId !== null) {
				this.conn
					.dispatch({
						type: "PresenceUnsubscribe",
						subId,
					})
					.catch(() => {});
			}
		}
	}

	subscribe(callback: (users: PresenceEntry[]) => void): () => void {
		this.userCallbacks.add(callback);

		if (this.userSubId !== null) {
			callback(this.getAll());
		} else {
			this.ensureUserSubscription();
		}

		return () => {
			this.userCallbacks.delete(callback);
			this.cleanupUserSubscription();
		};
	}

	subscribeChanges(callback: (batch: PresenceChangeBatch) => void): () => void {
		this.userChangeCallbacks.add(callback);

		if (this.userSubId !== null) {
			callback({ type: "snapshot", users: this.getAll() });
		} else {
			this.ensureUserSubscription();
		}

		return () => {
			this.userChangeCallbacks.delete(callback);
			this.cleanupUserSubscription();
		};
	}

	private handleUserSubscribeResponse(gen: number, ok: OkResponse): void {
		if (gen !== this.userSubGen) return;
		this.userSubPromise = null;
		if (!this.hasUserSubscribers()) {
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
		this.fireUserSubscribersOnInitialSnapshot();
	}

	private fireUserSubscribersOnInitialSnapshot(): void {
		if (this.userCallbacks.size > 0) {
			this.fireUserCallbacks();
		}
		if (this.userChangeCallbacks.size > 0) {
			const snapshotBatch: PresenceChangeBatch = {
				type: "snapshot",
				users: this.getAll(),
			};
			for (const cb of this.userChangeCallbacks) {
				cb(snapshotBatch);
			}
		}
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
				.catch((err) => {
					if (gen !== this.sharedSubGen) return;
					this.sharedSubPromise = null;
					this.emitError(
						this.normalizeError(err, "Presence subscribeShared failed"),
					);
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
		const index = this.userIndexes.get(userId);
		return index === undefined ? undefined : this.userEntries[index];
	}

	getAll(options?: PresenceGetAllOptions): PresenceEntry[] {
		// ponytail: snapshots stay O(n); add a delta API only if copying profiles hot again.
		const entries = this.userEntries.slice();
		if (!options?.includeSelf && this.localUserId) {
			const selfIndex = this.userIndexes.get(this.localUserId);
			if (selfIndex !== undefined) {
				entries[selfIndex] = entries[entries.length - 1];
				entries.pop();
			}
		}
		return entries;
	}

	getShared(): Record<string, unknown> | null {
		return this.sharedCache;
	}

	remove(): void {
		this.conn.dispatch({ type: "PresenceRemove" }).catch((err) => {
			this.emitError(this.normalizeError(err, "Presence remove failed"));
		});
	}

	invalidate(): void {
		this.userSubGen++;
		this.sharedSubGen++;
		this.localUserId = null;
		this.clearUserCache();
		this.sharedCache = null;
		this.userSubId = null;
		this.sharedSubId = null;
		this.userSubPromise = null;
		this.sharedSubPromise = null;
		this.clearThrottle();
	}

	replaySubscriptions(): void {
		if (this.hasUserSubscribers() && !this.userSubPromise) {
			this.userSubId = null;
			const gen = this.userSubGen;
			this.userSubPromise = this.conn
				.dispatch({ type: "PresenceSubscribe" })
				.then((ok) => {
					this.handleUserSubscribeResponse(gen, ok);
				})
				.catch((err) => {
					if (gen !== this.userSubGen) return;
					this.userSubPromise = null;
					this.emitError(
						this.normalizeError(err, "Presence replay subscribe failed"),
					);
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
					this.handleSharedSubscribeResponse(ok);
				})
				.catch((err) => {
					if (gen !== this.sharedSubGen) return;
					this.sharedSubPromise = null;
					this.emitError(
						this.normalizeError(err, "Presence replay subscribeShared failed"),
					);
				});
		}
	}

	private sendSet(data: Record<string, unknown>): void {
		this.conn.dispatch({ type: "PresenceSet", data }).catch((err) => {
			this.emitError(this.normalizeError(err, "Presence set failed"));
		});
	}

	private handleBroadcast(msg: PresenceBroadcast | SharedStateBroadcast): void {
		if (msg.type === "PresenceBroadcast") {
			this.handlePresenceBroadcast(msg);
		} else if (msg.type === "SharedStateBroadcast") {
			this.handleSharedStateBroadcast(msg);
		}
	}

	private shouldIncludeChange(change: PresenceChange): boolean {
		if (this.localUserId === null) return true;
		const changeUserId =
			change.type === "leave" ? change.userId : change.entry.userId;
		return changeUserId !== this.localUserId;
	}

	private fireUserChangeCallbacks(batch: PresenceChangeBatch): void {
		for (const cb of this.userChangeCallbacks) {
			cb(batch);
		}
	}

	private handlePresenceBroadcast(msg: PresenceBroadcast): void {
		if (msg.subId !== this.userSubId) return;

		const hasDelta = this.userChangeCallbacks.size > 0;
		const changes: PresenceChange[] | null = hasDelta ? [] : null;

		for (const entry of msg.users) {
			const change = this.applyBroadcastEntry(entry, hasDelta);
			if (
				change !== null &&
				changes !== null &&
				this.shouldIncludeChange(change)
			) {
				changes.push(change);
			}
		}

		if (this.userCallbacks.size > 0) {
			this.fireUserCallbacks();
		}

		if (changes !== null && changes.length > 0) {
			this.fireUserChangeCallbacks({ type: "changes", changes });
		}
	}

	private applyBroadcastEntry(
		entry: PresenceBroadcastEntry,
		collectChange: boolean,
	): PresenceChange | null {
		const userId = this.conn.schemaDictionary.decodePresenceUserId(
			entry.userId,
		);

		if (entry.event === "leave") {
			this.removeUserEntry(userId);
			return collectChange ? { type: "leave", userId } : null;
		}

		if (entry.event === "join") {
			return this.applyBroadcastJoin(userId, entry, collectChange);
		}

		return this.applyBroadcastUpdate(userId, entry, collectChange);
	}

	private applyBroadcastJoin(
		userId: string,
		entry: { data?: Record<string, unknown>; joinedAt?: number },
		collectChange: boolean,
	): PresenceChange | null {
		const newEntry: PresenceEntry = {
			userId,
			data: entry.data ?? {},
			joinedAt: entry.joinedAt ?? 0,
		};
		this.setUserEntry(newEntry);
		return collectChange ? { type: "join", entry: newEntry } : null;
	}

	private applyBroadcastUpdate(
		userId: string,
		entry: { data?: Record<string, unknown>; joinedAt?: number },
		collectChange: boolean,
	): PresenceChange | null {
		const index = this.userIndexes.get(userId);
		if (index !== undefined) {
			const existing = this.userEntries[index];
			const updatedEntry: PresenceEntry = {
				userId,
				joinedAt: existing.joinedAt,
				data: { ...existing.data, ...(entry.data ?? {}) },
			};
			this.userEntries[index] = updatedEntry;
			return collectChange ? { type: "update", entry: updatedEntry } : null;
		}

		const fallbackEntry: PresenceEntry = {
			userId,
			data: entry.data ?? {},
			joinedAt: entry.joinedAt ?? 0,
		};
		this.setUserEntry(fallbackEntry);
		return collectChange ? { type: "update", entry: fallbackEntry } : null;
	}

	private handleSharedStateBroadcast(msg: SharedStateBroadcast): void {
		if (msg.subId !== this.sharedSubId) return;

		for (const patch of msg.data) {
			this.sharedCache = { ...(this.sharedCache ?? {}), ...patch };
		}

		this.fireSharedCallbacks();
	}

	private populateUserCacheFromSnapshot(ok: OkResponse): void {
		this.clearUserCache();
		if (!Array.isArray(ok.users)) return;

		for (const user of ok.users) {
			const userId = this.conn.schemaDictionary.decodePresenceUserId(
				user.userId,
			);
			this.setUserEntry({
				userId,
				data: user.data as Record<string, unknown>,
				joinedAt: user.joinedAt ?? 0,
			});
		}
	}

	private setUserEntry(entry: PresenceEntry): void {
		const index = this.userIndexes.get(entry.userId);
		if (index === undefined) {
			this.userIndexes.set(entry.userId, this.userEntries.length);
			this.userEntries.push(entry);
		} else {
			this.userEntries[index] = entry;
		}
	}

	private removeUserEntry(userId: string): void {
		const index = this.userIndexes.get(userId);
		if (index === undefined) return;

		const lastIndex = this.userEntries.length - 1;
		if (index !== lastIndex) {
			const lastEntry = this.userEntries[lastIndex];
			this.userEntries[index] = lastEntry;
			this.userIndexes.set(lastEntry.userId, index);
		}
		this.userEntries.pop();
		this.userIndexes.delete(userId);
	}

	private clearUserCache(): void {
		this.userEntries.length = 0;
		this.userIndexes.clear();
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

	private normalizeError(err: unknown, fallbackMessage: string): ZyncBaseError {
		if (err instanceof ZyncBaseError) return err;
		return new ZyncBaseError(
			err instanceof Error ? err.message : fallbackMessage,
			{
				code: ErrorCodes.INTERNAL_ERROR,
				category: "server",
				retryable: true,
			},
		);
	}

	private clearThrottle(): void {
		if (this.throttleTimer !== null) {
			clearTimeout(this.throttleTimer);
			this.throttleTimer = null;
		}
		this.pendingSetData = null;
		this.lastSetTime = 0;
	}
}
