import { describe, expect, test } from "bun:test";

import * as Y from "yjs";

import { ZyncBaseError } from "../errors.js";
import {
	YjsDocumentNotFoundError,
	ZyncBaseYjsProvider,
	type ZyncBaseYjsProviderOptions,
} from "./provider.js";
import { chunkPayload } from "./storage.js";
import { asClient, FakeClient, type FakeRow, waitFor } from "./test-helpers.js";

const DOCUMENTS = "yjs_documents";
const SNAPSHOTS = "yjs_snapshots";
const UPDATES = "yjs_updates";
const DOC_ID = "doc-1";

function seedHeader(
	client: FakeClient,
	value: Record<string, unknown> = {},
	documentId = DOC_ID,
): FakeRow {
	return client.store.seed(
		DOCUMENTS,
		documentId,
		value as Record<string, never>,
	);
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
		`${updateId}-0`,
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

function seedSnapshot(
	client: FakeClient,
	documentId: string,
	snapshotId: string,
	bytes: Uint8Array,
	chunkSize = 8,
): void {
	const parts = chunkPayload(bytes, chunkSize);
	for (let index = 0; index < parts.length; index += 1) {
		client.store.seed(SNAPSHOTS, `${snapshotId}-p${index}`, {
			document_id: documentId,
			snapshot_id: snapshotId,
			part: index,
			parts: parts.length,
			data: parts[index] as Uint8Array,
		});
	}
	if (parts.length > 1) {
		client.store.seed(SNAPSHOTS, `${snapshotId}-commit`, {
			document_id: documentId,
			snapshot_id: snapshotId,
			part: parts.length,
			parts: parts.length,
			committed: true,
		});
	}
}

function stateUpdate(text: string, key = "content"): Uint8Array {
	const source = new Y.Doc();
	source.getText(key).insert(0, text);
	const update = Y.encodeStateAsUpdate(source);
	source.destroy();
	return update;
}

function makeProvider(
	client: FakeClient,
	doc: Y.Doc,
	options: ZyncBaseYjsProviderOptions = {},
): ZyncBaseYjsProvider {
	return new ZyncBaseYjsProvider(asClient(client), DOC_ID, doc, {
		connect: false,
		...options,
	});
}

function updateRows(client: FakeClient): FakeRow[] {
	return [...client.store.collection(UPDATES).values()];
}

function updateGroups(client: FakeClient): Map<string, FakeRow[]> {
	const groups = new Map<string, FakeRow[]>();
	for (const row of updateRows(client)) {
		const id = row.update_id;
		if (typeof id !== "string") continue;
		const group = groups.get(id);
		if (group === undefined) groups.set(id, [row]);
		else group.push(row);
	}
	return groups;
}

function applyStoredUpdates(client: FakeClient, doc: Y.Doc): void {
	for (const rows of updateGroups(client).values()) {
		const dataRows = rows
			.filter((row) => row.part !== row.parts)
			.slice()
			.sort((a, b) => (a.part as number) - (b.part as number));
		const length = dataRows.reduce(
			(sum, row) => sum + (row.data as Uint8Array).length,
			0,
		);
		const merged = new Uint8Array(length);
		let offset = 0;
		for (const row of dataRows) {
			const data = row.data as Uint8Array;
			merged.set(data, offset);
			offset += data.length;
		}
		Y.applyUpdate(doc, merged);
	}
}

describe("ZyncBaseYjsProvider lifecycle", () => {
	test("auto-connects and emits sync after the initial load", async () => {
		const client = new FakeClient();
		client.status = "disconnected";
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = new ZyncBaseYjsProvider(asClient(client), DOC_ID, doc);
		const statuses: string[] = [];
		const syncs: boolean[] = [];
		provider.on("status", ({ status }) => statuses.push(status));
		provider.on("sync", (synced) => syncs.push(synced));

		await waitFor(() => provider.synced);

		expect(client.connectCalls).toBe(1);
		expect(provider.synced).toBe(true);
		expect(statuses).toContain("connecting");
		expect(statuses).toContain("connected");
		expect(syncs).toEqual([true]);
		provider.destroy();
	});

	test("rejects with YjsDocumentNotFoundError for a missing header", async () => {
		const client = new FakeClient();
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc);

		await expect(provider.connect()).rejects.toBeInstanceOf(
			YjsDocumentNotFoundError,
		);
		expect(provider.synced).toBe(false);
		expect(client.store.subscriptions.size).toBe(0);
		provider.destroy();
	});

	test("connect is idempotent while active and works after disconnect", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc);

		const first = provider.connect();
		const second = provider.connect();
		expect(first).toBe(second);
		await first;
		expect(provider.synced).toBe(true);

		provider.disconnect();
		expect(provider.synced).toBe(false);
		expect(provider.status).toBe("disconnected");
		expect(client.store.subscriptions.size).toBe(0);

		await provider.connect();
		expect(provider.synced).toBe(true);
		provider.destroy();
	});

	test("disconnect during connect makes the next connect start a fresh attempt", async () => {
		const client = new FakeClient();
		seedHeader(client);
		client.store.deferSubscribe = true;
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc);

		const first = provider.connect();
		await waitFor(() => client.store.pendingSubscribeCount === 1);
		provider.disconnect();
		const second = provider.connect();
		await waitFor(() => client.store.pendingSubscribeCount === 2);
		client.store.releaseSubscriptions();

		await expect(first).rejects.toBeTruthy();
		await second;
		expect(provider.synced).toBe(true);
		expect(client.store.subscriptions.size).toBe(1);
		provider.destroy();
	});

	test("a sync listener that disconnects stops the completion path", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc);
		provider.on("sync", (synced) => {
			if (synced) provider.disconnect();
		});

		doc.getText("content").insert(0, "pending");
		await provider.connect();

		expect(provider.synced).toBe(false);
		expect(provider.status).toBe("disconnected");
		await new Promise((resolve) => setTimeout(resolve, 20));
		expect(updateRows(client)).toEqual([]);
		provider.destroy();
	});

	test("a sync listener disconnecting during resync stops the completion path", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc);
		await provider.connect();

		let syncEvents = 0;
		provider.on("sync", (synced) => {
			if (!synced) return;
			syncEvents += 1;
			provider.disconnect();
		});

		client.disconnect();
		client.status = "connected";
		client.emit("statusChange", "connected");
		client.emit("synced");

		await waitFor(() => syncEvents === 1);
		await new Promise((resolve) => setTimeout(resolve, 20));
		expect(provider.synced).toBe(false);
		expect(provider.status).toBe("disconnected");
		provider.destroy();
	});

	test("destroy is idempotent and stops writing", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc);
		await provider.connect();

		provider.destroy();
		provider.destroy();
		expect(provider.synced).toBe(false);
		expect(client.store.subscriptions.size).toBe(0);

		doc.getText("content").insert(0, "ignored");
		await new Promise((resolve) => setTimeout(resolve, 20));
		expect(updateRows(client)).toEqual([]);
	});
});

