import { ErrorCodes, ZyncBaseError } from "./errors.js";

export interface PendingEntry<TResponse, TContext = undefined> {
	resolve: (value: TResponse) => void;
	reject: (reason: unknown) => void;
	context: TContext;
	timer?: ReturnType<typeof setTimeout>;
}

export class PendingRequests<TResponse, TContext = undefined> {
	private nextRequestId = 1;
	private readonly entries = new Map<
		number,
		PendingEntry<TResponse, TContext>
	>();

	nextId(): number {
		return this.nextRequestId++;
	}

	/** With `timeoutMs`, the request rejects with TIMEOUT when no outcome arrives in time. */
	register(
		id: number,
		context: TContext,
		timeoutMs?: number,
	): Promise<TResponse> {
		return new Promise((resolve, reject) => {
			const entry: PendingEntry<TResponse, TContext> = {
				resolve,
				reject,
				context,
			};
			if (timeoutMs !== undefined) {
				entry.timer = setTimeout(() => {
					this.reject(
						id,
						new ZyncBaseError(
							`Write outcome not received within ${timeoutMs} ms; the write may still commit`,
							{
								code: ErrorCodes.TIMEOUT,
								category: "network",
								retryable: true,
								requestId: id,
							},
						),
					);
				}, timeoutMs);
			}
			this.entries.set(id, entry);
		});
	}

	context(id: number): TContext | undefined {
		return this.entries.get(id)?.context;
	}

	resolve(id: number, value: TResponse): boolean {
		const entry = this.take(id);
		if (!entry) return false;
		entry.resolve(value);
		return true;
	}

	reject(id: number, reason: unknown): boolean {
		const entry = this.take(id);
		if (!entry) return false;
		entry.reject(reason);
		return true;
	}

	rejectAll(reason: unknown): void {
		const entries = Array.from(this.entries.values());
		this.clear();
		for (const entry of entries) {
			entry.reject(reason);
		}
	}

	clear(): void {
		for (const entry of this.entries.values()) clearTimeout(entry.timer);
		this.entries.clear();
	}

	get size(): number {
		return this.entries.size;
	}

	private take(id: number): PendingEntry<TResponse, TContext> | undefined {
		const entry = this.entries.get(id);
		if (!entry) return undefined;
		this.entries.delete(id);
		clearTimeout(entry.timer);
		return entry;
	}
}
