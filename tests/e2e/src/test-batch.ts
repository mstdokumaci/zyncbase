import type { JsonValue, SubscriptionHandle } from "@zyncbase/client";
import { ZyncBaseClient } from "./client";

const BATCH_PROPAGATION_TIMEOUT_MS = 5000;

interface BatchTask {
	id: string;
	title: string;
	tags: string[];
}

interface TaskSubscriptionState {
	records: Map<string, BatchTask>;
	snapshotCount: number;
	onChange: Set<() => void>;
}

function asBatchTask(value: JsonValue): BatchTask | null {
	if (value === null || typeof value !== "object" || Array.isArray(value)) {
		return null;
	}

	const record = value as Record<string, JsonValue>;
	if (
		typeof record.id !== "string" ||
		typeof record.title !== "string" ||
		!Array.isArray(record.tags)
	) {
		return null;
	}

	const tags = record.tags.filter(
		(tag): tag is string => typeof tag === "string",
	);
	return { id: record.id, title: record.title, tags };
}

function describeBatchRecords(records: Map<string, BatchTask>): string {
	const batchRecords = [...records.values()]
		.filter((task) => task.id.startsWith("batch-"))
		.map((task) => `${task.id}:${task.title}`)
		.sort();
	return batchRecords.length > 0 ? batchRecords.join(", ") : "none";
}

function waitForTaskState(
	state: TaskSubscriptionState,
	description: string,
	predicate: (records: Map<string, BatchTask>) => boolean,
	timeoutMs = BATCH_PROPAGATION_TIMEOUT_MS,
): Promise<void> {
	if (predicate(state.records)) return Promise.resolve();

	return new Promise<void>((resolve, reject) => {
		let timer: ReturnType<typeof setTimeout>;
		const cleanup = () => {
			clearTimeout(timer);
			state.onChange.delete(check);
		};
		const check = () => {
			if (!predicate(state.records)) return;
			cleanup();
			resolve();
		};

		timer = setTimeout(() => {
			cleanup();
			reject(
				new Error(
					`Timed out waiting for ${description}. Current batch records: ${describeBatchRecords(state.records)}`,
				),
			);
		}, timeoutMs);

		state.onChange.add(check);
		check();
	});
}

function hasTags(task: BatchTask | undefined, tags: string[]): boolean {
	if (!task || task.tags.length !== tags.length) return false;
	return tags.every((tag, index) => task.tags[index] === tag);
}

export async function run(port: number = 3000) {
	const client = new ZyncBaseClient(`ws://localhost:${port}`);
	let subscription: SubscriptionHandle | null = null;

	try {
		await client.connect();
		await client.setNamespace("public");

		const state: TaskSubscriptionState = {
			records: new Map(),
			snapshotCount: 0,
			onChange: new Set(),
		};
		subscription = client.store.subscribe("tasks", {}, (tasks: JsonValue[]) => {
			state.records.clear();
			for (const value of tasks) {
				const task = asBatchTask(value);
				if (task) state.records.set(task.id, task);
			}
			state.snapshotCount++;
			for (const onChange of state.onChange) onChange();
		});

		await waitForTaskState(
			state,
			"initial tasks subscription snapshot",
			() => state.snapshotCount > 0,
		);

		const batchIdPrefix = `batch-${Date.now().toString(36)}`;
		const batch1Id = `${batchIdPrefix}-1`;
		const batch2Id = `${batchIdPrefix}-2`;

		console.log("Running batch operations...");

		await client.batch([
			{
				op: "set",
				path: ["tasks", batch1Id],
				value: { title: "Batch Task 1", tags: ["batch"] },
			},
			{
				op: "set",
				path: ["tasks", batch2Id],
				value: { title: "Batch Task 2", tags: ["batch"] },
			},
		]);

		await waitForTaskState(
			state,
			"batch inserts to propagate through subscription",
			(records) =>
				records.get(batch1Id)?.title === "Batch Task 1" &&
				hasTags(records.get(batch1Id), ["batch"]) &&
				records.get(batch2Id)?.title === "Batch Task 2" &&
				hasTags(records.get(batch2Id), ["batch"]),
		);

		console.log("Batch operations successful.");

		await client.batch([
			{
				op: "remove",
				path: ["tasks", batch1Id],
			},
			{
				op: "set",
				path: ["tasks", batch2Id],
				value: { title: "Batch Task 2 Updated", tags: ["updated"] },
			},
		]);

		await waitForTaskState(
			state,
			"batch remove/update to propagate through subscription",
			(records) =>
				!records.has(batch1Id) &&
				records.get(batch2Id)?.title === "Batch Task 2 Updated" &&
				hasTags(records.get(batch2Id), ["updated"]),
		);

		console.log("Batch remove/update successful.");
	} catch (err) {
		console.error("Test failed:", err);
		throw err;
	} finally {
		subscription?.unsubscribe();
		client.close();
	}
}