describe("ZyncBaseYjsProvider initial sync", () => {
	test("loads a chunked snapshot through the header pointer", async () => {
		const client = new FakeClient();
		const text = "hello from a chunked snapshot";
		seedSnapshot(client, DOC_ID, "snap-1", stateUpdate(text), 8);
		seedHeader(client, { current_snapshot_id: "snap-1" });
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc);

		await provider.connect();

		expect(doc.getText("content").toString()).toBe(text);
		provider.destroy();
	});

	test("loads a snapshot plus retained updates across pages", async () => {
		const client = new FakeClient();
		const source = new Y.Doc();
		const updates: Uint8Array[] = [];
		source.on("update", (update: Uint8Array) => updates.push(update));
		source.getText("content").insert(0, "a");
		source.getText("content").insert(1, "b");
		source.getText("content").insert(2, "c");
		source.getText("content").insert(3, "d");

		const firstState = new Y.Doc();
		Y.applyUpdate(firstState, updates[0] as Uint8Array);
		seedSnapshot(
			client,
			DOC_ID,
			"snap-watermark",
			Y.encodeStateAsUpdate(firstState),
			8,
		);
		firstState.destroy();

		for (let index = 0; index < updates.length; index += 1) {
			seedUpdate(
				client,
				DOC_ID,
				`up-${index}`,
				updates[index] as Uint8Array,
				index + 1,
			);
		}

		seedHeader(client, {
			current_snapshot_id: "snap-watermark",
			compacted_through: 1,
		});
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc, { pageSize: 2 });
		const errors: unknown[] = [];
		provider.on("error", (error) => errors.push(error));

		await provider.connect();

		expect(doc.getText("content").toString()).toBe("abcd");
		expect(errors).toEqual([]);
		const updateQueries = client.store.queries.filter(
			(query) => query.collection === UPDATES,
		);
		expect(updateQueries.length).toBeGreaterThan(1);
		// Chunked writes can straddle a compaction boundary, so reads must not
		// filter by compacted_through.
		expect(updateQueries[0]?.options.where?.created_at).toBeUndefined();
		source.destroy();
		provider.destroy();
	});

	test("applies a multi-part update whose parts straddle compacted_through", async () => {
		const client = new FakeClient();
		const source = new Y.Doc();
		source.getText("content").insert(0, "straddled update");
		const update = Y.encodeStateAsUpdate(source);
		const parts = chunkPayload(update, 8);
		expect(parts.length).toBeGreaterThan(1);

		for (let index = 0; index < parts.length; index += 1) {
			client.store.seed(
				UPDATES,
				`straddle-${index}`,
				{
					document_id: DOC_ID,
					update_id: "straddle",
					part: index,
					parts: parts.length,
					data: parts[index] as Uint8Array,
				},
				index === 0 ? 1 : 3 + index,
			);
		}
		client.store.seed(
			UPDATES,
			"straddle-commit",
			{
				document_id: DOC_ID,
				update_id: "straddle",
				part: parts.length,
				parts: parts.length,
				committed: true,
			},
			20,
		);
		seedHeader(client, { compacted_through: 2 });
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc);

		await provider.connect();

		expect(doc.getText("content").toString()).toBe("straddled update");
		source.destroy();
		provider.destroy();
	});

	test("halves the page size when a response is too large", async () => {
		const client = new FakeClient();
		const source = new Y.Doc();
		const updates: Uint8Array[] = [];
		source.on("update", (update: Uint8Array) => updates.push(update));
		for (let index = 0; index < 5; index += 1) {
			source.getText("content").insert(index, String(index));
		}
		for (let index = 0; index < updates.length; index += 1) {
			seedUpdate(client, DOC_ID, `page-${index}`, updates[index] as Uint8Array);
		}
		seedHeader(client);
		client.store.maxQueryLimit = 2;
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc, { pageSize: 8 });

		await provider.connect();

		expect(doc.getText("content").toString()).toBe("01234");
		const limits = client.store.queries
			.filter((query) => query.collection === UPDATES)
			.map((query) => query.options.limit);
		expect(limits.slice(0, 3)).toEqual([8, 4, 2]);
		source.destroy();
		provider.destroy();
	});

	test("applies a multi-part update only after its commit row", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc);
		await provider.connect();

		const source = new Y.Doc();
		source.getText("content").insert(0, "multi-part update");
		const update = Y.encodeStateAsUpdate(source);
		const parts = chunkPayload(update, 8);
		expect(parts.length).toBeGreaterThan(1);

		for (let index = 0; index < parts.length; index += 1) {
			client.store.seed(UPDATES, `multi-${index}`, {
				document_id: DOC_ID,
				update_id: "multi",
				part: index,
				parts: parts.length,
				data: parts[index] as Uint8Array,
			});
		}
		expect(doc.getText("content").toString()).toBe("");

		client.store.seed(UPDATES, "multi-commit", {
			document_id: DOC_ID,
			update_id: "multi",
			part: parts.length,
			parts: parts.length,
			committed: true,
		});

		await waitFor(
			() => doc.getText("content").toString() === "multi-part update",
		);
		source.destroy();
		provider.destroy();
	});

	test("waits for the committed flag on a live multi-part update", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc);
		await provider.connect();

		const source = new Y.Doc();
		source.getText("content").insert(0, "live multi-part");
		const update = Y.encodeStateAsUpdate(source);
		const parts = chunkPayload(update, 8);
		const markerId = "live-commit";
		client.store.seed(UPDATES, markerId, {
			document_id: DOC_ID,
			update_id: "live",
			part: parts.length,
			parts: parts.length,
			committed: false,
		});
		for (let index = 0; index < parts.length; index += 1) {
			client.store.seed(UPDATES, `live-${index}`, {
				document_id: DOC_ID,
				update_id: "live",
				part: index,
				parts: parts.length,
				data: parts[index] as Uint8Array,
			});
		}
		expect(doc.getText("content").toString()).toBe("");

		client.store.patch(UPDATES, markerId, { committed: true });

		await waitFor(
			() => doc.getText("content").toString() === "live multi-part",
		);
		source.destroy();
		provider.destroy();
	});

	test("requeues when the commit marker is removed before commit", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc, {
			chunkSize: 8,
			retryDelayMs: 5,
			maxRetryDelayMs: 20,
		});
		await provider.connect();

		let raced = false;
		client.store.beforeSet = (path, options) => {
			if (raced || options?.if === undefined) return;
			if (path[0] !== UPDATES) return;
			const row = client.store.collection(UPDATES).get(path[1] as string);
			if (row?.committed !== false) return;
			raced = true;
			client.store.delete(UPDATES, path[1] as string);
		};

		doc.getText("content").insert(0, "x".repeat(100));
		await expect(provider.flush()).rejects.toBeTruthy();

		await waitFor(() =>
			[...updateGroups(client).values()].some((rows) =>
				rows.some((row) => row.committed === true),
			),
		);
		expect(raced).toBe(true);
		provider.destroy();
	});

	test("re-reads the header when compaction lands during a sync", async () => {
		const client = new FakeClient();
		const source = new Y.Doc();
		source.getText("content").insert(0, "raced");
		const update = Y.encodeStateAsUpdate(source);
		seedUpdate(client, DOC_ID, "race-up", update);
		seedHeader(client);

		const doc = new Y.Doc();
		const provider = makeProvider(client, doc);
		let raced = false;
		client.store.afterQuery = (collection) => {
			if (collection !== UPDATES || raced) return;
			raced = true;
			client.store.delete(UPDATES, "race-up-0");
			seedSnapshot(client, DOC_ID, "snap-race", update, 8);
			client.store.patch(DOCUMENTS, DOC_ID, {
				current_snapshot_id: "snap-race",
				compacted_through: 1,
			});
		};

		await provider.connect();

		expect(raced).toBe(true);
		expect(doc.getText("content").toString()).toBe("raced");
		expect(
			client.store.queries.some((query) => query.collection === SNAPSHOTS),
		).toBe(true);
		source.destroy();
		provider.destroy();
	});

	test("ignores updates for other documents", async () => {
		const client = new FakeClient();
		seedUpdate(client, DOC_ID, "mine", stateUpdate("mine"));
		seedUpdate(client, "other-doc", "theirs", stateUpdate("theirs"));
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc);

		await provider.connect();

		expect(doc.getText("content").toString()).toBe("mine");
		provider.destroy();
	});

	test("emits an error for corrupt updates and keeps applying valid ones", async () => {
		const client = new FakeClient();
		seedUpdate(client, DOC_ID, "bad", new Uint8Array([1, 2, 3]), 1);
		seedUpdate(client, DOC_ID, "good", stateUpdate("valid"), 2);
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc);
		const errors: unknown[] = [];
		provider.on("error", (error) => errors.push(error));

		await provider.connect();

		expect(doc.getText("content").toString()).toBe("valid");
		expect(errors.length).toBeGreaterThan(0);
		provider.destroy();
	});

	test("does not echo remotely applied updates back to the store", async () => {
		const client = new FakeClient();
		seedUpdate(client, DOC_ID, "remote", stateUpdate("remote"));
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc);

		await provider.connect();

		expect(doc.getText("content").toString()).toBe("remote");
		expect(updateRows(client).length).toBe(1);
		provider.destroy();
	});
});

