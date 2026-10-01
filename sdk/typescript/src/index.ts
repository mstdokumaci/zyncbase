// Public API re-exports

export { createClient, ZyncBaseClient } from "./client.js";
export {
	ActionError,
	ActionExecutionError,
	ActionTimeoutError,
	ActionValidationError,
	ErrorCodes,
	NoActionWorkerError,
	SchemaError,
	WorkerDisconnectedError,
	ZyncBaseError,
} from "./errors.js";
export type {
	ActionCallOptions,
	ActionContext,
	ActionHandler,
	ActionScope,
	Actions,
	AuthConfig,
	BatchOperation,
	ClientEvents,
	ClientOptions,
	ConnectionStatus,
	DisconnectDetail,
	JsonValue,
	LifecycleEvent,
	ListenHandle,
	Path,
	Presence,
	PresenceEntry,
	PresenceGetAllOptions,
	QueryOptions,
	SortClause,
	StatusDetail,
	Store,
	SubscriptionHandle,
	TicketResponse,
	WriteOptions,
} from "./types.js";
export { generateUUIDv7 } from "./uuid.js";
