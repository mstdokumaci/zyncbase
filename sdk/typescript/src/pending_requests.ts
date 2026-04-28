export interface PendingEntry<TResponse, TContext = undefined> {
	resolve: (value: TResponse) => void;
	reject: (reason: unknown) => void;
	context: TContext;
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

	register(id: number, context: TContext): Promise<TResponse> {
		return new Promise((resolve, reject) => {
			this.entries.set(id, { resolve, reject, context });
		});
	}

	context(id: number): TContext | undefined {
		return this.entries.get(id)?.context;
	}

	resolve(id: number, value: TResponse): boolean {
		const entry = this.entries.get(id);
		if (!entry) return false;
		this.entries.delete(id);
		entry.resolve(value);
		return true;
	}

	reject(id: number, reason: unknown): boolean {
		const entry = this.entries.get(id);
		if (!entry) return false;
		this.entries.delete(id);
		entry.reject(reason);
		return true;
	}

	rejectAll(reason: unknown): void {
		const entries = Array.from(this.entries.values());
		this.entries.clear();
		for (const entry of entries) {
			entry.reject(reason);
		}
	}

	clear(): void {
		this.entries.clear();
	}

	get size(): number {
		return this.entries.size;
	}
}