describe("ZyncBaseYjsProvider local writes", () => {
	test("writes a local update on flush", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc);
		await provider.connect();

		doc.getText("content").insert(0, "local");
		await provider.flush();

		const rows = updateRows(client);
		expect(rows.length).toBe(1);
		const row = rows[0] as FakeRow;
		expect(row.document_id).toBe(DOC_ID);
		expect(row.part).toBe(0);
		expect(row.parts).toBe(1);
		const applied = new Y.Doc();
		Y.applyUpdate(applied, row.data as Uint8Array);
		expect(applied.getText("content").toString()).toBe("local");
		applied.destroy();
		provider.destroy();
	});

	test("merges updates inside the debounce window into one payload", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc);
		await provider.connect();

		doc.getText("content").insert(0, "a");
		doc.getText("content").insert(1, "b");
		await provider.flush();

		const groups = updateGroups(client);
		expect(groups.size).toBe(1);
		const rows = [...groups.values()][0] as FakeRow[];
		expect(rows.length).toBe(1);
		const applied = new Y.Doc();
		Y.applyUpdate(applied, rows[0]?.data as Uint8Array);
		expect(applied.getText("content").toString()).toBe("ab");
		applied.destroy();
		provider.destroy();
	});

	test("chunks large updates and commits them last", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc, { chunkSize: 8 });
		await provider.connect();

		const text = "x".repeat(120);
		doc.getText("content").insert(0, text);
		await provider.flush();

		const groups = updateGroups(client);
		expect(groups.size).toBe(1);
		const rows = [...groups.values()][0] as FakeRow[];
		const parts = rows[0]?.parts as number;
		expect(parts).toBeGreaterThan(1);
		expect(rows.length).toBe(parts + 1);
		const dataRows = rows.filter((row) => row.part !== row.parts);
		const commit = rows.find((row) => row.part === row.parts);
		expect(commit).toBeDefined();
		expect(commit?.data).toBeUndefined();
		for (const row of dataRows) {
			expect((row.data as Uint8Array).length).toBeLessThanOrEqual(8);
		}

		const ordered = dataRows
			.slice()
			.sort((a, b) => (a.part as number) - (b.part as number));
		const total = ordered.reduce(
			(sum, row) => sum + (row.data as Uint8Array).length,
			0,
		);
		const merged = new Uint8Array(total);
		let offset = 0;
		for (const row of ordered) {
			merged.set(row.data as Uint8Array, offset);
			offset += (row.data as Uint8Array).length;
		}
		const applied = new Y.Doc();
		Y.applyUpdate(applied, merged);
		expect(applied.getText("content").toString()).toBe(text);
		applied.destroy();
		provider.destroy();
	});

	test("retries a failed write without losing bytes", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc, {
			retryDelayMs: 5,
			maxRetryDelayMs: 20,
		});
		await provider.connect();

		const errors: unknown[] = [];
		provider.on("error", (error) => errors.push(error));
		client.store.writeFailures.push("CONNECTION_FAILED");
		doc.getText("content").insert(0, "retry");
		await expect(provider.flush()).rejects.toBeTruthy();

		await waitFor(() => updateRows(client).length === 1);

		expect(errors.length).toBeGreaterThan(0);
		const row = updateRows(client)[0] as FakeRow;
		const applied = new Y.Doc();
		Y.applyUpdate(applied, row.data as Uint8Array);
		expect(applied.getText("content").toString()).toBe("retry");
		applied.destroy();
		provider.destroy();
	});

	test("retries a write that lands before the session is ready", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc, {
			retryDelayMs: 5,
			maxRetryDelayMs: 20,
		});
		await provider.connect();

		client.store.writeFailures.push("SESSION_NOT_READY");
		doc.getText("content").insert(0, "restored");
		await expect(provider.flush()).rejects.toBeTruthy();
		await waitFor(() => updateRows(client).length === 1);

		const row = updateRows(client)[0] as FakeRow;
		const applied = new Y.Doc();
		Y.applyUpdate(applied, row.data as Uint8Array);
		expect(applied.getText("content").toString()).toBe("restored");
		applied.destroy();
		provider.destroy();
	});

	test("blocks later writes after a terminal error and retries on flush", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc, { retryDelayMs: 5 });
		await provider.connect();

		const errors: unknown[] = [];
		provider.on("error", (error) => errors.push(error));
		client.store.writeFailures.push("PERMISSION_DENIED");
		doc.getText("content").insert(0, "first");
		await expect(provider.flush()).rejects.toBeTruthy();

		doc.getText("content").insert(5, "second");
		await new Promise((resolve) => setTimeout(resolve, 30));
		expect(updateGroups(client).size).toBe(0);

		client.store.writeFailures.push("PERMISSION_DENIED");
		await expect(provider.flush()).rejects.toBeTruthy();
		expect(updateGroups(client).size).toBe(0);

		await provider.flush();

		expect(updateGroups(client).size).toBe(1);
		const applied = new Y.Doc();
		applyStoredUpdates(client, applied);
		expect(applied.getText("content").toString()).toBe("firstsecond");
		applied.destroy();
		expect(errors.length).toBe(2);
		provider.destroy();
	});

	test("rejects a drain that loses the connection with bytes still queued", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc);
		await provider.connect();

		client.store.pauseNextSet = true;
		doc.getText("content").insert(0, "first");
		const flushing = provider.flush();
		await waitFor(() => client.store.pausedSetCount === 1);

		doc.getText("content").insert(5, "second");
		client.status = "disconnected";
		client.store.releaseSets();

		await expect(flushing).rejects.toBeTruthy();
		expect(updateGroups(client).size).toBe(1);

		client.status = "connected";
		await provider.flush();
		expect(updateGroups(client).size).toBe(2);
		provider.destroy();
	});

	test("propagates a terminal failure from a drain joined by flush", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc, {
			writeDebounceMs: 0,
			retryDelayMs: 5,
		});
		await provider.connect();

		client.store.pauseNextSet = true;
		client.store.failPausedSet = "PERMISSION_DENIED";
		doc.getText("content").insert(0, "blocked");
		await waitFor(() => client.store.pausedSetCount === 1);

		const flushing = provider.flush();
		client.store.releaseSets();

		const error = await flushing.catch((err: unknown) => err);
		expect(error).toBeInstanceOf(ZyncBaseError);
		expect((error as ZyncBaseError).code).toBe("PERMISSION_DENIED");
		expect(client.store.setAttempts).toBe(1);
		expect(updateGroups(client).size).toBe(0);

		await provider.flush();
		expect(updateGroups(client).size).toBe(1);
		provider.destroy();
	});

	test("allows an explicit retry from an error listener after a terminal failure", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc, {
			writeDebounceMs: 0,
			retryDelayMs: 5,
		});
		await provider.connect();

		let retryStarted = false;
		let resolveRetry!: (promise: Promise<void>) => void;
		const retryCalled = new Promise<Promise<void>>((resolve) => {
			resolveRetry = resolve;
		});
		provider.on("error", () => {
			if (retryStarted) return;
			retryStarted = true;
			resolveRetry(provider.flush());
		});

		client.store.pauseNextSet = true;
		client.store.failPausedSet = "PERMISSION_DENIED";
		doc.getText("content").insert(0, "retry from error");
		await waitFor(() => client.store.pausedSetCount === 1);
		client.store.releaseSets();

		const retry = await retryCalled;
		await retry;

		expect(client.store.setAttempts).toBe(2);
		expect(updateGroups(client).size).toBe(1);
		provider.destroy();
	});

	test("retries with fresh identities when a middle chunk fails", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc, {
			chunkSize: 8,
			retryDelayMs: 5,
			maxRetryDelayMs: 20,
		});
		await provider.connect();

		const text = "y".repeat(60);
		client.store.writeFailures = [null, "CONNECTION_FAILED"];
		doc.getText("content").insert(0, text);
		await expect(provider.flush()).rejects.toBeTruthy();

		await waitFor(() =>
			[...updateGroups(client).values()].some((rows) =>
				rows.some((row) => row.committed === true),
			),
		);

		const groups = [...updateGroups(client).values()];
		const committed = groups.find((rows) =>
			rows.some((row) => row.committed === true),
		) as FakeRow[];
		const abandoned = groups.filter(
			(rows) => !rows.some((row) => row.committed === true),
		);
		expect(abandoned.length).toBeGreaterThan(0);
		for (const rows of abandoned) {
			expect(rows[0]?.update_id).not.toBe(committed[0]?.update_id);
		}

		provider.destroy();
		const reader = new Y.Doc();
		const readerProvider = makeProvider(client, reader);
		await readerProvider.connect();
		expect(reader.getText("content").toString()).toBe(text);
		readerProvider.destroy();
	});
});

