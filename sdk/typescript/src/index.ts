// Public API re-exports

export { createClient, ZyncBaseClient } from "./client.js";
export { ZyncBaseError, ErrorCodes } from "./errors.js";
export { generateUUIDv7 } from "./uuid.js";
export type {
  ClientOptions,
  Store,
  Path,
  QueryOptions,
  BatchOperation,
  SubscriptionHandle,
  LifecycleEvent,
} from "./types.js";
