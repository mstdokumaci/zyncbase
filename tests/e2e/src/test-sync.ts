import { ZyncBaseClient } from "./client";

/** Mock Task for testing */
interface MockTask {
	id: string;
	title?: string;
	tags?: string[] | null;
	must_be_complete?: { before: number | null; after: number | null } | null;
}

/**
 * Wait for a store.listen callback to satisfy a predicate within a timeout.
 * Resolves with the value when the predicate returns truthy, rejects on timeout.
 */
function waitForListen<T>(
	client: ZyncBaseClient,
	path: string[],
	predicate: (val: MockTask) => T | null | undefined | false,
	timeoutMs = 2000,
): Promise<T> {
	return new Promise<T>((resolve, reject) => {
		const timer = setTimeout(() => {
			unlisten();
			reject(
				new Error(`Timeout waiting for ${path.join(".")} after ${timeoutMs}ms`),
			);
		}, timeoutMs);

		const unlisten = client.store.listen(path, (val: unknown) => {
			const result = predicate(val as MockTask);
			if (result) {
				clearTimeout(timer);
				unlisten();
				resolve(result as T);
			}
		});
	});
}

export async function run(port: number = 3000) {
	const clientA = new ZyncBaseClient(`ws://127.0.0.1:${port}`);
	const clientB = new ZyncBaseClient(`ws://127.0.0.1:${port}`);

	try {
		console.log("Connecting clients...");
		await Promise.all([clientA.connect(), clientB.connect()]);
		console.log("Clients connected.");

		const namespace = "public";

		// 1. Client A sets task 1 with tags
		console.log("Client A setting task 1...");
		await clientA.set(namespace, ["tasks", "1"], {
			title: "A's Task",
			tags: ["home", "urgent"],
		});

		// 2. Client B listens for task 1 via store.listen (bi-directional sync: A sets → B fires)
		console.log("Client B waiting for task 1 via store.listen...");
		const task1 = await waitForListen(clientB, ["tasks", "1"], (val) =>
			val?.title === "A's Task" &&
				Array.isArray(val.tags) &&
				val.tags.includes("urgent")
				? val
				: null,
		);
		console.log("Client B received task 1:", task1);

		// 3. Client B sets task 2 with tags
		console.log("Client B setting task 2...");
		await clientB.set(namespace, ["tasks", "2"], {
			title: "B's Task",
			tags: ["work"],
		});

		// 4. Client A listens for task 2 via store.listen (bi-directional sync: B sets → A fires)
		console.log("Client A waiting for task 2 via store.listen...");
		const task2 = await waitForListen(clientA, ["tasks", "2"], (val) =>
			val?.title === "B's Task" &&
				Array.isArray(val.tags) &&
				val.tags.includes("work")
				? val
				: null,
		);
		console.log("Client A received task 2:", task2);

		// 5. Test nested object flatten/unflatten transparency (must_be_complete)
		console.log("Testing nested object (must_be_complete)...");
		const beforeTs = Math.floor(Date.now() / 1000);
		const afterTs = beforeTs + 3600;
		await clientA.set(namespace, ["tasks", "3"], {
			title: "Nested Task",
			must_be_complete: { before: beforeTs, after: afterTs },
		});

		const task3 = await waitForListen(clientB, ["tasks", "3"], (val) =>
			val?.must_be_complete?.before === beforeTs &&
				val?.must_be_complete?.after === afterTs
				? val
				: null,
		);
		console.log(
			"Client B received task 3 with nested fields:",
			JSON.stringify(task3),
		);

		// 6. Verify field-level update still works for nested fields
		console.log("Verifying field-level update for nested field...");
		const newAfterTs = afterTs + 60;
		await clientB.set(
			namespace,
			["tasks", "3", "must_be_complete", "after"],
			newAfterTs,
		);

		const finalTask3 = await waitForListen(clientA, ["tasks", "3"], (val) =>
			val?.must_be_complete?.after === newAfterTs ? val : null,
		);
		console.log(
			"Client A received field-level update for task 3 with nested fields:",
			JSON.stringify(finalTask3),
		);

		// 7. Verify both clients see the same deterministic state (including nested objects)
		const getSnapshot = (tasks: MockTask[]) =>
			JSON.stringify(
				tasks
					.map((t) => ({
						id: t.id,
						title: t.title,
						tags: t.tags,
						must_be_complete: t.must_be_complete,
					}))
					.sort((a, b) => (a.id as string).localeCompare(b.id as string)),
			);

		const expected = JSON.stringify([
			{
				id: "1",
				title: "A's Task",
				tags: ["home", "urgent"],
				must_be_complete: { before: null, after: null },
			},
			{
				id: "2",
				title: "B's Task",
				tags: ["work"],
				must_be_complete: { before: null, after: null },
			},
			{
				id: "3",
				title: "Nested Task",
				tags: null,
				must_be_complete: { before: beforeTs, after: newAfterTs },
			},
		]);

		const tasksA = (await clientA.get(namespace, ["tasks"])) as MockTask[];
		if (getSnapshot(tasksA) !== expected)
			throw new Error(`Client A mismatch. Got: ${getSnapshot(tasksA)}`);

		const tasksB = (await clientB.get(namespace, ["tasks"])) as MockTask[];
		if (getSnapshot(tasksB) !== expected)
			throw new Error(`Client B mismatch. Got: ${getSnapshot(tasksB)}`);

		console.log("Collection verification passed (with nested objects).");

		// 8. Test deep path fetch as well
		console.log("Testing deep path fetch for nested field...");
		const deepValue = await clientA.get(namespace, [
			"tasks",
			"3",
			"must_be_complete",
			"after",
		]);
		if (deepValue !== newAfterTs)
			throw new Error(
				`Deep path fetch failed. Expected ${newAfterTs}, got ${deepValue}`,
			);
		console.log("Deep path fetch passed.");

		console.log("E2E Sync test passed successfully!");
	} catch (err) {
		console.error("Test failed:", err);
		throw err;
	} finally {
		clientA.close();
		clientB.close();
	}
}