describe("ZyncBaseYjsProvider reconnect", () => {
	test("re-reads the snapshot on reconnect", async () => {
		const client = new FakeClient();
		const source = new Y.Doc();
		const updates: Uint8Array[] = [];
		source.on("update", (update: Uint8Array) => updates.push(update));
		source.getText("content").insert(0, "before");
		seedUpdate(client, DOC_ID, "before", updates[0] as Uint8Array, 1);
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc);
		await provider.connect();
		expect(doc.getText("content").toString()).toBe("before");

		source.getText("content").insert(6, " after");
		const snapshot = Y.encodeStateAsUpdate(source);
		client.store.delete(UPDATES, "before-0");
		seedSnapshot(client, DOC_ID, "snap-after", snapshot, 8);
		client.store.patch(DOCUMENTS, DOC_ID, {
			current_snapshot_id: "snap-after",
			compacted_through: 2,
		});

		client.emit("synced");
		await waitFor(() => doc.getText("content").toString() === "before after");
		expect(provider.synced).toBe(true);
		source.destroy();
		provider.destroy();
	});

	test("buffers local edits while disconnected and flushes on reconnect", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc);
		await provider.connect();
		provider.disconnect();

		doc.getText("content").insert(0, "offline");
		expect(updateRows(client)).toEqual([]);
		seedUpdate(client, DOC_ID, "remote", stateUpdate(" remote"));
		expect(doc.getText("content").toString()).toBe("offline");

		await provider.connect();
		await provider.flush();

		const text = doc.getText("content").toString();
		expect(text).toContain("offline");
		expect(text).toContain("remote");
		expect(updateGroups(client).size).toBe(2);
		provider.destroy();
	});

	test("stops syncing after disconnect", async () => {
		const client = new FakeClient();
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc);
		await provider.connect();
		provider.disconnect();

		seedUpdate(client, DOC_ID, "late", stateUpdate("late"));
		await new Promise((resolve) => setTimeout(resolve, 20));

		expect(doc.getText("content").toString()).toBe("");
		expect(provider.synced).toBe(false);
		provider.destroy();
	});
});

