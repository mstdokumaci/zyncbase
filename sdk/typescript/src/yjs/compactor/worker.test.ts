import { describe, expect, setSystemTime, test } from "bun:test";

import * as Y from "yjs";
import {
	ChunkAssembler,
	chunkPayload,
	YJS_DOCUMENTS_COLLECTION,
	YJS_SNAPSHOTS_COLLECTION,
	YJS_UPDATES_COLLECTION,
} from "../storage.js";
import {
	asClient,
	FakeClient,
	type FakeRow,
	waitFor,
} from "../test-helpers.js";
import { startYjsCompactor } from "./index.js";
import { YjsCompactor } from "./worker.js";

const DOCUMENTS = YJS_DOCUMENTS_COLLECTION;
const SNAPSHOTS = YJS_SNAPSHOTS_COLLECTION;
const UPDATES = YJS_UPDATES_COLLECTION;
const DOC_ID = "doc-1";

function seedHeader(
	client: FakeClient,
	documentId = DOC_ID,
	fields: Record<string, unknown> = {},
): FakeRow {
	return client.store.seed(DOCUMENTS, documentId, {
		compaction_version: 0,
		...fields,
	});
}

function seedUpdate(
	client: FakeClient,
	documentId: string,
	updateId: string,
	bytes: Uint8Array,
	createdAt?: number,
): void {
	client.store.seed(
		UPDATES,
		`${documentId}-${updateId}-0`,
		{
			document_id: documentId,
			update_id: updateId,
			part: 0,
			parts: 1,
			data: bytes,
		},
		createdAt,
	);
}

function seedPart(
	client: FakeClient,
	documentId: string,
	updateId: string,
	part: number,
	parts: number,
	data: Uint8Array,
	createdAt?: number,
): void {
	client.store.seed(
		UPDATES,
		`${documentId}-${updateId}-${part}`,
		{
			document_id: documentId,
			update_id: updateId,
			part,
			parts,
			data,
		},
		createdAt,
	);
}

function seedCommit(
	client: FakeClient,
	documentId: string,
	updateId: string,
	part: number,
	parts: number,
	createdAt?: number,
): void {
	client.store.seed(
		UPDATES,
		`${documentId}-${updateId}-commit`,
		{
			document_id: documentId,
			update_id: updateId,
			part,
			parts,
			committed: true,
		},
		createdAt,
	);
}

function seedSnapshotGroup(
	client: FakeClient,
	documentId: string,
	snapshotId: string,
	version: number,
	bytes: Uint8Array,
	chunkSize = 8,
): void {
	const parts = chunkPayload(bytes, chunkSize);
	for (let index = 0; index < parts.length; index += 1) {
		client.store.seed(SNAPSHOTS, `${snapshotId}-${index}`, {
			document_id: documentId,
			snapshot_id: snapshotId,
			compaction_version: version,
			part: index,
			parts: parts.length,
			data: parts[index] as Uint8Array,
		});
	}
	if (parts.length > 1) {
		client.store.seed(SNAPSHOTS, `${snapshotId}-commit`, {
			document_id: documentId,
			snapshot_id: snapshotId,
			compaction_version: version,
			part: parts.length,
			parts: parts.length,
			committed: true,
		});
	}
}

function incrementalUpdates(texts: string[]): Uint8Array[] {
	const source = new Y.Doc();
	const updates: Uint8Array[] = [];
	source.on("update", (update: Uint8Array) => updates.push(update));
	let offset = 0;
	for (const text of texts) {
		source.getText("content").insert(offset, text);
		offset += text.length;
	}
	source.destroy();
	return updates;
}

function seedMarker(
	client: FakeClient,
	documentId: string,
	updateId: string,
	parts: number,
	committed: boolean,
	createdAt?: number,
): string {
	const rowId = `${documentId}-${updateId}-marker`;
	client.store.seed(
		UPDATES,
		rowId,
		{
			document_id: documentId,
			update_id: updateId,
			part: parts,
			parts,
			committed,
		},
		createdAt,
	);
	return rowId;
}

