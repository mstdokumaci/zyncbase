// Public API re-exports

export { createClient, ZyncBaseClient } from "./client.js";
export { ErrorCodes, ZyncBaseError } from "./errors.js";
export type {
	BatchOperation,
	ClientOptions,
	JsonValue,
	LifecycleEvent,
	Path,
	QueryOptions,
	Store,
	SubscriptionHandle,
} from "./types.js";
export { generateUUIDv7 } from "./uuid.js";
