import { describe, expect, test } from "bun:test";
import { ActionsImpl } from "./actions.js";
import type { OutboundRequest } from "./connection_wire.js";
import {
	ActionError,
	ActionExecutionError,
	ActionTimeoutError,
	ActionValidationError,
	ErrorCodes,
	NoActionWorkerError,
	WorkerDisconnectedError,
	ZyncBaseError,
} from "./errors.js";
import { SchemaDictionary } from "./schema_dictionary.js";
import type { ActionContext, ActionForward, OkResponse } from "./types.js";

async function setupSchema(schema: SchemaDictionary): Promise<void> {
	await schema.processSchemaSync({
		tables: ["users"],
		fields: [["id", "name"]],
		fieldFlags: [[3, 0]],
		actions: ["player_move", "checkout"],
		actionParams: [["direction", "seq"], ["cart_id"]],
		actionReturns: [[], ["order_id"]],
		// player_move: presence scope, async. checkout: store scope, sync.
		actionFlags: [0b10, 0b01],
	});
}

function createMockConnection(options?: {
	response?: OkResponse;
	error?: unknown;
	ready?: boolean;
}) {
	const schema = new SchemaDictionary();
	const dispatched: OutboundRequest[] = [];
	const replies: OutboundRequest[] = [];
	const sentFrames: Uint8Array[] = [];
	let forwardHandler: ((msg: ActionForward) => void) | null = null;

	return {
		dispatchNoRetry: (msg: OutboundRequest) => {
			dispatched.push(msg);
			if (options?.error) return Promise.reject(options.error);
			return Promise.resolve(
				options?.response ?? ({ type: "ok", id: 0 } as OkResponse),
			);
		},
		encodeOutbound: (msg: OutboundRequest) => {
			replies.push(msg);
			return new Uint8Array([0x01]);
		},
		send: (data: Uint8Array) => {
			sentFrames.push(data);
		},
		onActionForward: (handler: (msg: ActionForward) => void) => {
			forwardHandler = handler;
		},
		isSchemaReady: () => options?.ready ?? true,
		getStoreNamespace: () => "public",
		getPresenceNamespace: () => "public",
		schemaDictionary: schema,
		dispatched,
		replies,
		sentFrames,
		fireForward: (msg: ActionForward) => {
			forwardHandler?.(msg);
		},
	};
}

function nextTick(): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, 0));
}

describe("ActionsImpl.call", () => {
	test("resolves undefined for async actions", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schemaDictionary);
		const actions = new ActionsImpl(conn);

		const result = await actions.call("player_move", {
			direction: "up",
			seq: 3,
		});

		expect(result).toBeUndefined();
		expect(conn.dispatched).toHaveLength(1);
		expect(conn.dispatched[0]).toMatchObject({
			type: "ActionCall",
			action_id: "player_move",
			params: { direction: "up", seq: 3 },
		});
	});

	test("resolves actionResult for sync actions and forwards timeoutMs", async () => {
		const conn = createMockConnection({
			response: {
				type: "ok",
				id: 1,
				actionResult: { order_id: "o1" },
			},
		});
		await setupSchema(conn.schemaDictionary);
		const actions = new ActionsImpl(conn);

		const result = await actions.call(
			"checkout",
			{ cart_id: "c1" },
			{ timeoutMs: 500 },
		);

		expect(result).toEqual({ order_id: "o1" });
		expect(conn.dispatched[0]).toMatchObject({
			type: "ActionCall",
			action_id: "checkout",
			timeoutMs: 500,
		});
	});

	test("maps server action errors to public classes", async () => {
		await setupSchema(new SchemaDictionary());
		const cases: Array<[string, unknown]> = [
			[ErrorCodes.NO_ACTION_WORKER, NoActionWorkerError],
			[ErrorCodes.ACTION_TIMEOUT, ActionTimeoutError],
			[ErrorCodes.WORKER_DISCONNECTED, WorkerDisconnectedError],
			[ErrorCodes.SCHEMA_VALIDATION_FAILED, ActionValidationError],
		];

		for (const [code, expected] of cases) {
			const conn = createMockConnection({
				error: new ZyncBaseError("failed", {
					code,
					category: "server",
					retryable: false,
				}),
			});
			await setupSchema(conn.schemaDictionary);
			const actions = new ActionsImpl(conn);
			await expect(
				actions.call("checkout", { cart_id: "c1" }),
			).rejects.toBeInstanceOf(expected as never);
		}
	});

	test("maps custom worker codes to ActionExecutionError", async () => {
		const conn = createMockConnection({
			error: new ZyncBaseError("too poor", {
				code: "INSUFFICIENT_FUNDS",
				category: "unknown",
				retryable: false,
			}),
		});
		await setupSchema(conn.schemaDictionary);
		const actions = new ActionsImpl(conn);

		try {
			await actions.call("checkout", { cart_id: "c1" });
			throw new Error("expected rejection");
		} catch (err) {
			expect(err).toBeInstanceOf(ActionExecutionError);
			expect((err as ActionExecutionError).code).toBe("INSUFFICIENT_FUNDS");
		}
	});

	test("rejects unknown actions locally", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schemaDictionary);
		const actions = new ActionsImpl(conn);
		await expect(actions.call("nope")).rejects.toBeInstanceOf(
			ActionValidationError,
		);
	});
});