function stateUpdate(text: string): Uint8Array {
	const doc = new Y.Doc();
	doc.getText("content").insert(0, text);
	const update = Y.encodeStateAsUpdate(doc);
	doc.destroy();
	return update;
}

function readHeader(client: FakeClient, documentId = DOC_ID): FakeRow {
	const row = client.store.collection(DOCUMENTS).get(documentId);
	if (row === undefined) throw new Error(`missing header ${documentId}`);
	return row;
}

function updateRows(client: FakeClient, documentId = DOC_ID): FakeRow[] {
	return [...client.store.collection(UPDATES).values()].filter(
		(row) => row.document_id === documentId,
	);
}

function snapshotGroups(
	client: FakeClient,
	documentId = DOC_ID,
): Map<string, FakeRow[]> {
	const groups = new Map<string, FakeRow[]>();
	for (const row of client.store.collection(SNAPSHOTS).values()) {
		if (row.document_id !== documentId) continue;
		const snapshotId = row.snapshot_id;
		if (typeof snapshotId !== "string") continue;
		const group = groups.get(snapshotId);
		if (group === undefined) groups.set(snapshotId, [row]);
		else group.push(row);
	}
	return groups;
}

function snapshotBytes(
	client: FakeClient,
	documentId: string,
	snapshotId: string,
): Uint8Array {
	const assembler = new ChunkAssembler();
	for (const row of client.store.collection(SNAPSHOTS).values()) {
		if (row.document_id !== documentId) continue;
		if (row.snapshot_id !== snapshotId) continue;
		const part = row.part;
		const parts = row.parts;
		if (typeof part !== "number" || typeof parts !== "number") continue;
		const data = row.data;
		const assembled = assembler.add({
			id: row.id,
			payloadId: snapshotId,
			part,
			parts,
			data: data instanceof Uint8Array ? data : null,
			committed: typeof row.committed === "boolean" ? row.committed : undefined,
		});
		if (assembled !== null) return assembled.bytes;
	}
	throw new Error("snapshot is incomplete");
}

function snapshotText(
	client: FakeClient,
	documentId: string,
	snapshotId: string,
): string {
	const doc = new Y.Doc();
	Y.applyUpdate(doc, snapshotBytes(client, documentId, snapshotId));
	const text = doc.getText("content").toString();
	doc.destroy();
	return text;
}

function makeWorker(
	client: FakeClient,
	options: ConstructorParameters<typeof YjsCompactor>[1] = {},
): YjsCompactor {
	return new YjsCompactor(asClient(client), {
		updateRetentionMs: 0,
		snapshotRetentionMs: 0,
		cleanupIntervalMs: 0,
		chunkSize: 8,
		pageSize: 2,
		...options,
	});
}

