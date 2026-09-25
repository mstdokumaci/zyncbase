import {
	ActionError,
	ActionExecutionError,
	ActionValidationError,
	NoActionWorkerError,
	ZyncBaseError,
} from "@zyncbase/client";
import { ZyncBaseClient } from "./client";

function assert(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
}

function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

async function expectReject(
	promise: Promise<unknown>,
	message: string,
): Promise<unknown> {
	try {
		await promise;
	} catch (err) {
		return err;
	}
	throw new Error(message);
}

/** Worker registration is asynchronous; retry while the call races registration. */
async function callWithWorkerRetry(
	call: () => Promise<unknown>,
	attempts = 40,
): Promise<unknown> {
	for (let i = 0; i < attempts; i++) {
		try {
			return await call();
		} catch (err) {
			if (err instanceof NoActionWorkerError && i < attempts - 1) {
				await sleep(25);
				continue;
			}
			throw err;
		}
	}
	throw new Error("callWithWorkerRetry exhausted");
}

async function pollUntil(
	predicate: () => boolean,
	timeoutMs: number,
	message: string,
): Promise<void> {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		if (predicate()) return;
		await sleep(25);
	}
	throw new Error(message);
}

export async function run(port: number = 3000): Promise<void> {
	const caller = new ZyncBaseClient(`ws://127.0.0.1:${port}`);
	const worker = new ZyncBaseClient(`ws://127.0.0.1:${port}`);

	try {
		await caller.connect();

		// 1. No worker registered yet → NO_ACTION_WORKER.
		const noWorker = await expectReject(
			caller.actions.call("checkout", { cart_id: "c1" }),
			"expected NO_ACTION_WORKER before any worker registers",
		);
		assert(
			noWorker instanceof NoActionWorkerError,
			`expected NoActionWorkerError, got ${String(noWorker)}`,
		);

		// 2. Connect a worker and register handlers.
		await worker.connect();
		const contexts: Array<{
			userId: string;
			namespace: string;
			execId: number;
		}> = [];
		const moves: Array<Record<string, unknown>> = [];

		worker.actions.handle("checkout", (ctx, params) => {
			contexts.push(ctx);
			if (params.cart_id === "empty") {
				throw new ActionError("EMPTY_CART", "cart is empty");
			}
			return { order_id: `order-${params.cart_id}` };
		});
		worker.actions.handle("player_move", (_ctx, params) => {
			moves.push(params);
		});

		// 3. Sync action round-trip with typed returns.
		const result = (await callWithWorkerRetry(() =>
			caller.actions.call("checkout", { cart_id: "c1" }),
		)) as { order_id?: string };
		assert(
			result?.order_id === "order-c1",
			`unexpected sync result ${JSON.stringify(result)}`,
		);
		assert(contexts.length >= 1, "worker handler was not invoked");
		assert(
			contexts[0].execId > 0,
			`expected positive execId, got ${contexts[0].execId}`,
		);
		assert(
			contexts[0].namespace === "public",
			`unexpected namespace ${contexts[0].namespace}`,
		);
		assert(
			typeof contexts[0].userId === "string" && contexts[0].userId.length > 0,
			"expected a resolved userId in ActionContext",
		);

		// 4. Worker application error surfaces as ActionExecutionError.
		const execErr = await expectReject(
			caller.actions.call("checkout", { cart_id: "empty" }),
			"expected worker ActionError",
		);
		assert(
			execErr instanceof ActionExecutionError && execErr.code === "EMPTY_CART",
			`expected ActionExecutionError EMPTY_CART, got ${String(execErr)}`,
		);

		// 5. Input params validation.
		const validationErr = await expectReject(
			caller.actions.call("checkout", {}),
			"expected params validation failure",
		);
		assert(
			validationErr instanceof ActionValidationError,
			`expected ActionValidationError, got ${String(validationErr)}`,
		);

		// 6. Async fire-and-forget resolves on admission and delivers to the worker.
		const asyncResult = await caller.actions.call("player_move", {
			direction: "up",
			seq: 1,
		});
		assert(
			asyncResult === undefined,
			`async action should resolve undefined, got ${JSON.stringify(asyncResult)}`,
		);
		await pollUntil(
			() => moves.length === 1,
			2000,
			"worker did not receive the async action",
		);
		assert(
			moves[0].direction === "up",
			`unexpected async params ${JSON.stringify(moves[0])}`,
		);

		// 7. Invoke authorization denial stays PERMISSION_DENIED.
		const denied = await expectReject(
			caller.actions.call("locked", {}),
			"expected invoke denial",
		);
		assert(
			denied instanceof ZyncBaseError && denied.code === "PERMISSION_DENIED",
			`expected PERMISSION_DENIED, got ${String(denied)}`,
		);
	} finally {
		worker.close();
		caller.close();
	}
}
