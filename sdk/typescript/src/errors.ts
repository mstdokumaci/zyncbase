// ZyncBaseError and ErrorCodes
import type { JsonValue } from "./types.js";

export const ErrorCodes = {
	AUTH_FAILED: "AUTH_FAILED",
	TOKEN_EXPIRED: "TOKEN_EXPIRED",
	SESSION_NOT_READY: "SESSION_NOT_READY",
	NAMESPACE_UNAUTHORIZED: "NAMESPACE_UNAUTHORIZED",
	PERMISSION_DENIED: "PERMISSION_DENIED",
	COLLECTION_NOT_FOUND: "COLLECTION_NOT_FOUND",
	SCHEMA_VALIDATION_FAILED: "SCHEMA_VALIDATION_FAILED",
	UNIQUE_CONSTRAINT_VIOLATED: "UNIQUE_CONSTRAINT_VIOLATED",
	FIELD_NOT_FOUND: "FIELD_NOT_FOUND",
	INVALID_FIELD_NAME: "INVALID_FIELD_NAME",
	INVALID_ARRAY_ELEMENT: "INVALID_ARRAY_ELEMENT",
	INVALID_MESSAGE: "INVALID_MESSAGE",
	RATE_LIMITED: "RATE_LIMITED",
	MESSAGE_TOO_LARGE: "MESSAGE_TOO_LARGE",
	CONNECTION_FAILED: "CONNECTION_FAILED",
	TIMEOUT: "TIMEOUT",
	INTERNAL_ERROR: "INTERNAL_ERROR",
	ENGINE_UNHEALTHY: "ENGINE_UNHEALTHY",
	INVALID_PATH: "INVALID_PATH",
	BATCH_TOO_LARGE: "BATCH_TOO_LARGE",
	REQUEST_SUPERSEDED: "REQUEST_SUPERSEDED",
	NAMESPACE_SWITCH_REJECTED: "NAMESPACE_SWITCH_REJECTED",
	IMMUTABLE_FIELD: "IMMUTABLE_FIELD",
	INVALID_MESSAGE_FORMAT: "INVALID_MESSAGE_FORMAT",
	INVALID_MESSAGE_TYPE: "INVALID_MESSAGE_TYPE",
	SUBSCRIPTION_NOT_FOUND: "SUBSCRIPTION_NOT_FOUND",
	NO_ACTION_WORKER: "NO_ACTION_WORKER",
	ACTION_TIMEOUT: "ACTION_TIMEOUT",
	WORKER_DISCONNECTED: "WORKER_DISCONNECTED",
} as const;

interface ZyncBaseErrorOptions {
	code: string;
	category: string;
	retryable: boolean;
	retryAfter?: number;
	requestId?: number;
	path?: string[];
	details?: Record<string, JsonValue>;
}

function deriveCategory(code: string): {
	category: string;
	retryable: boolean;
} {
	switch (code) {
		case ErrorCodes.AUTH_FAILED:
		case ErrorCodes.TOKEN_EXPIRED:
			return { category: "authentication", retryable: false };

		case ErrorCodes.NAMESPACE_UNAUTHORIZED:
		case ErrorCodes.PERMISSION_DENIED:
			return { category: "authorization", retryable: false };

		case ErrorCodes.SESSION_NOT_READY:
		case ErrorCodes.REQUEST_SUPERSEDED:
		case ErrorCodes.NAMESPACE_SWITCH_REJECTED:
		case ErrorCodes.SUBSCRIPTION_NOT_FOUND:
		case ErrorCodes.NO_ACTION_WORKER:
			return { category: "state", retryable: false };

		case ErrorCodes.RATE_LIMITED:
			return { category: "rate_limit", retryable: true };

		case ErrorCodes.ACTION_TIMEOUT:
		case ErrorCodes.WORKER_DISCONNECTED:
			// Server category, but action calls are never auto-retried.
			return { category: "server", retryable: false };

		case ErrorCodes.INTERNAL_ERROR:
			return { category: "server", retryable: true };

		case ErrorCodes.ENGINE_UNHEALTHY:
			return { category: "server", retryable: true };

		case ErrorCodes.SCHEMA_VALIDATION_FAILED:
		case ErrorCodes.UNIQUE_CONSTRAINT_VIOLATED:
		case ErrorCodes.FIELD_NOT_FOUND:
		case ErrorCodes.INVALID_FIELD_NAME:
		case ErrorCodes.INVALID_ARRAY_ELEMENT:
		case ErrorCodes.INVALID_MESSAGE:
		case ErrorCodes.COLLECTION_NOT_FOUND:
		case ErrorCodes.IMMUTABLE_FIELD:
		case ErrorCodes.INVALID_MESSAGE_FORMAT:
		case ErrorCodes.INVALID_MESSAGE_TYPE:
			return { category: "validation", retryable: false };

		case ErrorCodes.CONNECTION_FAILED:
		case ErrorCodes.TIMEOUT:
			return { category: "network", retryable: true };

		case ErrorCodes.INVALID_PATH:
		case ErrorCodes.BATCH_TOO_LARGE:
		case ErrorCodes.MESSAGE_TOO_LARGE:
			return { category: "client", retryable: false };

		default:
			return { category: "unknown", retryable: false };
	}
}