describe("YjsCompactor", () => {
	test("compacts updates into a snapshot and cleans covered rows", async () => {
		const client = new FakeClient();
		const updates = incrementalUpdates(["hello", " world"]);
		seedHeader(client);
		seedUpdate(client, DOC_ID, "u0", updates[0] as Uint8Array, 1);
		seedUpdate(client, DOC_ID, "u1", updates[1] as Uint8Array, 2);
		const errors: unknown[] = [];
		const compacted: string[] = [];
		const worker = makeWorker(client, {
			onError: (error) => errors.push(error),
			onCompacted: (event) => compacted.push(event.documentId),
		});

		await worker.runPass();

		const header = readHeader(client);
		expect(header.compaction_version).toBe(1);
		expect(typeof header.compacted_through).toBe("number");
		const snapshotId = header.current_snapshot_id;
		expect(typeof snapshotId).toBe("string");
		expect(snapshotGroups(client).size).toBe(1);
		expect(snapshotText(client, DOC_ID, snapshotId as string)).toBe(
			"hello world",
		);
		expect(updateRows(client)).toEqual([]);
		expect(errors).toEqual([]);
		expect(compacted).toEqual([DOC_ID]);
	});

	test("does nothing when a document has no updates", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const worker = makeWorker(client);

		await worker.runPass();

		const header = readHeader(client);
		expect(header.compaction_version).toBe(0);
		expect(header.current_snapshot_id ?? null).toBeNull();
		expect(snapshotGroups(client).size).toBe(0);
	});

	test("keeps incomplete chunks and clamps the watermark", async () => {
		const client = new FakeClient();
		const updates = incrementalUpdates(["a", "b".repeat(30)]);
		seedHeader(client);
		seedUpdate(client, DOC_ID, "a", updates[0] as Uint8Array);
		const parts = chunkPayload(updates[1] as Uint8Array, 8);
		expect(parts.length).toBeGreaterThan(1);
		for (let index = 0; index < parts.length; index += 1) {
			seedPart(
				client,
				DOC_ID,
				"b",
				index,
				parts.length,
				parts[index] as Uint8Array,
			);
		}
		const worker = makeWorker(client, {
			updateRetentionMs: 120_000,
			snapshotRetentionMs: 0,
		});

		await worker.runPass();

		let header = readHeader(client);
		expect(header.compaction_version).toBe(1);
		const firstWatermark = header.compacted_through as number;
		expect(typeof firstWatermark).toBe("number");
		expect(
			snapshotText(client, DOC_ID, header.current_snapshot_id as string),
		).toBe("a");
		const remainingB = updateRows(client).filter(
			(row) => row.update_id === "b",
		);
		expect(remainingB.length).toBe(parts.length);

		seedCommit(client, DOC_ID, "b", parts.length, parts.length);
		await worker.runPass();

		header = readHeader(client);
		expect(header.compaction_version).toBe(2);
		expect(header.compacted_through as number).toBeGreaterThan(firstWatermark);
		expect(
			snapshotText(client, DOC_ID, header.current_snapshot_id as string),
		).toBe(`a${"b".repeat(30)}`);
		expect(snapshotGroups(client).size).toBe(1);
	});

	test("keeps retrying while an incomplete group remains", async () => {
		const client = new FakeClient();
		const updates = incrementalUpdates(["a", "b".repeat(30)]);
		seedHeader(client);
		seedUpdate(client, DOC_ID, "a", updates[0] as Uint8Array);
		const parts = chunkPayload(updates[1] as Uint8Array, 8);
		for (let index = 0; index < parts.length; index += 1) {
			seedPart(
				client,
				DOC_ID,
				"b",
				index,
				parts.length,
				parts[index] as Uint8Array,
			);
		}
		const worker = makeWorker(client, {
			updateRetentionMs: 120_000,
			snapshotRetentionMs: 0,
		});

		await worker.runPass();

		let header = readHeader(client);
		expect(header.compaction_version).toBe(1);
		const watermark = header.compacted_through as number;
		const bRows = updateRows(client).filter((row) => row.update_id === "b");
		const cursor = Math.max(...bRows.map((row) => row.created_at as number));
		expect(cursor).toBeGreaterThan(watermark);
		seedCommit(client, DOC_ID, "b", parts.length, parts.length, watermark + 1);

		setSystemTime(new Date(Date.now() + 2_000));
		try {
			await worker.runPass();
		} finally {
			setSystemTime();
		}

		header = readHeader(client);
		expect(header.compaction_version).toBe(2);
		expect(
			snapshotText(client, DOC_ID, header.current_snapshot_id as string),
		).toBe(`a${"b".repeat(30)}`);
	});

	test("abandons an uncommitted multi-part group", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const update = incrementalUpdates(["x".repeat(30)])[0] as Uint8Array;
		const parts = chunkPayload(update, 8);
		seedMarker(client, DOC_ID, "abandoned", parts.length, false);
		for (let index = 0; index < parts.length; index += 1) {
			seedPart(
				client,
				DOC_ID,
				"abandoned",
				index,
				parts.length,
				parts[index] as Uint8Array,
			);
		}
		const worker = makeWorker(client);

		await worker.runPass();

		expect(updateRows(client)).toEqual([]);
		expect(readHeader(client).compaction_version).toBe(0);
		expect(snapshotGroups(client).size).toBe(0);
	});

	test("keeps parts when the publisher commits before abandonment", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const update = incrementalUpdates(["x".repeat(30)])[0] as Uint8Array;
		const parts = chunkPayload(update, 8);
		const markerId = seedMarker(
			client,
			DOC_ID,
			"raced-commit",
			parts.length,
			false,
		);
		for (let index = 0; index < parts.length; index += 1) {
			seedPart(
				client,
				DOC_ID,
				"raced-commit",
				index,
				parts.length,
				parts[index] as Uint8Array,
			);
		}
		let raced = false;
		client.store.beforeBatch = (operations) => {
			if (raced) return;
			const remove = operations.find(
				(operation) =>
					operation.op === "remove" && operation.path[0] === UPDATES,
			);
			if (remove === undefined) return;
			raced = true;
			client.store.patch(UPDATES, markerId, { committed: true });
		};
		const worker = makeWorker(client);

		await worker.runPass();

		expect(raced).toBe(true);
		expect(readHeader(client).compaction_version).toBe(0);
		expect(snapshotGroups(client).size).toBe(0);
		const rows = updateRows(client);
		expect(rows.length).toBe(parts.length + 1);
		expect(rows.some((row) => row.committed === true)).toBe(true);
	});

	test("keeps an active uncommitted group for a later pass", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const update = incrementalUpdates(["x".repeat(30)])[0] as Uint8Array;
		const parts = chunkPayload(update, 8);
		seedMarker(client, DOC_ID, "active", parts.length, false);
		for (let index = 0; index < parts.length; index += 1) {
			seedPart(
				client,
				DOC_ID,
				"active",
				index,
				parts.length,
				parts[index] as Uint8Array,
			);
		}
		const worker = makeWorker(client, { updateRetentionMs: 120_000 });

		await worker.runPass();

		expect(readHeader(client).compaction_version).toBe(0);
		expect(snapshotGroups(client).size).toBe(0);
		expect(updateRows(client).length).toBe(parts.length + 1);
	});

	test("keeps a committed group that follows more than 512 pending groups", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const update = incrementalUpdates(["committed"])[0] as Uint8Array;
		const parts = chunkPayload(update, 4);
		expect(parts.length).toBeGreaterThan(1);
		seedPart(
			client,
			DOC_ID,
			"committed",
			0,
			parts.length,
			parts[0] as Uint8Array,
		);
		for (let index = 0; index < 513; index += 1) {
			seedPart(
				client,
				DOC_ID,
				`pending-${index}`,
				0,
				parts.length,
				parts[0] as Uint8Array,
			);
		}
		for (let index = 1; index < parts.length; index += 1) {
			seedPart(
				client,
				DOC_ID,
				"committed",
				index,
				parts.length,
				parts[index] as Uint8Array,
			);
		}
		seedCommit(client, DOC_ID, "committed", parts.length, parts.length);
		const worker = makeWorker(client);

		await worker.runPass();

		const header = readHeader(client);
		expect(header.compaction_version).toBe(1);
		expect(
			snapshotText(client, DOC_ID, header.current_snapshot_id as string),
		).toBe("committed");
		expect(updateRows(client)).toEqual([]);
	});

	test("retains a committed group with a missing part", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const update = incrementalUpdates(["z".repeat(30)])[0] as Uint8Array;
		const parts = chunkPayload(update, 8);
		expect(parts.length).toBeGreaterThan(1);
		seedPart(
			client,
			DOC_ID,
			"missing-part",
			0,
			parts.length,
			parts[0] as Uint8Array,
		);
		seedCommit(client, DOC_ID, "missing-part", parts.length, parts.length);
		const worker = makeWorker(client);

		await worker.runPass();

		expect(readHeader(client).compaction_version).toBe(0);
		expect(snapshotGroups(client).size).toBe(0);
		expect(updateRows(client).length).toBe(2);
	});

	test("does not seal a group whose commit row lacks committed true", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const update = incrementalUpdates(["q".repeat(30)])[0] as Uint8Array;
		const parts = chunkPayload(update, 8);
		for (let index = 0; index < parts.length; index += 1) {
			seedPart(
				client,
				DOC_ID,
				"unsealed",
				index,
				parts.length,
				parts[index] as Uint8Array,
			);
		}
		client.store.seed(UPDATES, "unsealed-commit", {
			document_id: DOC_ID,
			update_id: "unsealed",
			part: parts.length,
			parts: parts.length,
		});
		const worker = makeWorker(client);

		await worker.runPass();

		expect(readHeader(client).compaction_version).toBe(0);
		expect(snapshotGroups(client).size).toBe(0);
		expect(updateRows(client)).toEqual([]);
	});

	test("retries after a compaction version conflict", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const first = incrementalUpdates(["a"]);
		seedUpdate(client, DOC_ID, "a", first[0] as Uint8Array, 1);

		let raced = false;
		client.store.beforeBatch = () => {
			if (raced) return;
			raced = true;
			client.store.patch(DOCUMENTS, DOC_ID, { compaction_version: 1 });
		};
		const worker = makeWorker(client);

		await worker.runPass();

		let header = readHeader(client);
		expect(raced).toBe(true);
		expect(header.compaction_version).toBe(1);
		expect(header.current_snapshot_id ?? null).toBeNull();
		expect(snapshotGroups(client).size).toBe(1);

		setSystemTime(new Date(Date.now() + 2_000));
		try {
			await worker.runPass();
		} finally {
			setSystemTime();
		}

		header = readHeader(client);
		expect(header.compaction_version).toBe(2);
		expect(
			snapshotText(client, DOC_ID, header.current_snapshot_id as string),
		).toBe("a");
		expect(snapshotGroups(client).size).toBe(1);
	});

	test("compacts an update that arrives after a conflict", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const updates = incrementalUpdates(["a", "b"]);
		seedUpdate(client, DOC_ID, "a", updates[0] as Uint8Array, 1);

		let raced = false;
		client.store.beforeBatch = () => {
			if (raced) return;
			raced = true;
			client.store.patch(DOCUMENTS, DOC_ID, { compaction_version: 1 });
		};
		const worker = makeWorker(client);

		await worker.runPass();
		expect(readHeader(client).current_snapshot_id ?? null).toBeNull();

		seedUpdate(client, DOC_ID, "b", updates[1] as Uint8Array, 10);
		await worker.runPass();

		const header = readHeader(client);
		expect(header.compaction_version).toBe(2);
		expect(
			snapshotText(client, DOC_ID, header.current_snapshot_id as string),
		).toBe("ab");
		expect(snapshotGroups(client).size).toBe(1);
	});

	test("protects a pending snapshot generation at the current version", async () => {
		const client = new FakeClient();
		const current = "snap-current";
		const pending = "snap-pending";
		seedHeader(client, DOC_ID, {
			compaction_version: 1,
			current_snapshot_id: current,
			compacted_through: 1,
		});
		seedSnapshotGroup(client, DOC_ID, current, 1, stateUpdate("current"));
		seedSnapshotGroup(client, DOC_ID, pending, 1, stateUpdate("pending"));
		const worker = makeWorker(client, { snapshotRetentionMs: 0 });

		await worker.runPass();

		expect(snapshotGroups(client).size).toBe(2);

		client.store.patch(DOCUMENTS, DOC_ID, { compaction_version: 2 });
		await worker.runPass();

		const groups = snapshotGroups(client);
		expect(groups.size).toBe(1);
		expect(groups.has(current)).toBe(true);
	});

	test("aborts snapshot cleanup when the header changes", async () => {
		const client = new FakeClient();
		const current = "snap-current";
		const old = "snap-old";
		seedHeader(client, DOC_ID, {
			compaction_version: 1,
			current_snapshot_id: current,
			compacted_through: 1,
		});
		seedSnapshotGroup(client, DOC_ID, current, 1, stateUpdate("current"));
		seedSnapshotGroup(client, DOC_ID, old, 0, stateUpdate("old"));

		let raced = false;
		client.store.beforeBatch = () => {
			if (raced) return;
			raced = true;
			client.store.patch(DOCUMENTS, DOC_ID, { compaction_version: 2 });
		};
		const worker = makeWorker(client, { snapshotRetentionMs: 0 });

		await worker.runPass();

		expect(raced).toBe(true);
		expect(snapshotGroups(client).size).toBe(2);
		expect(readHeader(client).compaction_version).toBe(2);
	});

	test("skips commit and cleanup when stopped during a multi-part write", async () => {
		const client = new FakeClient();
		seedHeader(client);
		seedUpdate(
			client,
			DOC_ID,
			"a",
			incrementalUpdates(["x".repeat(100)])[0] as Uint8Array,
		);
		client.store.pauseNextSet = true;
		const handle = startYjsCompactor(asClient(client), {
			intervalMs: 60_000,
			updateRetentionMs: 0,
			snapshotRetentionMs: 0,
			cleanupIntervalMs: 0,
			chunkSize: 8,
		});
		try {
			await waitFor(() => client.store.pausedSetCount === 1);
			const stopping = handle.stop();
			client.store.releaseSets();
			await stopping;
		} finally {
			await handle.stop();
		}

		const header = readHeader(client);
		expect(header.compaction_version).toBe(0);
		expect(header.current_snapshot_id ?? null).toBeNull();
		expect(updateRows(client).length).toBe(1);
		expect(snapshotGroups(client).size).toBe(1);
	});

	test("processes multiple namespaces independently", async () => {
		const client = new FakeClient();
		await client.setStoreNamespace("a");
		seedHeader(client, "doc-a");
		seedUpdate(
			client,
			"doc-a",
			"ua",
			incrementalUpdates(["a"])[0] as Uint8Array,
			1,
		);
		await client.setStoreNamespace("b");
		seedHeader(client, "doc-b");
		seedUpdate(
			client,
			"doc-b",
			"ub",
			incrementalUpdates(["b"])[0] as Uint8Array,
			1,
		);
		const worker = makeWorker(client, { namespaces: ["a", "b"] });

		await worker.runPass();

		await client.setStoreNamespace("a");
		expect(readHeader(client, "doc-a").compaction_version).toBe(1);
		expect(snapshotGroups(client, "doc-a").size).toBe(1);
		await client.setStoreNamespace("b");
		expect(readHeader(client, "doc-b").compaction_version).toBe(1);
		expect(snapshotGroups(client, "doc-b").size).toBe(1);
	});

	test("resumes from its update cursor across passes", async () => {
		const client = new FakeClient();
		const updates = incrementalUpdates(["a", "b"]);
		seedHeader(client);
		seedUpdate(client, DOC_ID, "a", updates[0] as Uint8Array, 1);
		const worker = makeWorker(client);

		await worker.runPass();
		expect(readHeader(client).compaction_version).toBe(1);

		seedUpdate(client, DOC_ID, "b", updates[1] as Uint8Array, 10);
		await worker.runPass();

		const header = readHeader(client);
		expect(header.compaction_version).toBe(2);
		expect(header.compacted_through).toBe(10);
		expect(
			snapshotText(client, DOC_ID, header.current_snapshot_id as string),
		).toBe("ab");
		expect(snapshotGroups(client).size).toBe(1);
	});

	test("starts and stops the long-running worker", async () => {
		const client = new FakeClient();
		seedHeader(client);
		seedUpdate(
			client,
			DOC_ID,
			"a",
			incrementalUpdates(["a"])[0] as Uint8Array,
			1,
		);
		const handle = startYjsCompactor(asClient(client), {
			intervalMs: 60_000,
			updateRetentionMs: 0,
			snapshotRetentionMs: 0,
			cleanupIntervalMs: 0,
		});

		expect(handle.running).toBe(true);
		await waitFor(() => readHeader(client).compaction_version === 1);
		await handle.stop();
		expect(handle.running).toBe(false);
	});
});
