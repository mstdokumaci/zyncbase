// Store API

import type { OutboundRequest } from "./connection_wire.js";
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
	InboundMessage,
	JsonValue,
	LifecycleEvent,
	OkResponse,
	Path,
	QueryOptions,
	SubscriptionHandle,
	WriteOptions,
} from "./types.js";
import { generateUUIDv7 } from "./uuid.js";

/** The subset of ConnectionManager that StoreImpl depends on. */
export interface StoreConnection {
	dispatch(msg: OutboundRequest): Promise<OkResponse>;
	onMessage(handler: (msg: InboundMessage) => void): void;
	on(event: LifecycleEvent, handler: (...args: unknown[]) => void): void;
}

interface SubscribeState {
	subId: number | null;
	nextCursor: string | null;
	hasMore: boolean;
	closed: boolean;
}

export class StoreImpl {
	private readonly inFlightWrites = new Map<
		string,
		{ resolve: () => void; reject: (err: Error) => void }
	>();

	constructor(
		private readonly conn: StoreConnection,
		private readonly tracker: SubscriptionTracker,
		private readonly emitError: (err: ZyncBaseError) => void = () => {},
	) {
		this.conn.onMessage((msg) => this.handleInboundMessage(msg));
		this.conn.on("disconnected", () => this.rejectAllInFlight());
		this.conn.on("reconnecting", () => this.rejectAllInFlight());
	}

	async set(
		path: Path,
		value: JsonValue,
		options?: WriteOptions,
	): Promise<void> {
		const command = buildSet(path, value, options);
		await this.dispatchWrite(
			command.message,
			command.message.writeId,
			options,
			"Set failed",
		);
	}

	async remove(path: Path, options?: WriteOptions): Promise<void> {
		const command = buildRemove(path, options);
		await this.dispatchWrite(
			command.message,
			command.message.writeId,
			options,
			"Remove failed",
		);
	}

	async create(
		collection: string,
		value: JsonValue,
		options?: WriteOptions,
	): Promise<string> {
		const id = generateUUIDv7();
		const command = buildCreate(collection, value, id, options);
		await this.dispatchWrite(
			command.message,
			command.message.writeId,
			options,
			"Create failed",
		);
		return id;
	}

	async push(
		collection: string,
		value: JsonValue,
		options?: WriteOptions,
	): Promise<string> {
		return this.create(collection, value, options);
	}

	async update(
		path: Path,
		value: JsonValue,
		options?: WriteOptions,
	): Promise<void> {
		return this.set(path, value, options);
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

	async batch(
		operations: BatchOperation[],
		options?: WriteOptions,
	): Promise<void> {
		const message = buildBatch(operations, options);
		await this.dispatchWrite(message, message.writeId, options, "Batch failed");
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

	private async dispatchWrite(
		message: OutboundRequest,
		writeId: string | undefined,
		options: WriteOptions | undefined,
		fallbackMessage: string,
	): Promise<void> {
		if (options?.confirm === "committed") {
			if (!writeId) {
				throw new ZyncBaseError(
					"writeId is required for committed confirmation",
					{
						code: ErrorCodes.INVALID_MESSAGE,
						category: "client",
						retryable: false,
					},
				);
			}
			let commitResolve: () => void = () => {};
			let commitReject: (err: Error) => void = () => {};
			const commitPromise = new Promise<void>((resolve, reject) => {
				commitResolve = resolve;
				commitReject = reject;
			});
			this.inFlightWrites.set(writeId, {
				resolve: commitResolve,
				reject: commitReject,
			});
			try {
				await this.conn.dispatch(message);
			} catch (err) {
				this.inFlightWrites.delete(writeId);
				this.emitAndThrow(err, fallbackMessage);
			}
			try {
				await commitPromise;
			} catch (err) {
				this.emitAndThrow(err, fallbackMessage);
			}
		} else {
			await this.dispatchVoid(message, fallbackMessage);
		}
	}

	private async dispatchVoid(
		message: OutboundRequest,
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

	private rejectAllInFlight(): void {
		if (this.inFlightWrites.size === 0) return;
		const err = new ZyncBaseError(
			"Connection closed before write was confirmed",
			{
				code: ErrorCodes.CONNECTION_FAILED,
				category: "network",
				retryable: true,
			},
		);
		for (const pending of this.inFlightWrites.values()) {
			pending.reject(err);
		}
		this.inFlightWrites.clear();
	}

	private handleInboundMessage(msg: InboundMessage): void {
		if (msg.type === "WriteCommitted") {
			const pending = this.inFlightWrites.get(msg.writeId);
			if (pending) {
				pending.resolve();
				this.inFlightWrites.delete(msg.writeId);
			}
		} else if (msg.type === "WriteError") {
			const pending = this.inFlightWrites.get(msg.writeId);
			if (pending) {
				const details: Record<string, string | number> = {
					phase: msg.phase ?? "write",
				};
				if (msg.batchIndex !== undefined) details.batchIndex = msg.batchIndex;
				const error = ZyncBaseError.fromServerResponse({
					code: msg.code,
					message: msg.message,
					details,
				});
				pending.reject(error);
				this.inFlightWrites.delete(msg.writeId);
			}
		}
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
