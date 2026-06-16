// Public API re-exports

export { createClient, ZyncBaseClient } from "./client.js";
export { ErrorCodes, ZyncBaseError } from "./errors.js";
export type {
	AuthConfig,
	BatchOperation,
	ClientOptions,
	JsonValue,
	LifecycleEvent,
	Path,
	Presence,
	PresenceEntry,
	PresenceGetAllOptions,
	QueryOptions,
	Store,
	SubscriptionHandle,
	TicketResponse,
} from "./types.js";
export { generateUUIDv7 } from "./uuid.js";
