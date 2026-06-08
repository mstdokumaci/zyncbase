import { ErrorCodes, ZyncBaseError } from "./errors.js";
import type { ClientOptions } from "./types.js";

export class RetryPolicy {
	private options: ClientOptions;

	constructor(options: ClientOptions) {
		this.options = options;
	}

	shouldRetry(err: unknown, attempt: number): boolean {
		if (!(err instanceof ZyncBaseError)) return false;

		switch (err.code) {
			case ErrorCodes.RATE_LIMITED:
				return this.options.retryRateLimits !== false;

			case ErrorCodes.INTERNAL_ERROR:
			case ErrorCodes.ENGINE_UNHEALTHY:
				if (this.options.retryServerErrors === false) return false;
				return attempt < (this.options.maxServerRetries ?? 3);

			default:
				return false;
		}
	}

	getDelay(err: unknown, attempt: number): number {
		if (err instanceof ZyncBaseError && err.retryAfter != null) {
			return err.retryAfter;
		}

		const base = this.options.reconnectDelay ?? 1000;
		const maxDelay = this.options.maxReconnectDelay ?? 30_000;
		const preCap = base * 2 ** attempt;
		const jitter = preCap * 0.1 * (Math.random() * 2 - 1);
		return Math.min(preCap + jitter, maxDelay);
	}
}
