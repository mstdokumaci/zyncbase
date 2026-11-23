import type { ZyncBaseClient } from "../client.js";
import { ZyncBaseError } from "../errors.js";
import type {
	BatchOperation,
	ConnectionStatus,
	JsonValue,
	SubscriptionHandle,
} from "../types.js";

export type FakeRow = Record<string, JsonValue> & {
	id: string;
	created_at: number;
	updated_at: number;
};

type QueryOptions = {
	where?: Record<string, unknown>;
	orderBy?: ReadonlyArray<Record<string, "asc" | "desc">>;
	limit?: number;
	after?: string;
};

interface FakeSubscription {
	namespace: string;
	collection: string;
	where: Record<string, unknown> | undefined;
	orderBy: ReadonlyArray<Record<string, "asc" | "desc">>;
	initialIds: Set<string>;
	startClock: number;
	callback: (rows: JsonValue[]) => void;
}

function isPlainRecord(value: unknown): value is Record<string, unknown> {
	return (
		value !== null &&
		typeof value === "object" &&
		!Array.isArray(value) &&
		!(value instanceof Uint8Array)
	);
}

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: test fake mirrors the SDK's comparison operators.
function matches(
	row: FakeRow,
	where: Record<string, unknown> | undefined,
): boolean {
	if (where === undefined) return true;
	for (const [field, condition] of Object.entries(where)) {
		const actual = row[field];
		if (isPlainRecord(condition)) {
			if ("eq" in condition && actual !== condition.eq) return false;
			if ("gt" in condition) {
				if (
					typeof actual !== "number" ||
					typeof condition.gt !== "number" ||
					actual <= condition.gt
				) {
					return false;
				}
			}
			if ("gte" in condition) {
				if (
					typeof actual !== "number" ||
					typeof condition.gte !== "number" ||
					actual < condition.gte
				) {
					return false;
				}
			}
			if ("lt" in condition) {
				if (
					typeof actual !== "number" ||
					typeof condition.lt !== "number" ||
					actual >= condition.lt
				) {
					return false;
				}
			}
			if ("lte" in condition) {
				if (
					typeof actual !== "number" ||
					typeof condition.lte !== "number" ||
					actual > condition.lte
				) {
					return false;
				}
			}
			continue;
		}
		if (actual !== condition) return false;
	}
	return true;
}

function sortRows(
	rows: FakeRow[],
	orderBy: ReadonlyArray<Record<string, "asc" | "desc">> | undefined,
): FakeRow[] {
	const clause = orderBy?.[0];
	if (clause === undefined)
		return rows.sort((a, b) => a.created_at - b.created_at);
	const [field, direction] = Object.entries(clause)[0] as [
		string,
		"asc" | "desc",
	];
	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: test fake mirrors the SDK's sort direction branches.
	rows.sort((a, b) => {
		const left = a[field];
		const right = b[field];
		if (left === right) return 0;
		if (typeof left === "number" && typeof right === "number") {
			return direction === "asc" ? left - right : right - left;
		}
		return direction === "asc"
			? String(left) < String(right)
				? -1
				: 1
			: String(left) > String(right)
				? -1
				: 1;
	});
	return rows;
}

/** Minimal in-memory stand-in for the SDK store. */
export class FakeStore {
	private readonly namespaceData = new Map<
		string,
		Map<string, Map<string, FakeRow>>
	>();
	readonly queries: Array<{ collection: string; options: QueryOptions }> = [];
	readonly subscriptions = new Set<FakeSubscription>();
	private namespace = "public";

	/** Runs before a batch validates its conditions; used for CAS races. */
	beforeBatch: ((operations: BatchOperation[]) => void) | null = null;

	setNamespace(namespace: string): void {
		this.namespace = namespace;
	}

	private dataFor(namespace: string): Map<string, Map<string, FakeRow>> {
		let data = this.namespaceData.get(namespace);
		if (data === undefined) {
			data = new Map();
			this.namespaceData.set(namespace, data);
		}
		return data;
	}

