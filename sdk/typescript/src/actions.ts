// Actions API — schema-validated client-to-worker calls and worker handlers.

import type { OutboundRequest } from "./connection_wire.js";
import {
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
import type {
	ActionSchemaEntry,
	SchemaDictionary,
} from "./schema_dictionary.js";
import type {
	ActionCallOptions,
	ActionContext,
	ActionForward,
	ActionHandler,
	Actions,
	JsonValue,
	OkResponse,
} from "./types.js";

/** The subset of ConnectionManager that ActionsImpl depends on. */
export interface ActionsConnection {
	/** Send a request without automatic retry (action calls are never retried). */
	dispatchNoRetry(msg: OutboundRequest): Promise<OkResponse>;
	/** Encode a one-way outbound message (ActionReply). */
	encodeOutbound(msg: OutboundRequest): Uint8Array;
	send(data: Uint8Array): void;
	onActionForward(handler: (msg: ActionForward) => void): void;
	isSchemaReady(): boolean;
	getStoreNamespace(): string;
	getPresenceNamespace(): string;
	readonly schemaDictionary: SchemaDictionary;
}

export class ActionsImpl implements Actions {
	private readonly handlers = new Map<string, ActionHandler>();
	private readonly conn: ActionsConnection;
	private readonly emitError: (err: ZyncBaseError) => void;

	constructor(
		conn: ActionsConnection,
		emitError: (err: ZyncBaseError) => void = () => {},
	) {
		this.conn = conn;
		this.emitError = emitError;
		this.conn.onActionForward((msg) => {
			void this.handleForward(msg);
		});
	}

	async call(
		name: string,
		params: Record<string, unknown> = {},
		options?: ActionCallOptions,
	): Promise<unknown> {
		const action = this.requireAction(name);
		this.requireReady();

		try {
			const message: OutboundRequest = {
				type: "ActionCall",
				action_id: name,
				params,
			};
			if (options?.timeoutMs !== undefined) {
				Object.assign(message, { timeoutMs: options.timeoutMs });
			}
			const ok = await this.conn.dispatchNoRetry(message);
			if (!action.hasReturns) return undefined;
			return ok.actionResult ?? {};
		} catch (err) {
			throw mapActionError(err);
		}
	}

	handle(name: string, handler: ActionHandler): void {
		this.requireAction(name);
		this.requireReady();
		this.handlers.set(name, handler);
		void this.register([name]);
	}

	/** Re-register all handlers after reconnect or a bound-scope namespace switch. */
	replayRegistrations(): void {
		if (this.handlers.size === 0 || !this.conn.isSchemaReady()) return;

		const names: string[] = [];
		for (const name of this.handlers.keys()) {
			try {
				this.conn.schemaDictionary.getAction(name);
				names.push(name);
			} catch {
				// Schema changed and the action no longer exists; drop the handler.
				this.handlers.delete(name);
			}
		}
		if (names.length > 0) void this.register(names);
	}

	private async register(names: string[]): Promise<void> {
		try {
			await this.conn.dispatchNoRetry({
				type: "ActionRegister",
				action_ids: names,
			});
		} catch (err) {
			this.emitError(mapActionError(err));
		}
	}

	private requireAction(name: string): ActionSchemaEntry {
		try {
			return this.conn.schemaDictionary.getAction(name);
		} catch (err) {
			if (err instanceof SchemaError) {
				throw new ActionValidationError(err.message);
			}
			throw err;
		}
	}

	private requireReady(): void {
		if (!this.conn.isSchemaReady()) {
			throw new ZyncBaseError("Scoped session is not ready", {
				code: ErrorCodes.SESSION_NOT_READY,
				category: "state",
				retryable: false,
			});
		}
	}

	private async handleForward(msg: ActionForward): Promise<void> {
		const name = this.actionNameFor(msg.action_id);
		if (name === null) return;
		const handler = this.handlers.get(name);
		if (!handler) return;

		const action = this.conn.schemaDictionary.getAction(name);
		let params: Record<string, JsonValue>;
		try {
			params = this.conn.schemaDictionary.decodeActionParams(
				action,
				msg.params,
			);
		} catch (err) {
			this.emitError(toZyncError(err, "Invalid action params"));
			return;
		}

		const ctx = this.buildContext(msg, action);

		// Async actions are fire-and-forget: no reply is sent.
		if (!action.hasReturns) {
			await this.runAsyncHandler(handler, ctx, params);
			return;
		}

		const reply = await this.runSyncHandler(action, handler, ctx, params);
		this.sendReply(msg.execId, reply.ok, reply.payload);
	}

	private actionNameFor(actionId: number): string | null {
		try {
			return this.conn.schemaDictionary.getActionName(actionId);
		} catch {
			return null;
		}
	}

	private buildContext(
		msg: ActionForward,
		action: ActionSchemaEntry,
	): ActionContext {
		return {
			userId: msg.userId,
			namespace:
				action.scope === "presence"
					? this.conn.getPresenceNamespace()
					: this.conn.getStoreNamespace(),
			execId: msg.execId,
		};
	}

	private async runAsyncHandler(
		handler: ActionHandler,
		ctx: ActionContext,
		params: Record<string, JsonValue>,
	): Promise<void> {
		try {
			await handler(ctx, params);
		} catch (err) {
			this.emitError(toZyncError(err, "Async action handler failed"));
		}
	}

	private async runSyncHandler(
		action: ActionSchemaEntry,
		handler: ActionHandler,
		ctx: ActionContext,
		params: Record<string, JsonValue>,
	): Promise<{ ok: boolean; payload: unknown }> {
		try {
			const result = await handler(ctx, params);
			return {
				ok: true,
				payload: this.conn.schemaDictionary.encodeActionReturns(
					action,
					(result ?? {}) as Record<string, JsonValue>,
				),
			};
		} catch (err) {
			// Keep internal failure details worker-local; callers get a generic error.
			if (!(err instanceof ActionError)) {
				this.emitError(toZyncError(err, "Sync action failed"));
			}
			return { ok: false, payload: actionErrorPayload(err) };
		}
	}

	private sendReply(execId: number, ok: boolean, payload: unknown): void {
		try {
			const bytes = this.conn.encodeOutbound({
				type: "ActionReply",
				execId,
				ok,
				payload,
			});
			this.conn.send(bytes);
		} catch (err) {
			this.emitError(toZyncError(err, "Failed to send action reply"));
		}
	}
}

/**
 * Map a raw request error into the public action error classes.
 * Passes transport/authorization/readiness errors through unchanged.
 */
export function mapActionError(err: unknown): ZyncBaseError {
	if (!(err instanceof ZyncBaseError)) {
		return toZyncError(err, "Action failed");
	}

	switch (err.code) {
		case ErrorCodes.NO_ACTION_WORKER:
			return new NoActionWorkerError(err.message, err.requestId);
		case ErrorCodes.ACTION_TIMEOUT:
			return new ActionTimeoutError(err.message, err.requestId);
		case ErrorCodes.WORKER_DISCONNECTED:
			return new WorkerDisconnectedError(err.message, err.requestId);
		case ErrorCodes.SCHEMA_VALIDATION_FAILED:
			return new ActionValidationError(err.message, err.requestId);
		case ErrorCodes.PERMISSION_DENIED:
		case ErrorCodes.SESSION_NOT_READY:
		case ErrorCodes.REQUEST_SUPERSEDED:
		case ErrorCodes.CONNECTION_FAILED:
		case ErrorCodes.RATE_LIMITED:
		case ErrorCodes.AUTH_FAILED:
		case ErrorCodes.TOKEN_EXPIRED:
			return err;
		default:
			if (err.category === "server" || err.category === "unknown") {
				return new ActionExecutionError(err.code, err.message, err.requestId);
			}
			return err;
	}
}

function toZyncError(err: unknown, fallback: string): ZyncBaseError {
	if (err instanceof ZyncBaseError) return err;
	return new ZyncBaseError(err instanceof Error ? err.message : fallback, {
		code: ErrorCodes.INTERNAL_ERROR,
		category: "server",
		retryable: false,
	});
}

function actionErrorPayload(err: unknown): unknown {
	if (err instanceof ActionError) {
		return [err.code, err.message];
	}
	return [ErrorCodes.INTERNAL_ERROR, "Action handler failed"];
}
