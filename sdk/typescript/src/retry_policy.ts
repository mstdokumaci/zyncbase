import { ErrorCodes, ZyncBaseError } from "./errors.js";
import type { ClientOptions } from "./types.js";

/**
 * Exponential backoff with ±10% jitter, capped at `max`.
 * `attempt` is capped at 30 so `2 ** attempt` can never overflow to Infinity.
 */
export function backoffDelay(
	attempt: number,
	opts?: { base?: number; max?: number; jitter?: boolean },
): number {
	const base = opts?.base ?? 1000;
	const max = opts?.max ?? 30_000;
	const preCap = base * 2 ** Math.min(attempt, 30);
	const jitter =
		(opts?.jitter ?? true) ? preCap * 0.1 * (Math.random() * 2 - 1) : 0;
	return Math.min(preCap + jitter, max);
}

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

		return backoffDelay(attempt, {
			base: this.options.reconnectDelay,
			max: this.options.maxReconnectDelay,
			jitter: this.options.reconnectJitter,
		});
	}
}
