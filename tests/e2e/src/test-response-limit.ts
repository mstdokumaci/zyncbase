import { ZyncBaseClient } from "./client";

export async function run(port: number = 3000) {
	const client = new ZyncBaseClient(`ws://127.0.0.1:${port}`);

	try {
		console.log("Connecting client...");
		await client.connect();
		console.log("Client connected.");

		await testResponseTooLarge(client);

		console.log("All query response limit tests passed!");
	} catch (err) {
		console.error("Test failed:", err);
		throw err;
	} finally {
		client.close();
	}
}

async function testResponseTooLarge(client: ZyncBaseClient) {
	console.log("Testing RESPONSE_TOO_LARGE...");
	await client.setNamespace("public");

	const title = "x".repeat(120);
	const committed = { confirm: "committed" } as const;
	for (let i = 0; i < 12; i++) {
		await client.store.set(["tasks", `task-${i}`], { title }, committed);
	}

	let tooLargeError: { code?: string } | undefined;
	try {
		await client.store.query("tasks");
	} catch (err: unknown) {
		tooLargeError = err as { code?: string };
	}
	if (tooLargeError === undefined) {
		throw new Error("Expected unbounded query to exceed the response limit");
	}
	if (tooLargeError.code !== "RESPONSE_TOO_LARGE") {
		throw new Error(
			`Expected RESPONSE_TOO_LARGE but got ${tooLargeError.code}`,
		);
	}
	console.log("RESPONSE_TOO_LARGE verified.");

	const rows = await client.store.query("tasks", { limit: 1 });
	if (rows.length !== 1) {
		throw new Error(`Expected 1 row under the limit but got ${rows.length}`);
	}
	console.log("Under-limit query succeeded after the rejection.");
}
