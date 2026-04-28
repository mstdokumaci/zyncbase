// Store API

import type { ConnectionManager } from "./connection.js";
import { ErrorCodes, ZyncBaseError } from "./errors.js";
import {
	buildBatch,
	buildCreate,
	buildGet,
	buildListen,
	buildLoadMore,
	buildQuery,
	buildRemove,
	buildSet,
	buildSubscribe,
	buildUnsubscribe,
	shapeGetResult,
	shapeQueryResult,
} from "./store_wire.js";
import type { SubscriptionTracker } from "./subscriptions.js";
import type {
	BatchOperation,
	JsonValue,
	OkResponse,
	Path,
	QueryOptions,
	SubscriptionHandle,
} from "./types.js";
import { generateUUIDv7 } from "./uuid.js";

interface SubscribeState {
	subId: number | null;
	nextCursor: string | null;
	hasMore: boolean;
	closed: boolean;
}

export class StoreImpl {
	constructor(
		private readonly conn: ConnectionManager,
		private readonly tracker: SubscriptionTracker,
		private readonly emitError: (err: ZyncBaseError) => void = () => {},
	) {}

	async set(path: Path, value: JsonValue): Promise<void> {
		const command = buildSet(path, value);
		await this.dispatchVoid(command.message, "Set failed");
	}

	async remove(path: Path): Promise<void> {
		const command = buildRemove(path);
		await this.dispatchVoid(command.message, "Remove failed");
	}

	async create(collection: string, value: JsonValue): Promise<string> {
		const id = generateUUIDv7();
		const command = buildCreate(collection, value, id);
		await this.dispatchVoid(command.message, "Create failed");
		return id;
	}

	async push(collection: string, value: JsonValue): Promise<string> {
		return this.create(collection, value);
	}

	async update(path: Path, value: JsonValue): Promise<void> {
		return this.set(path, value);
	}

	async get(path: Path): Promise<JsonValue | null | undefined> {
		const command = buildGet(path);
		try {
			const ok = await this.conn.dispatch(command.message);
			return shapeGetResult(command.segments, (ok.value ?? []) as JsonValue[]);
		} catch (err) {
			this.emitAndThrow(err, "Get failed");
		}
	}

	async query(
		collection: string,
		options?: QueryOptions,
	): Promise<JsonValue[] & { nextCursor: string | null }> {
		const command = buildQuery(collection, options);
		try {
			const ok = await this.conn.dispatch(command.message);
			return shapeQueryResult(ok);
		} catch (err) {
			this.emitAndThrow(err, "Query failed");
		}
	}

	async batch(operations: BatchOperation[]): Promise<void> {
		const message = buildBatch(operations);
		await this.dispatchVoid(message, "Batch failed");
	}

	listen(path: Path, callback: (value: JsonValue) => void): () => void {
		const command = buildListen(path);
		const state = {
			closed: false,
			subId: null as number | null,
		};

		this.conn
			.dispatch(command.message)
			.then((ok) => {
				if (state.closed) {
					if (ok.subId !== undefined) {
						this.dispatchUnsubscribe(ok.subId);
					}
					return;
				}

				state.subId = ok.subId ?? null;
				if (state.subId === null) return;

				this.tracker.registerListen(
					state.subId,
					command.message,
					callback,
					command.segments,
				);
				if (ok.value !== undefined) {
					this.tracker.dispatchInitialSnapshot(
						state.subId,
						command.segments,
						ok.value as JsonValue,
					);
				}
			})
			.catch((err) => this.emitOnly(err, "Listen failed"));

		return () => {
			state.closed = true;
			if (state.subId === null) return;
			this.tracker.unregister(state.subId);
			this.dispatchUnsubscribe(state.subId);
			state.subId = null;
		};
	}

	subscribe(
		collection: string,
		options: QueryOptions,
		callback: (results: JsonValue[]) => void,
	): SubscriptionHandle {
		const command = buildSubscribe(collection, options);
		const state: SubscribeState = {
			subId: null,
			nextCursor: null,
			hasMore: false,
			closed: false,
		};

		const handle: SubscriptionHandle = {
			hasMore: false,
			unsubscribe: () => {
				state.closed = true;
				if (state.subId === null) return;
				this.tracker.unregister(state.subId);
				this.dispatchUnsubscribe(state.subId);
				state.subId = null;
			},
			loadMore: async () => {
				if (state.subId === null || state.nextCursor === null) return;
				const ok = await this.conn.dispatch(
					buildLoadMore(state.subId, state.nextCursor, collection),
				);
				state.nextCursor = ok.nextCursor ?? null;
				state.hasMore = ok.hasMore ?? false;
				handle.hasMore = state.hasMore;
				if (state.subId !== null && ok.value !== undefined) {
					this.tracker.dispatchInitialSnapshot(
						state.subId,
						[collection],
						ok.value as JsonValue,
					);
				}
			},
		};

		this.conn
			.dispatch(command.message)
			.then((ok) =>
				this.handleSubscribeSuccess(
					ok,
					state,
					handle,
					command.message,
					collection,
					options,
					callback,
				),
			)
			.catch((err) => this.emitOnly(err, "Subscribe failed"));

		return handle;
	}

	private handleSubscribeSuccess(
		ok: OkResponse,
		state: SubscribeState,
		handle: SubscriptionHandle,
		params: Parameters<SubscriptionTracker["registerCollection"]>[1],
		collection: string,
		options: QueryOptions,
		callback: (results: JsonValue[]) => void,
	): void {
		if (this.unsubscribeRemoteIfClosed(state.closed, ok.subId)) return;

		state.subId = ok.subId ?? null;
		state.nextCursor = ok.nextCursor ?? null;
		state.hasMore = ok.hasMore ?? false;
		handle.hasMore = state.hasMore;
		if (state.subId === null) return;

		this.tracker.registerCollection(
			state.subId,
			params,
			callback,
			collection,
			options.orderBy,
		);
		if (ok.value !== undefined) {
			this.tracker.dispatchInitialSnapshot(
				state.subId,
				[collection],
				ok.value as JsonValue,
			);
		}
	}

	private async dispatchVoid(
		message: Parameters<ConnectionManager["dispatch"]>[0],
		fallbackMessage: string,
	): Promise<void> {
		try {
			await this.conn.dispatch(message);
		} catch (err) {
			this.emitAndThrow(err, fallbackMessage);
		}
	}

	private dispatchUnsubscribe(subId: number): void {
		this.conn.dispatch(buildUnsubscribe(subId)).catch(() => {});
	}

	private unsubscribeRemoteIfClosed(closed: boolean, subId?: number): boolean {
		if (!closed) return false;
		if (subId !== undefined) {
			this.dispatchUnsubscribe(subId);
		}
		return true;
	}

	private emitOnly(err: unknown, fallbackMessage: string): void {
		this.emitError(this.normalizeError(err, fallbackMessage));
	}

	private emitAndThrow(err: unknown, fallbackMessage: string): never {
		const error = this.normalizeError(err, fallbackMessage);
		this.emitError(error);
		throw error;
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
}