	/** Fail queries whose limit exceeds this value with RESPONSE_TOO_LARGE. */
	maxQueryLimit = Number.POSITIVE_INFINITY;
	/** Queue of error codes thrown by the next `set` calls; `null` succeeds. */
	writeFailures: Array<string | null> = [];
	/** Runs before a query computes its result. */
	afterQuery: ((collection: string) => void) | null = null;
	/** Hold subscriptions until `releaseSubscriptions()` is called. */
	deferSubscribe = false;
	/** Hold the next successful `set` until `releaseSets()` is called. */
	pauseNextSet = false;
	/** Error code thrown after the paused write resumes. */
	failPausedSet: string | undefined;
	/** Number of store write attempts, including failed ones. */
	setAttempts = 0;

	private readonly subscribeResolvers: Array<() => void> = [];
	private readonly setResolvers: Array<() => void> = [];
	private errorFactory = (code: string): Error =>
		ZyncBaseError.fromServerResponse({ code, message: code });

	private clock = Date.now() * 1_000 - 60_000_000;

	setErrorFactory(factory: (code: string) => Error): void {
		this.errorFactory = factory;
	}

	get pendingSubscribeCount(): number {
		return this.subscribeResolvers.length;
	}

	get pausedSetCount(): number {
		return this.setResolvers.length;
	}

	releaseSubscriptions(): void {
		for (const resolve of this.subscribeResolvers.splice(0)) resolve();
	}

	releaseSets(): void {
		for (const resolve of this.setResolvers.splice(0)) resolve();
	}

	collection(name: string): Map<string, FakeRow> {
		return this.collectionIn(this.namespace, name);
	}

	private collectionIn(namespace: string, name: string): Map<string, FakeRow> {
		const data = this.dataFor(namespace);
		let rows = data.get(name);
		if (rows === undefined) {
			rows = new Map();
			data.set(name, rows);
		}
		return rows;
	}

	seed(
		collection: string,
		id: string,
		value: Record<string, JsonValue>,
		createdAt?: number,
	): FakeRow {
		const time = createdAt ?? this.clock++;
		const row = {
			...value,
			id,
			created_at: time,
			updated_at: time,
		} as FakeRow;
		this.collection(collection).set(id, row);
		this.notify(collection);
		return row;
	}

	patch(
		collection: string,
		id: string,
		value: Record<string, JsonValue>,
	): FakeRow | null {
		const existing = this.collection(collection).get(id);
		if (existing === undefined) return null;
		const row = {
			...existing,
			...value,
			id,
			created_at: existing.created_at,
			updated_at: this.clock++,
		} as FakeRow;
		this.collection(collection).set(id, row);
		this.notify(collection);
		return row;
	}

	delete(collection: string, id: string): void {
		if (this.collection(collection).delete(id)) this.notify(collection);
	}

