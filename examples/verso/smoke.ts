import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createClient } from "@zyncbase/client";
import { ZyncBaseYjsProvider } from "@zyncbase/client/yjs";
import * as Y from "yjs";
import { cursorFromPresence, cursorToPresence } from "./editor/cursor-presence";
import { assembleChanges } from "./history-data";
import { startVersoServer } from "./server";
import {
	type AppClient,
	collections,
	pageNamespace,
	STORE_NAMESPACE,
} from "./shared";

async function freePort(): Promise<number> {
	const server = createServer();
	await new Promise<void>((resolve, reject) => {
		server.once("error", reject);
		server.listen(0, "127.0.0.1", resolve);
	});
	const address = server.address();
	if (!address || typeof address === "string") throw new Error("No port");
	await new Promise<void>((resolve, reject) =>
		server.close((error) => (error ? reject(error) : resolve())),
	);
	return address.port;
}

async function session(port: number, email: string) {
	const response = await fetch(`http://127.0.0.1:${port}/session`, {
		method: "POST",
		headers: { "content-type": "application/json" },
		body: JSON.stringify({ email }),
	});
	assert.equal(response.status, 200);
	return (await response.json()) as { token: string; email: string };
}

function claims(token: string): { sub?: string; workspace?: string } {
	const payload = token.split(".")[1] ?? "";
	return JSON.parse(Buffer.from(payload, "base64url").toString()) as {
		sub?: string;
		workspace?: string;
	};
}

function clientFor(port: number, token: string): AppClient {
	return createClient({
		url: `ws://127.0.0.1:${port}/ws`,
		auth: { token },
		storeNamespace: STORE_NAMESPACE,
		presenceNamespace: STORE_NAMESPACE,
	}) as AppClient;
}

async function eventually(
	label: string,
	check: () => boolean | Promise<boolean>,
	timeoutMs = 10_000,
) {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		if (await check()) return;
		await Bun.sleep(50);
	}
	throw new Error(`Timed out: ${label}`);
}

async function createPage(
	client: AppClient,
	title: string,
	parentId?: string,
): Promise<string> {
	const id = client.utils.id();
	await client.store.batch([
		{
			op: "set",
			path: ["pages", id],
			value: {
				title,
				position: 1000,
				compaction_version: 0,
				...(parentId ? { parent_id: parentId } : {}),
			},
		},
	]);
	return id;
}

const dataDir = await mkdtemp(join(tmpdir(), "verso-smoke-"));
const appPort = await freePort();
const localOrigin = `http://localhost:${appPort}`;
const secondOrigin = `http://second-origin.test:${appPort}`;
const server = await startVersoServer({
	port: appPort,
	databasePort: await freePort(),
	origins: [localOrigin, secondOrigin],
	dataDir,
	quiet: true,
	compactorIntervalMs: 500,
});