describe("ActionsImpl.handle", () => {
	test("throws SESSION_NOT_READY before the schema is ready", async () => {
		const conn = createMockConnection({ ready: false });
		await setupSchema(conn.schemaDictionary);
		const actions = new ActionsImpl(conn);

		expect(() => actions.handle("checkout", () => ({}))).toThrow(
			/SESSION_NOT_READY|not ready/,
		);
		await expect(
			actions.call("checkout", { cart_id: "c" }),
		).rejects.toMatchObject({
			code: ErrorCodes.SESSION_NOT_READY,
		});
	});

	test("registers handlers and replies with encoded returns", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schemaDictionary);
		const actions = new ActionsImpl(conn);
		const contexts: ActionContext[] = [];

		actions.handle("checkout", (ctx, params) => {
			contexts.push(ctx);
			return { order_id: `o-${params.cart_id}` };
		});

		expect(conn.dispatched[0]).toMatchObject({
			type: "ActionRegister",
			action_ids: ["checkout"],
		});

		conn.fireForward({
			type: "ActionForward",
			execId: 42,
			userId: "user-1",
			action_id: 1,
			params: [[0, "cart-9"]],
		});
		await nextTick();

		expect(contexts[0]).toMatchObject({
			userId: "user-1",
			namespace: "public",
			execId: 42,
		});
		expect(conn.replies).toHaveLength(1);
		expect(conn.replies[0]).toMatchObject({
			type: "ActionReply",
			execId: 42,
			ok: true,
			payload: [[0, "o-cart-9"]],
		});
		expect(conn.sentFrames).toHaveLength(1);
	});

	test("sends worker ActionError as an error tuple", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schemaDictionary);
		const actions = new ActionsImpl(conn);

		actions.handle("checkout", () => {
			throw new ActionError("INSUFFICIENT_FUNDS", "too poor");
		});
		conn.fireForward({
			type: "ActionForward",
			execId: 7,
			userId: "user-1",
			action_id: 1,
			params: [[0, "cart-1"]],
		});
		await nextTick();

		expect(conn.replies[0]).toMatchObject({
			type: "ActionReply",
			execId: 7,
			ok: false,
			payload: ["INSUFFICIENT_FUNDS", "too poor"],
		});
	});

	test("does not reply for async actions and reports handler errors", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schemaDictionary);
		const errors: ZyncBaseError[] = [];
		const actions = new ActionsImpl(conn, (err) => errors.push(err));
		let calls = 0;

		actions.handle("player_move", () => {
			calls += 1;
			throw new Error("boom");
		});
		conn.fireForward({
			type: "ActionForward",
			execId: 8,
			userId: "user-1",
			action_id: 0,
			params: [[0, "up"]],
		});
		await nextTick();

		expect(calls).toBe(1);
		expect(conn.replies).toHaveLength(0);
		expect(errors).toHaveLength(1);
	});

	test("ignores forwards for unregistered actions", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schemaDictionary);
		new ActionsImpl(conn);

		conn.fireForward({
			type: "ActionForward",
			execId: 9,
			userId: "user-1",
			action_id: 1,
			params: [[0, "cart-1"]],
		});
		await nextTick();

		expect(conn.replies).toHaveLength(0);
	});

	test("replayRegistrations re-sends registered handlers", async () => {
		const conn = createMockConnection();
		await setupSchema(conn.schemaDictionary);
		const actions = new ActionsImpl(conn);
		actions.handle("checkout", () => ({}));
		conn.dispatched.length = 0;

		actions.replayRegistrations();
		await nextTick();

		expect(conn.dispatched).toHaveLength(1);
		expect(conn.dispatched[0]).toMatchObject({
			type: "ActionRegister",
			action_ids: ["checkout"],
		});
	});
});