	async set(path: string[], value: JsonValue): Promise<void> {
		this.setAttempts += 1;
		if (path.length !== 2)
			throw new Error("FakeStore only supports row writes");
		const failure = this.writeFailures.shift();
		if (failure !== undefined && failure !== null) {
			throw this.errorFactory(failure);
		}
		if (this.pauseNextSet) {
			this.pauseNextSet = false;
			await new Promise<void>((resolve) => this.setResolvers.push(resolve));
			if (this.failPausedSet !== undefined) {
				const code = this.failPausedSet;
				this.failPausedSet = undefined;
				throw this.errorFactory(code);
			}
		}
		if (!isPlainRecord(value)) throw new Error("Expected an object row");
		const [collection, id] = path as [string, string];
		const existing = this.collection(collection).get(id);
		const row = {
			...value,
			id,
			created_at: existing?.created_at ?? this.clock++,
			updated_at: this.clock++,
		} as FakeRow;
		this.collection(collection).set(id, row);
		this.notify(collection);
	}

	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: test fake mirrors the SDK's atomic batch semantics.
	async batch(operations: BatchOperation[]): Promise<void> {
		this.beforeBatch?.(operations);
		const backup = new Map<string, Map<string, FakeRow | undefined>>();
		const save = (collection: string, id: string): void => {
			let rows = backup.get(collection);
			if (rows === undefined) {
				rows = new Map();
				backup.set(collection, rows);
			}
			if (!rows.has(id)) rows.set(id, this.collection(collection).get(id));
		};

		for (const operation of operations) {
			const [collection, id] = operation.path as [string, string];
			save(collection, id);
			if (operation.if === undefined) continue;
			const row = this.collection(collection).get(id);
			if (row === undefined || !matches(row, operation.if)) {
				throw this.errorFactory("PRECONDITION_FAILED");
			}
		}

		const collections = new Set<string>();
		try {
			for (const operation of operations) {
				const [collection, id] = operation.path as [string, string];
				collections.add(collection);
				if (operation.op === "remove") {
					if (operation.path.length === 2) {
						this.collection(collection).delete(id);
					} else {
						const row = this.collection(collection).get(id);
						if (row !== undefined) {
							const field = operation.path[2] as string;
							const next = { ...row, updated_at: this.clock++ } as FakeRow;
							delete next[field];
							this.collection(collection).set(id, next);
						}
					}
					continue;
				}
				if (operation.op === "increment") {
					const existing = this.collection(collection).get(id) ?? {
						id,
						created_at: this.clock++,
						updated_at: this.clock++,
					};
					const row = { ...existing, updated_at: this.clock++ } as FakeRow;
					const field = operation.path[2] as string;
					const current = row[field];
					row[field] =
						(typeof current === "number" ? current : 0) + operation.by;
					this.collection(collection).set(id, row);
					continue;
				}
				if (operation.path.length === 2) {
					if (!isPlainRecord(operation.value)) {
						throw new Error("Expected an object row");
					}
					const existing = this.collection(collection).get(id);
					const row = {
						...operation.value,
						id,
						created_at: existing?.created_at ?? this.clock++,
						updated_at: this.clock++,
					} as FakeRow;
					this.collection(collection).set(id, row);
				} else {
					const existing = this.collection(collection).get(id) ?? {
						id,
						created_at: this.clock++,
						updated_at: this.clock++,
					};
					const row = {
						...existing,
						updated_at: this.clock++,
					} as FakeRow;
					row[operation.path[2] as string] =
						operation.value === undefined ? null : operation.value;
					this.collection(collection).set(id, row);
				}
			}
		} catch (error) {
			for (const [collection, rows] of backup) {
				for (const [id, row] of rows) {
					if (row === undefined) this.collection(collection).delete(id);
					else this.collection(collection).set(id, row);
				}
			}
			throw error;
		}
		for (const collection of collections) this.notify(collection);
	}

	async remove(path: string[]): Promise<void> {
		if (path.length !== 2)
			throw new Error("FakeStore only supports row removes");
		const [collection, id] = path as [string, string];
		if (this.collection(collection).delete(id)) this.notify(collection);
	}

	async get(path: string[]): Promise<JsonValue | null> {
		if (path.length !== 2) return null;
		const [collection, id] = path as [string, string];
		return this.collection(collection).get(id) ?? null;
	}

	async query(
		collection: string,
		options: QueryOptions = {},
	): Promise<JsonValue[] & { nextCursor: string | null }> {
		this.queries.push({ collection, options });
		if (options.limit !== undefined && options.limit > this.maxQueryLimit) {
			throw this.errorFactory("RESPONSE_TOO_LARGE");
		}
		this.afterQuery?.(collection);
		let rows = [...this.collection(collection).values()].filter((row) =>
			matches(row, options.where),
		);
		sortRows(rows, options.orderBy);
		if (options.after !== undefined) {
			const after = Number(options.after);
			rows = rows.filter((row) => row.created_at > after);
		}
		const limit = options.limit ?? Number.POSITIVE_INFINITY;
		const page = rows.slice(0, limit);
		const nextCursor =
			rows.length > page.length && page.length > 0
				? String(page[page.length - 1]?.created_at)
				: null;
		const result = page as unknown as JsonValue[] & {
			nextCursor: string | null;
		};
		result.nextCursor = nextCursor;
		return result;
	}

