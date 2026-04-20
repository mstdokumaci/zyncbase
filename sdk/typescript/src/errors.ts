// ZyncBaseError and ErrorCodes
import type { JsonValue } from "./types.js";

export const ErrorCodes = {
	AUTH_FAILED: "AUTH_FAILED",
	TOKEN_EXPIRED: "TOKEN_EXPIRED",
	NAMESPACE_UNAUTHORIZED: "NAMESPACE_UNAUTHORIZED",
	PERMISSION_DENIED: "PERMISSION_DENIED",
	COLLECTION_NOT_FOUND: "COLLECTION_NOT_FOUND",
	SCHEMA_VALIDATION_FAILED: "SCHEMA_VALIDATION_FAILED",
	FIELD_NOT_FOUND: "FIELD_NOT_FOUND",
	INVALID_FIELD_NAME: "INVALID_FIELD_NAME",
	INVALID_ARRAY_ELEMENT: "INVALID_ARRAY_ELEMENT",
	INVALID_MESSAGE: "INVALID_MESSAGE",
	RATE_LIMITED: "RATE_LIMITED",
	MESSAGE_TOO_LARGE: "MESSAGE_TOO_LARGE",
	CONNECTION_FAILED: "CONNECTION_FAILED",
	TIMEOUT: "TIMEOUT",
	INTERNAL_ERROR: "INTERNAL_ERROR",
	INVALID_PATH: "INVALID_PATH",
	BATCH_TOO_LARGE: "BATCH_TOO_LARGE",
} as const;

export type ErrorCode = (typeof ErrorCodes)[keyof typeof ErrorCodes];

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
		case ErrorCodes.NAMESPACE_UNAUTHORIZED:
		case ErrorCodes.PERMISSION_DENIED:
			return { category: "auth", retryable: false };

		case ErrorCodes.RATE_LIMITED:
			return { category: "rate_limit", retryable: true };

		case ErrorCodes.INTERNAL_ERROR:
			return { category: "server", retryable: true };

		case ErrorCodes.SCHEMA_VALIDATION_FAILED:
		case ErrorCodes.FIELD_NOT_FOUND:
		case ErrorCodes.INVALID_FIELD_NAME:
		case ErrorCodes.INVALID_ARRAY_ELEMENT:
		case ErrorCodes.INVALID_MESSAGE:
		case ErrorCodes.COLLECTION_NOT_FOUND:
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
		public readonly code: "TABLE_NOT_FOUND" | "FIELD_NOT_FOUND",
	) {
		super(message);
		this.name = "SchemaError";
		Object.setPrototypeOf(this, SchemaError.prototype);
	}
}

