import { expect } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
	createClient,
	type SchemaLike,
	type ZyncBaseClient,
	ZyncBaseError,
} from "@zyncbase/client";
import { ZyncBaseYjsProvider } from "@zyncbase/client/yjs";
import { startYjsCompactor } from "@zyncbase/client/yjs/compactor";
import * as Y from "yjs";

import { FakeClient } from "../../../sdk/typescript/src/yjs/test-helpers.js";

type Row = Record<string, unknown>;
type ProviderClient = ConstructorParameters<typeof ZyncBaseYjsProvider>[0];

async function waitFor(predicate: () => boolean, timeoutMs = 10_000) {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		if (predicate()) return;
		await Bun.sleep(10);
	}
	throw new Error("Yjs e2e waitFor timed out");
}

async function waitForCompaction(
	client: ZyncBaseClient<SchemaLike>,
	documentId: string,
	timeoutMs = 15_000,
	minVersion = 1,
): Promise<Row> {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		const header = (await client.store.get([
			"yjs_documents",
			documentId,
		])) as Row | null;
		if (
			header !== null &&
			typeof header.current_snapshot_id === "string" &&
			typeof header.compaction_version === "number" &&
			header.compaction_version >= minVersion
		) {
			return header;
		}
		await Bun.sleep(20);
	}
	throw new Error("Yjs compaction timed out");
}

async function waitForNoUpdates(
	client: ZyncBaseClient<SchemaLike>,
	documentId: string,
	timeoutMs = 10_000,
): Promise<void> {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		const rows = await client.store.query("yjs_updates", {
			where: { document_id: documentId },
			limit: 50,
		});
		if (rows.length === 0) return;
		await Bun.sleep(20);
	}
	throw new Error("Yjs update cleanup timed out");
}

function split(bytes: Uint8Array, chunkSize: number): Uint8Array[] {
	const parts: Uint8Array[] = [];
	for (let offset = 0; offset < bytes.length; offset += chunkSize) {
		parts.push(bytes.slice(offset, offset + chunkSize));
	}
	return parts;
}