	async subscribe(
		collection: string,
		options: QueryOptions,
		callback: (rows: JsonValue[]) => void,
	): Promise<SubscriptionHandle> {
		if (this.deferSubscribe) {
			await new Promise<void>((resolve) =>
				this.subscribeResolvers.push(resolve),
			);
		}
		const startClock = this.clock;
		const matching = sortRows(
			[...this.collection(collection).values()].filter((row) =>
				matches(row, options.where),
			),
			options.orderBy,
		);
		const initial = matching.slice(0, options.limit ?? matching.length);
		const subscription: FakeSubscription = {
			namespace: this.namespace,
			collection,
			where: options.where,
			orderBy: options.orderBy ?? [{ created_at: "asc" }],
			initialIds: new Set(initial.map((row) => row.id)),
			startClock,
			callback,
		};
		this.subscriptions.add(subscription);
		callback(initial as JsonValue[]);
		return {
			unsubscribe: async () => {
				this.subscriptions.delete(subscription);
			},
			loadMore: async () => {},
			hasMore: false,
			getSnapshot: () => this.snapshot(subscription),
			pendingIds: new Set(),
		};
	}

	private snapshot(subscription: FakeSubscription): JsonValue[] {
		const rows = [
			...this.collectionIn(
				subscription.namespace,
				subscription.collection,
			).values(),
		].filter(
			(row) =>
				matches(row, subscription.where) &&
				(subscription.initialIds.has(row.id) ||
					row.created_at >= subscription.startClock),
		);
		return sortRows(rows, subscription.orderBy) as JsonValue[];
	}

	notify(collection: string): void {
		for (const subscription of [...this.subscriptions]) {
			if (subscription.collection !== collection) continue;
			if (subscription.namespace !== this.namespace) continue;
			subscription.callback(this.snapshot(subscription));
		}
	}
}

type Listener = (...args: unknown[]) => void;

/** Minimal stand-in for `ZyncBaseClient` used by provider tests. */
export class FakeClient {
	readonly store = new FakeStore();
	status: ConnectionStatus = "connected";
	connectCalls = 0;

	private readonly listeners = new Map<string, Set<Listener>>();

	async setStoreNamespace(namespace: string): Promise<void> {
		this.store.setNamespace(namespace);
	}

	async connect(): Promise<void> {
		this.connectCalls += 1;
		this.status = "connected";
		this.emit("statusChange", "connected");
		this.emit("connected");
		this.emit("synced");
	}

	disconnect(): void {
		this.status = "disconnected";
		this.emit("statusChange", "disconnected");
		this.emit("disconnected", {
			code: "CONNECTION_FAILED",
			reason: "disconnected",
			category: "network",
			retryable: true,
			attempt: 0,
		});
	}

	on(event: string, listener: Listener): void {
		let listeners = this.listeners.get(event);
		if (listeners === undefined) {
			listeners = new Set();
			this.listeners.set(event, listeners);
		}
		listeners.add(listener);
	}

	off(event: string, listener: Listener): void {
		this.listeners.get(event)?.delete(listener);
	}

	emit(event: string, ...args: unknown[]): void {
		for (const listener of [...(this.listeners.get(event) ?? [])]) {
			listener(...args);
		}
	}
}

export function asClient(client: FakeClient): ZyncBaseClient {
	return client as unknown as ZyncBaseClient;
}

export async function waitFor(
	predicate: () => boolean,
	timeoutMs = 2_000,
): Promise<void> {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		if (predicate()) return;
		await new Promise((resolve) => setTimeout(resolve, 5));
	}
	throw new Error("waitFor timed out");
}
