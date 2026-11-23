import { expect } from "bun:test";
import { createClient } from "@zyncbase/client";
import { ZyncBaseYjsProvider } from "@zyncbase/client/yjs";
import * as Y from "yjs";

type Row = Record<string, unknown>;

async function waitFor(predicate: () => boolean, timeoutMs = 10_000) {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		if (predicate()) return;
		await Bun.sleep(10);
	}
	throw new Error("Yjs e2e waitFor timed out");
}

function split(bytes: Uint8Array, chunkSize: number): Uint8Array[] {
	const parts: Uint8Array[] = [];
	for (let offset = 0; offset < bytes.length; offset += chunkSize) {
		parts.push(bytes.slice(offset, offset + chunkSize));
	}
	return parts;
}

export async function run(port: number): Promise<void> {
	const url = `ws://127.0.0.1:${port}`;
	const clientA = createClient({ url, auth: { anonymous: true } });
	const clientB = createClient({ url, auth: { anonymous: true } });
	const clientC = createClient({ url, auth: { anonymous: true } });
	const docA = new Y.Doc();
	const docB = new Y.Doc();
	const docC = new Y.Doc();
	let providerA: ZyncBaseYjsProvider | null = null;
	let providerB: ZyncBaseYjsProvider | null = null;
	let providerC: ZyncBaseYjsProvider | null = null;
	let documentId: string | null = null;
	let secondDocumentId: string | null = null;

	try {
		await Promise.all([
			clientA.connect(),
			clientB.connect(),
			clientC.connect(),
		]);

		const slug = `yjs-${Date.now()}`;
		documentId = await clientA.store.create("yjs_documents", { slug });
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

		secondDocumentId = await clientA.store.create("yjs_documents", {
			slug: `${slug}-snapshot`,
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

		providerA.destroy();
		providerB.destroy();
		providerC.destroy();
		providerA = null;
		providerB = null;
		providerC = null;

		await clientA.store.remove(["yjs_documents", documentId]);
		const remainingUpdates = await clientA.store.query("yjs_updates", {
			where: { document_id: documentId },
			limit: 50,
		});
		const remainingSnapshots = await clientA.store.query("yjs_snapshots", {
			where: { document_id: documentId },
			limit: 50,
		});
		const remainingNotes = await clientA.store.query("notes", {
			where: { document_id: documentId },
			limit: 50,
		});
		expect(remainingUpdates.length).toBe(0);
		expect(remainingSnapshots.length).toBe(0);
		expect(remainingNotes.length).toBe(0);
		expect(await clientA.store.get(["yjs_documents", documentId])).toBeNull();
		expect(noteId.length).toBeGreaterThan(0);

		await clientA.store.remove(["yjs_documents", secondDocumentId]);
	} finally {
		providerA?.destroy();
		providerB?.destroy();
		providerC?.destroy();
		docA.destroy();
		docB.destroy();
		docC.destroy();
		clientA.disconnect();
		clientB.disconnect();
		clientC.disconnect();
	}
}
