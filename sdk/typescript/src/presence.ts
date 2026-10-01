import { ErrorCodes, ZyncBaseError } from "./errors.js";
import type { SchemaDictionary } from "./schema_dictionary.js";
import type {
	LifecycleEvent,
	OkResponse,
	Presence,
	PresenceBroadcast,
	PresenceBroadcastEntry,
	PresenceEntry,
	PresenceGetAllOptions,
	SharedStateBroadcast,
} from "./types.js";

const THROTTLE_INTERVAL_MS = 16;

interface SetWaiter {
	resolve: () => void;
	reject: (reason?: unknown) => void;
}

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
	private sharedCallbacks = new Set<
		(shared: Record<string, unknown> | null) => void
	>();
	private _localUserId: string | null = null;
	private lastSetTime = 0;
	private pendingSetData: Record<string, unknown> | null = null;
	private pendingSetWaiters: SetWaiter[] = [];
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
		this._localUserId = userId;
	}

	/** Scope-resolved internal users.id, or null before scope setup. */
	get localUserId(): string | null {
		return this._localUserId;
	}

	set(data: Record<string, unknown>): Promise<void> {
		let resolve!: () => void;
		let reject!: (reason?: unknown) => void;
		const accepted = new Promise<void>((res, rej) => {
			resolve = res;
			reject = rej;
		});
		accepted.catch(() => {});
		this.pendingSetWaiters.push({ resolve, reject });

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
			this.sendSet(
				pending ? { ...pending, ...data } : data,
				this.pendingSetWaiters.splice(0),
			);
		} else {
			this.pendingSetData = { ...(this.pendingSetData ?? {}), ...data };
			if (this.throttleTimer === null) {
				this.throttleTimer = setTimeout(() => {
					this.throttleTimer = null;
					if (this.pendingSetData) {
						this.lastSetTime = performance.now();
						this.sendSet(this.pendingSetData, this.pendingSetWaiters.splice(0));
						this.pendingSetData = null;
					}
				}, THROTTLE_INTERVAL_MS - elapsed);
			}
		}
		return accepted;
	}

	setShared(data: Record<string, unknown>): Promise<void> {
		return this.dispatchAccepted(
			{ type: "PresenceSetShared", data },
			"Presence setShared failed",
		);
	}

	private hasUserSubscribers(): boolean {
		return this.userCallbacks.size > 0;
	}

	private ensureUserSubscription(): Promise<void> {
		if (this.userSubId !== null) return Promise.resolve();
		if (this.userSubPromise !== null) return this.userSubPromise;
		const gen = this.userSubGen;
		const pending = this.establishUserSubscription(gen).catch((err) => {
			const error = this.normalizeError(err, "Presence subscribe failed");
			if (gen === this.userSubGen) this.emitError(error);
			throw error;
		});
		this.userSubPromise = pending;
		pending.then(
			() => {
				if (gen === this.userSubGen && this.userSubPromise === pending)
					this.userSubPromise = null;
			},
			() => {
				if (gen === this.userSubGen && this.userSubPromise === pending)
					this.userSubPromise = null;
			},
		);
		return pending;
	}

	private async establishUserSubscription(gen: number): Promise<void> {
		while (gen === this.userSubGen) {
			const ok = await this.conn.dispatch({ type: "PresenceSubscribe" });
			if (ok.subId === undefined) {
				throw new ZyncBaseError("PresenceSubscribe response missing subId", {
					code: ErrorCodes.INVALID_MESSAGE,
					category: "client",
					retryable: false,
				});
			}
			if (gen !== this.userSubGen || !this.hasUserSubscribers()) {
				await this.dispatchAccepted(
					{ type: "PresenceUnsubscribe", subId: ok.subId },
					"Presence unsubscribe failed",
				);
				if (gen !== this.userSubGen || !this.hasUserSubscribers()) return;
				continue;
			}
			this.userSubId = ok.subId;
			this.populateUserCacheFromSnapshot(ok);
			this.fireUserSubscribersOnInitialSnapshot();
			return;
		}
		throw new ZyncBaseError("Presence subscription superseded", {
			code: ErrorCodes.REQUEST_SUPERSEDED,
			category: "state",
			retryable: false,
		});
	}

	private cleanupUserSubscription(): Promise<void> {
		if (
			!this.hasUserSubscribers() &&
			(this.userSubId !== null || this.userSubPromise !== null)
		) {
			const subId = this.userSubId;
			this.userSubId = null;
			this.clearUserCache();
			if (subId !== null) {
				return this.dispatchAccepted(
					{ type: "PresenceUnsubscribe", subId },
					"Presence unsubscribe failed",
				);
			}
			if (this.userSubPromise !== null) return this.userSubPromise;
		}
		return Promise.resolve();
	}

	private ensureSharedSubscription(): Promise<void> {
		if (this.sharedSubId !== null) return Promise.resolve();
		if (this.sharedSubPromise !== null) return this.sharedSubPromise;
		const gen = this.sharedSubGen;
		const pending = this.establishSharedSubscription(gen).catch((err) => {
			const error = this.normalizeError(err, "Presence subscribeShared failed");
			if (gen === this.sharedSubGen) this.emitError(error);
			throw error;
		});
		this.sharedSubPromise = pending;
		pending.then(
			() => {
				if (gen === this.sharedSubGen && this.sharedSubPromise === pending)
					this.sharedSubPromise = null;
			},
			() => {
				if (gen === this.sharedSubGen && this.sharedSubPromise === pending)
					this.sharedSubPromise = null;
			},
		);
		return pending;
	}

	private async establishSharedSubscription(gen: number): Promise<void> {
		while (gen === this.sharedSubGen) {
			const ok = await this.conn.dispatch({ type: "PresenceSubscribeShared" });
			if (ok.subId === undefined) {
				throw new ZyncBaseError(
					"PresenceSubscribeShared response missing subId",
					{
						code: ErrorCodes.INVALID_MESSAGE,
						category: "client",
						retryable: false,
					},
				);
			}
			if (!this.hasCurrentSharedSubscribers(gen)) {
				await this.dispatchAccepted(
					{ type: "PresenceUnsubscribeShared", subId: ok.subId },
					"Presence unsubscribeShared failed",
				);
				if (!this.hasCurrentSharedSubscribers(gen)) return;
				continue;
			}
			this.sharedSubId = ok.subId;
			this.sharedCache =
				ok.shared != null ? (ok.shared as Record<string, unknown>) : null;
			this.fireSharedCallbacks();
			return;
		}
		throw new ZyncBaseError("Presence shared subscription superseded", {
			code: ErrorCodes.REQUEST_SUPERSEDED,
			category: "state",
			retryable: false,
		});
	}

	private hasCurrentSharedSubscribers(gen: number): boolean {
		return gen === this.sharedSubGen && this.sharedCallbacks.size > 0;
	}

	private cleanupSharedSubscription(): Promise<void> {
		if (
			this.sharedCallbacks.size === 0 &&
			(this.sharedSubId !== null || this.sharedSubPromise !== null)
		) {
			const subId = this.sharedSubId;
			this.sharedSubId = null;
			this.sharedCache = null;
			if (subId !== null) {
				return this.dispatchAccepted(
					{ type: "PresenceUnsubscribeShared", subId },
					"Presence unsubscribeShared failed",
				);
			}
			if (this.sharedSubPromise !== null) return this.sharedSubPromise;
		}
		return Promise.resolve();
	}

	subscribe(
		callback: (users: PresenceEntry[]) => void,
	): Promise<() => Promise<void>> {
		return this.subscribeCallback(
			this.userCallbacks,
			callback,
			() => this.ensureUserSubscription(),
			() => this.cleanupUserSubscription(),
			() => (this.userSubId === null ? undefined : this.getAll()),
		);
	}

	private subscribeCallback<T>(
		callbacks: Set<(value: T) => void>,
		callback: (value: T) => void,
		start: () => Promise<void>,
		cleanup: () => Promise<void>,
		initial?: () => T | undefined,
	): Promise<() => Promise<void>> {
		let closed = false;
		let initialDelivered = false;
		const pending: T[] = [];
		let flushTimer: ReturnType<typeof setTimeout> | null = null;
		const listener = (value: T) => {
			if (closed) return;
			if (initialDelivered) {
				callback(value);
				return;
			}
			pending.push(value);
			if (flushTimer !== null) return;
			flushTimer = setTimeout(() => {
				flushTimer = null;
				initialDelivered = true;
				for (const next of pending.splice(0)) {
					if (closed) break;
					callback(next);
				}
			}, 0);
		};
		callbacks.add(listener);
		const snapshot = initial?.();
		if (snapshot !== undefined) listener(snapshot);

		let ready: Promise<void>;
		try {
			ready = start();
		} catch (err) {
			ready = Promise.reject(err);
		}

		const result = ready.then(
			() => {
				let closing: Promise<void> | null = null;
				return () => {
					if (closing) return closing;
					closed = true;
					callbacks.delete(listener);
					if (flushTimer !== null) clearTimeout(flushTimer);
					pending.length = 0;
					closing = cleanup();
					closing.catch(() => {});
					return closing;
				};
			},
			(err) => {
				closed = true;
				callbacks.delete(listener);
				if (flushTimer !== null) clearTimeout(flushTimer);
				pending.length = 0;
				throw err;
			},
		);
		result.catch(() => {});
		return result;
	}

	private fireUserSubscribersOnInitialSnapshot(): void {
		if (this.userCallbacks.size > 0) {
			this.fireUserCallbacks();
		}
	}

	subscribeShared(
		callback: (shared: Record<string, unknown> | null) => void,
	): Promise<() => Promise<void>> {
		return this.subscribeCallback(
			this.sharedCallbacks,
			callback,
			() => this.ensureSharedSubscription(),
			() => this.cleanupSharedSubscription(),
			() => (this.sharedSubId === null ? undefined : this.sharedCache),
		);
	}

	get(userId: string): PresenceEntry | undefined {
		const index = this.userIndexes.get(userId);
		return index === undefined ? undefined : this.userEntries[index];
	}

	getAll(options?: PresenceGetAllOptions): PresenceEntry[] {
		// snapshots stay O(n); add a delta API only if copying profiles hot again.
		const entries = this.userEntries.slice();
		if (!options?.includeSelf && this._localUserId) {
			const selfIndex = this.userIndexes.get(this._localUserId);
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

	remove(): Promise<void> {
		this.clearThrottle(
			new ZyncBaseError("Presence set superseded by remove", {
				code: ErrorCodes.REQUEST_SUPERSEDED,
				category: "state",
				retryable: false,
			}),
		);
		return this.dispatchAccepted(
			{ type: "PresenceRemove" },
			"Presence remove failed",
		);
	}

	invalidate(
		reason = new ZyncBaseError("Presence set superseded by scope change", {
			code: ErrorCodes.REQUEST_SUPERSEDED,
			category: "state",
			retryable: false,
		}),
	): void {
		this.userSubGen++;
		this.sharedSubGen++;
		this._localUserId = null;
		this.clearUserCache();
		this.sharedCache = null;
		this.userSubId = null;
		this.sharedSubId = null;
		this.userSubPromise = null;
		this.sharedSubPromise = null;
		this.clearThrottle(reason);
	}

	async replaySubscriptions(): Promise<void> {
		if (this.hasUserSubscribers()) {
			this.userSubId = null;
			await this.ensureUserSubscription();
		}

		if (this.sharedCallbacks.size > 0) {
			this.sharedSubId = null;
			await this.ensureSharedSubscription();
		}
	}

	private sendSet(data: Record<string, unknown>, waiters: SetWaiter[]): void {
		this.dispatchAccepted(
			{ type: "PresenceSet", data },
			"Presence set failed",
		).then(
			() => {
				for (const waiter of waiters) waiter.resolve();
			},
			(error) => {
				for (const waiter of waiters) waiter.reject(error);
			},
		);
	}

	private dispatchAccepted(
		message: Record<string, unknown>,
		fallback: string,
	): Promise<void> {
		const accepted = this.conn.dispatch(message).then(
			() => {},
			(err) => {
				const error = this.normalizeError(err, fallback);
				this.emitError(error);
				throw error;
			},
		);
		accepted.catch(() => {});
		return accepted;
	}

	private handleBroadcast(msg: PresenceBroadcast | SharedStateBroadcast): void {
		if (msg.type === "PresenceBroadcast") {
			this.handlePresenceBroadcast(msg);
		} else if (msg.type === "SharedStateBroadcast") {
			this.handleSharedStateBroadcast(msg);
		}
	}

	private isRelevantChange(userId: string): boolean {
		return this._localUserId === null || userId !== this._localUserId;
	}

	private handlePresenceBroadcast(msg: PresenceBroadcast): void {
		if (msg.subId !== this.userSubId) return;

		let changed = false;
		for (const entry of msg.users) {
			if (this.applyBroadcastEntry(entry)) changed = true;
		}

		if (changed && this.userCallbacks.size > 0) {
			this.fireUserCallbacks();
		}
	}

	private applyBroadcastEntry(entry: PresenceBroadcastEntry): boolean {
		const userId = this.conn.schemaDictionary.decodePresenceUserId(
			entry.userId,
		);

		if (entry.event === "leave") {
			this.removeUserEntry(userId);
			return this.isRelevantChange(userId);
		}

		if (entry.event === "join") {
			this.applyBroadcastJoin(userId, entry);
		} else {
			this.applyBroadcastUpdate(userId, entry);
		}
		return this.isRelevantChange(userId);
	}

	private applyBroadcastJoin(
		userId: string,
		entry: { data?: Record<string, unknown>; joinedAt?: number },
	): void {
		this.setUserEntry({
			userId,
			data: entry.data ?? {},
			joinedAt: entry.joinedAt ?? 0,
		});
	}

	private applyBroadcastUpdate(
		userId: string,
		entry: { data?: Record<string, unknown>; joinedAt?: number },
	): void {
		const index = this.userIndexes.get(userId);
		if (index !== undefined) {
			const existing = this.userEntries[index];
			this.userEntries[index] = {
				userId,
				joinedAt: existing.joinedAt,
				data: { ...existing.data, ...(entry.data ?? {}) },
			};
			return;
		}

		this.setUserEntry({
			userId,
			data: entry.data ?? {},
			joinedAt: entry.joinedAt ?? 0,
		});
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
		this.invalidate(
			new ZyncBaseError("Connection closed before presence was accepted", {
				code: ErrorCodes.CONNECTION_FAILED,
				category: "network",
				retryable: true,
			}),
		);
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

	private clearThrottle(reason?: Error): void {
		if (this.throttleTimer !== null) {
			clearTimeout(this.throttleTimer);
			this.throttleTimer = null;
		}
		this.pendingSetData = null;
		if (reason) {
			for (const waiter of this.pendingSetWaiters) waiter.reject(reason);
		}
		this.pendingSetWaiters = [];
		this.lastSetTime = 0;
	}
}