try {
	// Only the configured origins may mint a session.
	const forged = await fetch(`http://127.0.0.1:${server.port}/session`, {
		method: "POST",
		headers: { "content-type": "application/json", origin: "http://evil.test" },
		body: JSON.stringify({ email: "ada@verso.test" }),
	});
	assert.equal(forged.status, 403);
	const allowed = await fetch(`http://127.0.0.1:${server.port}/session`, {
		method: "POST",
		headers: { "content-type": "application/json", origin: secondOrigin },
		body: JSON.stringify({ email: "ada@verso.test" }),
	});
	assert.equal(allowed.status, 200);

	const ada = await session(server.port, "ada@verso.test");
	const grace = await session(server.port, "grace@verso.test");
	const a = clientFor(server.databasePort, ada.token);
	const b = clientFor(server.databasePort, grace.token);
	await a.connect();
	await b.connect();

	// Profiles live on the global users row the resolver already created.
	const adaId = a.presence.localUserId;
	const graceId = b.presence.localUserId;
	assert.ok(adaId && graceId);
	await a.store.batch([
		{ op: "set", path: ["users", adaId, "name"], value: "Ada" },
		{ op: "set", path: ["users", adaId, "color"], value: "#c96a4b" },
	]);
	const profile = (await b.store.get(["users", adaId])) as {
		name?: string;
	} | null;
	assert.equal(profile?.name, "Ada");

	// The directory is live: a later profile write reaches the other client.
	const names: string[] = [];
	const profileSub = await b.store.listen(
		["users", adaId],
		(value: unknown) => {
			const name = (value as { name?: string } | null)?.name;
			if (typeof name === "string") names.push(name);
		},
	);
	await a.store.set(["users", adaId, "name"], "Ada L.");
	await eventually("profile update reaches the peer", () =>
		names.includes("Ada L."),
	);
	await profileSub.unlisten();

	// The write rule is ownership-guarded: another person cannot rewrite the row.
	const denied = await b.store.set(["users", adaId, "color"], "#000000").then(
		() => null,
		(error: { code?: string }) => error.code,
	);
	assert.equal(denied, "PERMISSION_DENIED");
	const untouched = (await b.store.get(["users", adaId])) as {
		color?: string;
	} | null;
	assert.equal(untouched?.color, "#c96a4b");

	// The server seeds the welcome page before anyone connects.
	await eventually("welcome page seeded", async () => {
		const rows = await a.store.query("pages", {
			where: { slug: "welcome" },
			limit: 1,
		});
		return rows.length === 1;
	});
	const welcome = (
		await a.store.query("pages", { where: { slug: "welcome" }, limit: 1 })
	)[0];
	assert.ok(welcome);
	const seedDoc = new Y.Doc();
	const seedProvider = new ZyncBaseYjsProvider(a, welcome.id, seedDoc, {
		collections,
		connect: false,
	});
	await seedProvider.connect();
	assert.ok(seedDoc.getXmlFragment("default").length > 0);
	seedProvider.destroy();

	// A page row, and a child page that cascades from its parent.
	const parent = await createPage(a, "Parent");
	const parentRow = (await a.store.get(["pages", parent])) as {
		owner_id?: string;
	} | null;
	assert.equal(parentRow?.owner_id, adaId);
	const child = await createPage(a, "Child", parent);
	assert.equal(
		(await b.store.query("pages", { where: { parent_id: parent } })).length,
		1,
	);

	// Claimed identity is stable per email and distinct across emails.
	const again = await session(server.port, "  ADA@verso.test ");
	assert.equal(claims(again.token).sub, claims(ada.token).sub);
	assert.equal(claims(again.token).workspace, claims(ada.token).workspace);

	// Presence accepts the relative-position shape Tiptap publishes: root IDs
	// are `{client, clock}` objects.
	await a.setPresenceNamespace(pageNamespace(parent));
	await b.setPresenceNamespace(pageNamespace(parent));
	await a.presence.set({
		yjsClientId: 7,
		cursor: {
			anchor: {
				type: { client: 7, clock: 0 },
				tname: "default",
				item: { client: 7, clock: 3 },
				assoc: 0,
			},
			head: {
				type: { client: 7, clock: 0 },
				tname: "default",
				item: { client: 7, clock: 3 },
				assoc: 0,
			},
		},
	});
	await b.presence.subscribe(() => {});
	await eventually("peer presence arrives", () => {
		const users = b.presence.getAll();
		return users.some((user) => user.data.cursor?.anchor?.item?.client === 7);
	});

	// Two providers over one page converge, and their carets travel as presence.
	const docA = new Y.Doc();
	const docB = new Y.Doc();
	const awarenessOptions = (pageId: string) => ({
		namespace: pageNamespace(pageId),
		toPresence: (state: Record<string, unknown>) => {
			const user = state.user;
			const cursor = cursorToPresence(state.cursor);
			return {
				...(user ? { user } : {}),
				...(cursor ? { cursor } : {}),
			};
		},
		fromPresence: (data: Record<string, unknown>) => {
			const user = data.user;
			const cursor = cursorFromPresence(data.cursor);
			return {
				...(user ? { user } : {}),
				...(cursor ? { cursor } : {}),
			};
		},
	});
	const providerA = new ZyncBaseYjsProvider(a, parent, docA, {
		collections,
		writeDebounceMs: 20,
		awareness: awarenessOptions(parent),
	});
	const providerB = new ZyncBaseYjsProvider(b, parent, docB, {
		collections,
		writeDebounceMs: 20,
		awareness: awarenessOptions(parent),
	});
	await Promise.all([providerA.connect(), providerB.connect()]);
	docA.getText("body").insert(0, "hello from ada");
	await eventually(
		"provider convergence",
		() => docB.getText("body").toString() === "hello from ada",
	);

	providerA.awareness?.setLocalStateField("user", {
		name: "Ada",
		color: "#c96a4b",
	});
	// The shape that used to crash peers: a caret on an empty non-text node has
	// a root type ID and no item.
	const rootId = { client: docA.clientID, clock: 0 };
	providerA.awareness?.setLocalStateField("cursor", {
		anchor: { type: rootId, assoc: 0 },
		head: { type: rootId, assoc: 0 },
	});
	await eventually("caret reaches the peer", () => {
		const states = providerB.awareness?.getStates();
		if (!states) return false;
		for (const state of states.values()) {
			const value = state as {
				user?: { name?: string };
				cursor?: { anchor?: { type?: { client?: number } } };
			};
			if (
				value.user?.name === "Ada" &&
				value.cursor?.anchor?.type?.client === docA.clientID
			) {
				return true;
			}
		}
		return false;
	});

	// A caret with no reference at all is dropped instead of poisoning the peer.
	providerA.awareness?.setLocalStateField("cursor", {
		anchor: { assoc: 0 },
		head: { assoc: 0 },
	});
	await eventually("reference-less cursor clears the peer caret", () => {
		for (const state of providerB.awareness?.getStates().values() ?? []) {
			const value = state as {
				user?: { name?: string };
				cursor?: { anchor?: { type?: { client?: number } } };
			};
			if (value.user?.name !== "Ada") continue;
			return value.cursor?.anchor?.type?.client === undefined;
		}
		return false;
	});

	// The change log replays to the live document.
	const entries = assembleChanges(
		(await b.store.query("page_changes", {
			where: { document_id: parent },
			orderBy: [{ created_at: "asc" }],
		})) as never,
	);
	const replayed = new Y.Doc();
	for (const entry of entries) Y.applyUpdate(replayed, entry.bytes);
	assert.equal(replayed.getText("body").toString(), "hello from ada");
	// Change rows record their writer, which is what names the author in history.
	assert.ok(entries.length > 0);
	assert.ok(entries.some((entry) => entry.ownerId === adaId));
	assert.ok(entries.every((entry) => entry.ownerId !== undefined));

	// The append-only log exists for the page, and compacts into a snapshot.
	await eventually("page_changes rows", async () => {
		const rows = await b.store.query("page_changes", {
			where: { document_id: parent },
		});
		return rows.length > 0;
	});
	await eventually("compacted snapshot", async () => {
		const rows = await b.store.query("page_snapshots", {
			where: { document_id: parent },
		});
		return rows.length > 0;
	});

	providerA.destroy();
	providerB.destroy();

	// Deleting a page cascades to its subtree and to its content chunks.
	await a.store.remove(["pages", parent]);
	await eventually("cascade removed subtree", async () => {
		const pages = await a.store.query("pages", {
			where: { id: { in: [parent, child] } },
		});
		const changes = await a.store.query("page_changes", {
			where: { document_id: parent },
		});
		const snapshots = await a.store.query("page_snapshots", {
			where: { document_id: parent },
		});
		return pages.length === 0 && changes.length === 0 && snapshots.length === 0;
	});

	a.disconnect();
	b.disconnect();
	console.log("verso smoke: ok");
} finally {
	await server.stop();
	await rm(dataDir, { recursive: true, force: true });
}
