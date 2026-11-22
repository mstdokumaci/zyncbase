import { ZyncBaseClient } from "./client";

/**
 * A store-only app connects and writes without presence authorization; only
 * a presence call needs it, and only that call fails.
 */
export async function run(port: number): Promise<void> {
	const client = new ZyncBaseClient(`ws://127.0.0.1:${port}`);
	try {
		await client.connect();
		await client.store.set(["tasks", "store-only"], { title: "no presence" });
		const task = await client.store.get(["tasks", "store-only"]);
		if ((task as { title?: unknown } | null)?.title !== "no presence") {
			throw new Error(`Expected the stored task, got ${JSON.stringify(task)}`);
		}

		const denied = await client.presence.set({}).then(
			() => null,
			(err: { code?: string }) => err.code,
		);
		if (denied !== "NAMESPACE_UNAUTHORIZED") {
			throw new Error(`Expected NAMESPACE_UNAUTHORIZED, got ${denied}`);
		}
		if (client.status !== "connected") {
			throw new Error(
				`Expected the session to stay connected, got ${client.status}`,
			);
		}
		console.log("E2E store-only session passed.");
	} finally {
		client.close();
	}
}