export class ZyncBaseError extends Error {
	code: string;
	category: string;
	retryable: boolean;
	retryAfter?: number;
	requestId?: number;
	path?: string[];
	details?: Record<string, JsonValue>;

	constructor(message: string, options: ZyncBaseErrorOptions) {
		super(message);
		this.name = "ZyncBaseError";
		this.code = options.code;
		this.category = options.category;
		this.retryable = options.retryable;
		this.retryAfter = options.retryAfter;
		this.requestId = options.requestId;
		this.path = options.path;
		this.details = options.details;

		// Restore prototype chain for instanceof checks
		Object.setPrototypeOf(this, new.target.prototype);
	}

	static fromServerResponse(payload: {
		code: string;
		message: string;
		retryAfter?: number;
		requestId?: number;
		path?: string[];
		details?: Record<string, JsonValue>;
	}): ZyncBaseError {
		const { category, retryable } = deriveCategory(payload.code);
		return new ZyncBaseError(payload.message, {
			code: payload.code,
			category,
			retryable,
			retryAfter: payload.retryAfter,
			requestId: payload.requestId,
			path: payload.path,
			details: payload.details,
		});
	}
}

/** Error thrown by SchemaDictionary when a lookup fails. */
export class SchemaError extends Error {
	constructor(
		message: string,
		public readonly code:
			| "TABLE_NOT_FOUND"
			| "FIELD_NOT_FOUND"
			| "ACTION_NOT_FOUND"
			| "INVALID_PATH",
	) {
		super(message);
		this.name = "SchemaError";
		Object.setPrototypeOf(this, SchemaError.prototype);
	}
}

// ─── Action errors ────────────────────────────────────────────────────────────

/** No connected worker is registered for the action in the bound namespace. */
export class NoActionWorkerError extends ZyncBaseError {
	constructor(message: string, requestId?: number) {
		super(message, {
			code: ErrorCodes.NO_ACTION_WORKER,
			category: "state",
			retryable: false,
			requestId,
		});
		this.name = "NoActionWorkerError";
	}
}

/** Worker failed to reply before the server deadline; the action may still execute. */
export class ActionTimeoutError extends ZyncBaseError {
	constructor(message: string, requestId?: number) {
		super(message, {
			code: ErrorCodes.ACTION_TIMEOUT,
			category: "server",
			retryable: false,
			requestId,
		});
		this.name = "ActionTimeoutError";
	}
}

/** Worker disconnected while processing a sync action; it may have partially executed. */
export class WorkerDisconnectedError extends ZyncBaseError {
	constructor(message: string, requestId?: number) {
		super(message, {
			code: ErrorCodes.WORKER_DISCONNECTED,
			category: "server",
			retryable: false,
			requestId,
		});
		this.name = "WorkerDisconnectedError";
	}
}

/** Input params or worker return payload violated schema constraints. */
export class ActionValidationError extends ZyncBaseError {
	constructor(message: string, requestId?: number) {
		super(message, {
			code: ErrorCodes.SCHEMA_VALIDATION_FAILED,
			category: "validation",
			retryable: false,
			requestId,
		});
		this.name = "ActionValidationError";
	}
}

/** Worker threw an application-level ActionError carrying a custom code. */
export class ActionExecutionError extends ZyncBaseError {
	constructor(code: string, message: string, requestId?: number) {
		super(message, {
			code,
			category: "server",
			retryable: false,
			requestId,
		});
		this.name = "ActionExecutionError";
	}
}

/** Error thrown by worker handlers to send a structured error back to the caller. */
export class ActionError extends Error {
	readonly code: string;

	constructor(code: string, message: string) {
		super(message);
		this.name = "ActionError";
		this.code = code;
		Object.setPrototypeOf(this, ActionError.prototype);
	}
}