describe("ZyncBaseYjsProvider awareness", () => {
	test("is disabled by default", () => {
		const client = new FakeClient();
		const doc = new Y.Doc();
		const provider = makeProvider(client, doc);

		expect(provider.awareness).toBeNull();
		expect(client.presence.setCalls).toHaveLength(0);

		provider.destroy();
		doc.destroy();
	});

	test("publishes the local awareness state when enabled", async () => {
		const client = new FakeClient();
		client.presenceNamespace = "doc-1";
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = new ZyncBaseYjsProvider(asClient(client), DOC_ID, doc, {
			connect: false,
			awareness: { namespace: "doc-1" },
		});
		expect(provider.awareness).not.toBeNull();
		provider.awareness?.setLocalStateField("cursor", { x: 1, y: 2 });

		await provider.connect();
		expect(client.presence.setCalls.at(-1)).toMatchObject({
			cursor: { x: 1, y: 2 },
			yjsClientId: doc.clientID,
		});

		provider.destroy();
		doc.destroy();
	});

	test("rejects a presence namespace that does not match", () => {
		const client = new FakeClient();
		const doc = new Y.Doc();
		expect(
			() =>
				new ZyncBaseYjsProvider(asClient(client), DOC_ID, doc, {
					connect: false,
					awareness: { namespace: "doc-1" },
				}),
		).toThrow(/does not match/);
		doc.destroy();
	});

	test("stops awareness when a resync finds the document deleted", async () => {
		const client = new FakeClient();
		client.presenceNamespace = "doc-1";
		seedHeader(client);
		const doc = new Y.Doc();
		const provider = new ZyncBaseYjsProvider(asClient(client), DOC_ID, doc, {
			connect: false,
			awareness: { namespace: "doc-1" },
		});
		await provider.connect();
		expect(client.presence.subscribers).toBe(1);

		client.store.delete(DOCUMENTS, DOC_ID);
		client.emit("synced");
		await waitFor(() => provider.status === "disconnected");
		expect(client.presence.subscribers).toBe(0);

		provider.destroy();
		doc.destroy();
	});
});