function sourceUpdates(texts: string[]): Uint8Array[] {
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

/**
 * The emitted package splits shared modules across entry points. These checks
 * import the built entries, so they catch a duplicated `ZyncBaseError` class
 * that source-level unit tests cannot.
 */
async function runPackageChecks(): Promise<void> {
	const entry = readFileSync(
		join(import.meta.dir, "../../../sdk/typescript/dist/yjs/index.js"),
		"utf8",
	);
	expect(entry).toMatch(/from\s+["']yjs["']/);

	const retryClient = new FakeClient();
	retryClient.status = "connected";
	retryClient.store.setErrorFactory((code) =>
		ZyncBaseError.fromServerResponse({ code, message: code }),
	);
	retryClient.store.seed("yjs_documents", "doc-1", {
		compaction_version: 0,
	});
	const retryDoc = new Y.Doc();
	const retryProvider = new ZyncBaseYjsProvider(
		retryClient as unknown as ProviderClient,
		"doc-1",
		retryDoc,
		{ connect: false, retryDelayMs: 1, maxRetryDelayMs: 5 },
	);
	try {
		await retryProvider.connect();
		retryClient.store.writeFailures.push("CONNECTION_FAILED");
		retryDoc.getText("content").insert(0, "retry");
		await expect(retryProvider.flush()).rejects.toBeTruthy();
		await waitFor(() => retryClient.store.collection("yjs_updates").size === 1);
	} finally {
		retryProvider.destroy();
		retryDoc.destroy();
	}

	const readClient = new FakeClient();
	readClient.status = "connected";
	readClient.store.setErrorFactory((code) =>
		ZyncBaseError.fromServerResponse({ code, message: code }),
	);
	readClient.store.seed("yjs_documents", "doc-1", {
		compaction_version: 0,
	});
	const updates = sourceUpdates(["a", "b", "c"]);
	for (let index = 0; index < updates.length; index += 1) {
		readClient.store.seed("yjs_updates", `up-${index}`, {
			document_id: "doc-1",
			update_id: `up-${index}`,
			part: 0,
			parts: 1,
			data: updates[index] as Uint8Array,
		});
	}
	readClient.store.maxQueryLimit = 2;
	const readDoc = new Y.Doc();
	const readProvider = new ZyncBaseYjsProvider(
		readClient as unknown as ProviderClient,
		"doc-1",
		readDoc,
		{ connect: false, pageSize: 8 },
	);
	try {
		await readProvider.connect();
		expect(readProvider.synced).toBe(true);
		expect(readDoc.getText("content").toString()).toBe("abc");
	} finally {
		readProvider.destroy();
		readDoc.destroy();
	}
}

export async function run(port: number): Promise<void> {
	await runPackageChecks();

	const url = `ws://127.0.0.1:${port}`;
	const clientA = createClient({ url, auth: { anonymous: true } });
	const clientB = createClient({ url, auth: { anonymous: true } });
	const clientC = createClient({ url, auth: { anonymous: true } });
	const clientD = createClient({ url, auth: { anonymous: true } });
	const docA = new Y.Doc();
	const docB = new Y.Doc();
	const docC = new Y.Doc();
	const docD = new Y.Doc();
	let providerA: ZyncBaseYjsProvider | null = null;
	let providerB: ZyncBaseYjsProvider | null = null;
	let providerC: ZyncBaseYjsProvider | null = null;
	let compactor: ReturnType<typeof startYjsCompactor> | null = null;
	const compactorErrors: unknown[] = [];
	let documentId: string | null = null;
	let secondDocumentId: string | null = null;

	try {
		await Promise.all([
			clientA.connect(),
			clientB.connect(),
			clientC.connect(),
			clientD.connect(),
		]);

		const slug = `yjs-${Date.now()}`;
		documentId = await clientA.store.create("yjs_documents", {
			slug,
			compaction_version: 0,
		});
		const noteId = await clientA.store.create("notes", {
			document_id: documentId,
			title: "Document note",
		});

		providerA = new ZyncBaseYjsProvider(clientA, documentId, docA, {
			connect: false,
			chunkSize: 128,
			pageSize: 2,
		});
		providerB = new ZyncBaseYjsProvider(clientB, documentId, docB, {
			connect: false,
			chunkSize: 128,
			pageSize: 2,
		});
		await providerA.connect();
		await providerB.connect();

		const text = "hello ".repeat(400);
		docA.getText("content").insert(0, text);
		await providerA.flush();
		await waitFor(() => docB.getText("content").toString() === text);

		const headers = (await clientB.store.query("yjs_documents", {
			where: { slug },
			limit: 1,
		})) as unknown as Row[];
		expect(headers[0]?.id).toBe(documentId);
		expect(typeof headers[0]?.created_at).toBe("number");
		expect(typeof headers[0]?.updated_at).toBe("number");
		expect(headers[0]?.created_at as number).toBeLessThanOrEqual(
			headers[0]?.updated_at as number,
		);

		const updates = (await clientA.store.query("yjs_updates", {
			where: { document_id: documentId },
			orderBy: [{ created_at: "asc" }],
			limit: 500,
		})) as unknown as Row[];
		const groups = new Map<string, Row[]>();
		for (const row of updates) {
			const updateId = row.update_id as string;
			const group = groups.get(updateId);
			if (group === undefined) groups.set(updateId, [row]);
			else group.push(row);
		}
		const chunked = [...groups.values()].find(
			(group) => (group[0]?.parts as number) > 1,
		);
		expect(chunked).toBeDefined();
		const chunkedRows = chunked as Row[];
		const parts = chunkedRows[0]?.parts as number;
		expect(chunkedRows.length).toBe(parts + 1);
		const commit = chunkedRows.find((row) => row.part === parts);
		expect(commit).toBeDefined();
		expect(commit?.data ?? null).toBeNull();
		for (const row of chunkedRows) {
			if (row.part === parts) continue;
			expect((row.data as Uint8Array).length).toBeLessThanOrEqual(128);
		}

		compactor = startYjsCompactor(clientD, {
			intervalMs: 25,
			updateRetentionMs: 0,
			snapshotRetentionMs: 0,
			cleanupIntervalMs: 0,
			chunkSize: 128,
			pageSize: 2,
			onError: (error) => compactorErrors.push(error),
		});
		const compactedHeader = await waitForCompaction(clientA, documentId);
		expect(compactedHeader.compaction_version as number).toBeGreaterThanOrEqual(
			1,
		);
		await waitForNoUpdates(clientA, documentId);
		const compactedSnapshots = await clientA.store.query("yjs_snapshots", {
			where: { document_id: documentId },
			limit: 500,
		});
		expect(compactedSnapshots.length).toBeGreaterThan(0);
		const compactedUpdates = await clientA.store.query("yjs_updates", {
			where: { document_id: documentId },
			limit: 50,
		});
		expect(compactedUpdates.length).toBe(0);

		const providerD = new ZyncBaseYjsProvider(clientC, documentId, docD, {
			connect: false,
			chunkSize: 128,
			pageSize: 2,
		});
		try {
			await providerD.connect();
			expect(docD.getText("content").toString()).toBe(text);
		} finally {
			providerD.destroy();
		}

		const postText = `${text} post-compaction`;
		docA.getText("content").insert(text.length, " post-compaction");
		await providerA.flush();
		await waitFor(() => docB.getText("content").toString() === postText);
		await waitForCompaction(clientA, documentId, 15_000, 2);

		secondDocumentId = await clientA.store.create("yjs_documents", {
			slug: `${slug}-snapshot`,
			compaction_version: 0,
		});
		const snapshotSource = new Y.Doc();
		const snapshotText = "snapshot ".repeat(50);
		snapshotSource.getText("content").insert(0, snapshotText);
		const snapshotBytes = Y.encodeStateAsUpdate(snapshotSource);
		const snapshotParts = split(snapshotBytes, 64);
		const snapshotId = clientA.utils.id();
		for (let index = 0; index < snapshotParts.length; index += 1) {
			await clientA.store.set(["yjs_snapshots", clientA.utils.id()], {
				document_id: secondDocumentId,
				snapshot_id: snapshotId,
				part: index,
				parts: snapshotParts.length,
				data: snapshotParts[index] as Uint8Array,
			});
		}
		if (snapshotParts.length > 1) {
			await clientA.store.set(["yjs_snapshots", clientA.utils.id()], {
				document_id: secondDocumentId,
				snapshot_id: snapshotId,
				part: snapshotParts.length,
				parts: snapshotParts.length,
			});
		}
		await clientA.store.set(
			["yjs_documents", secondDocumentId, "current_snapshot_id"],
			snapshotId,
		);

		providerC = new ZyncBaseYjsProvider(clientC, secondDocumentId, docC, {
			connect: false,
			chunkSize: 64,
			pageSize: 2,
		});
		await providerC.connect();
		expect(docC.getText("content").toString()).toBe(snapshotText);

		await compactor.stop();
		compactor = null;
		expect(compactorErrors).toEqual([]);

		providerA.destroy();
		providerB.destroy();
		providerC.destroy();
		providerA = null;
		providerB = null;
		providerC = null;

		const snapshotsBefore = await clientA.store.query("yjs_snapshots", {
			where: { document_id: secondDocumentId },
			limit: 50,
		});
		expect(snapshotsBefore.length).toBeGreaterThan(0);

		await clientA.store.remove(["yjs_documents", secondDocumentId]);
		const snapshotsAfter = await clientA.store.query("yjs_snapshots", {
			where: { document_id: secondDocumentId },
			limit: 50,
		});
		expect(snapshotsAfter.length).toBe(0);

		await clientA.store.remove(["yjs_documents", documentId]);
		const remainingUpdates = await clientA.store.query("yjs_updates", {
			where: { document_id: documentId },
			limit: 50,
		});
		const remainingNotes = await clientA.store.query("notes", {
			where: { document_id: documentId },
			limit: 50,
		});
		expect(remainingUpdates.length).toBe(0);
		expect(remainingNotes.length).toBe(0);
		expect(await clientA.store.get(["yjs_documents", documentId])).toBeNull();
		expect(noteId.length).toBeGreaterThan(0);
	} finally {
		providerA?.destroy();
		providerB?.destroy();
		providerC?.destroy();
		await compactor?.stop().catch(() => {});
		docA.destroy();
		docB.destroy();
		docC.destroy();
		docD.destroy();
		clientA.disconnect();
		clientB.disconnect();
		clientC.disconnect();
		clientD.disconnect();
	}
}
