import type { ZyncBaseClient } from "../client.js";
import type { SchemaLike } from "../types.js";
import { YjsCompactor, type YjsCompactorOptions } from "./compactor_impl.js";

export type {
	YjsCompactedEvent,
	YjsCompactorErrorContext,
	YjsCompactorOptions,
	YjsCompactorPhase,
} from "./compactor_impl.js";

export interface YjsCompactorHandle {
	/** Whether the worker loop is active. */
	readonly running: boolean;
	/** Stop the loop and wait for the current pass. */
	stop(): Promise<void>;
}

/**
 * Start a long-running Yjs compactor.
 *
 * Start the worker in an app server or a background Bun worker and call
 * `stop()` on shutdown. The app owns the client connection and connects a
 * dedicated client first.
 */
export function startYjsCompactor<
	S extends object = SchemaLike,
	A = never,
	P = never,
>(
	client: ZyncBaseClient<S, A, P>,
	options: YjsCompactorOptions<S> = {},
): YjsCompactorHandle {
	const worker = new YjsCompactor(client, options);
	worker.start();
	return {
		get running() {
			return worker.running;
		},
		stop: () => worker.stop(),
	};
}
