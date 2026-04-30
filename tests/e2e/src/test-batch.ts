import { ZyncBaseClient } from "./client";

export async function run(port: number = 3000) {
	const client = new ZyncBaseClient(`ws://localhost:${port}`);

	try {
		await client.connect();
		const namespace = "public";

		console.log("Running batch operations...");

		await client.batch([
			{
				op: "set",
				path: ["tasks", "batch-1"],
				value: { title: "Batch Task 1", tags: ["batch"] },
			},
			{
				op: "set",
				path: ["tasks", "batch-2"],
				value: { title: "Batch Task 2", tags: ["batch"] },
			},
		]);

		// Verify that they were inserted
		const b1 = await client.get(namespace, ["tasks", "batch-1"]);
		const b2 = await client.get(namespace, ["tasks", "batch-2"]);
		if (b1?.title !== "Batch Task 1" || b2?.title !== "Batch Task 2") {
			throw new Error("Batch insert failed to retrieve inserted data");
		}

		console.log("Batch operations successful.");

		// Now let's try batch delete
		await client.batch([
			{
				op: "remove",
				path: ["tasks", "batch-1"],
			},
			{
				op: "set",
				path: ["tasks", "batch-2"],
				value: { title: "Batch Task 2 Updated", tags: ["updated"] },
			},
		]);

		const b1_deleted = await client.get(namespace, ["tasks", "batch-1"]);
		const b2_updated = await client.get(namespace, ["tasks", "batch-2"]);
		if (b1_deleted != null) {
			throw new Error("Batch delete failed");
		}
		if (b2_updated?.title !== "Batch Task 2 Updated") {
			throw new Error("Batch update failed");
		}

		console.log("Batch remove/update successful.");

		// Let's test the 500 limit if possible? No need, 500 is large.
	} catch (err) {
		console.error("Test failed:", err);
		throw err;
	} finally {
		client.close();
	}
}
