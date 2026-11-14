import {
	afterAll,
	beforeAll,
	describe,
	expect,
	setDefaultTimeout,
	test,
} from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createClient } from "@zyncbase/client";
import type {
	ZyncBaseActions,
	ZyncBasePresence,
	ZyncBaseSchema,
} from "./schema-types";
import { startQuorumServer } from "./server";
import { generateRoomCode, roomNamespace } from "./shared";

setDefaultTimeout(120_000);

let server: Awaited<ReturnType<typeof startQuorumServer>>;
let dataDir: string;
let appPort: number;
let databasePort: number;
const clients: ReturnType<
	typeof createClient<ZyncBaseSchema, ZyncBaseActions, ZyncBasePresence>
>[] = [];

async function freePort(): Promise<number> {
	const probe = createServer();
	await new Promise<void>((resolve, reject) => {
		probe.once("error", reject);
		probe.listen(0, "127.0.0.1", resolve);
	});
	const address = probe.address();
	if (!address || typeof address === "string") throw new Error("No port");
	await new Promise<void>((resolve, reject) =>
		probe.close((error) => (error ? reject(error) : resolve())),
	);
	return address.port;
}

async function sessionToken(room: string, subject: string): Promise<string> {
	const response = await fetch(`http://127.0.0.1:${appPort}/session`, {
		method: "POST",
		headers: { "content-type": "application/json" },
		body: JSON.stringify({ room, subject }),
	});
	if (!response.ok) {
		throw new Error(
			`session failed: ${response.status} ${await response.text()}`,
		);
	}
	const body = (await response.json()) as { token: string };
	return body.token;
}

async function openClient(
	room: string,
	subject: string,
	namespaceRoom = room,
): Promise<
	ReturnType<
		typeof createClient<ZyncBaseSchema, ZyncBaseActions, ZyncBasePresence>
	>
> {
	const token = await sessionToken(room, subject);
	const client = createClient<
		ZyncBaseSchema,
		ZyncBaseActions,
		ZyncBasePresence
	>({
		url: `ws://127.0.0.1:${databasePort}/ws`,
		auth: { token },
		storeNamespace: roomNamespace(namespaceRoom),
		presenceNamespace: roomNamespace(namespaceRoom),
		reconnect: false,
	});
	await client.connect();
	clients.push(client);
	return client;
}

beforeAll(async () => {
	dataDir = await mkdtemp(join(tmpdir(), "quorum-test-"));
	const [port, dbPort] = await Promise.all([freePort(), freePort()]);
	appPort = port;
	databasePort = dbPort;
	server = await startQuorumServer({
		port: appPort,
		databasePort,
		dataDir,
		origin: `http://127.0.0.1:${appPort}`,
		quiet: true,
	});
});

afterAll(async () => {
	await Promise.allSettled(clients.map((client) => client.disconnect()));
	await server.stop();
	await rm(dataDir, { recursive: true, force: true });
});

describe("quorum voting", () => {
	test("enforces the budget and the per-card cap under concurrent votes", async () => {
		const room = generateRoomCode();
		const host = await openClient(room, "budget-host");
		const created = await host.actions.call("create_room", {
			name: "Host",
			title: "Budget",
			template: "retro",
			vote_budget: 5,
			max_per_card: 3,
		});
		const cards: string[] = [];
		for (let index = 0; index < 6; index++) {
			const card = await host.actions.call("add_card", {
				lane: "Start",
				text: `Idea ${index}`,
			});
			cards.push(card.card_id);
		}
		await host.actions.call("start_vote", { duration_ms: 60_000 });

		const first = await Promise.allSettled(
			Array.from({ length: 4 }, () =>
				host.actions.call("cast_vote", { card_id: cards[0] }),
			),
		);
		expect(first.filter((entry) => entry.status === "fulfilled")).toHaveLength(
			3,
		);

		const second = await Promise.allSettled(
			Array.from({ length: 4 }, () =>
				host.actions.call("cast_vote", { card_id: cards[1] }),
			),
		);
		expect(second.filter((entry) => entry.status === "fulfilled")).toHaveLength(
			2,
		);

		const sixth = await host.actions
			.call("cast_vote", { card_id: cards[2] })
			.then(() => ({ ok: true }))
			.catch(() => ({ ok: false }));
		expect(sixth.ok).toBe(false);

		const budgets = await host.store.query("budgets", {
			where: { room_code: room },
		});
		expect(budgets[0]?.votes_left).toBe(0);
		const roomRow = await host.store.get(["rooms", created.room_id]);
		expect(roomRow?.votes_cast).toBe(5);
	});

	test("two clients with the same identity cannot overspend", async () => {
		const room = generateRoomCode();
		const first = await openClient(room, "same-person");
		await first.actions.call("create_room", {
			name: "Same",
			title: "Two tabs",
			template: "list",
			vote_budget: 5,
			max_per_card: 5,
		});
		const card = await first.actions.call("add_card", {
			lane: "Ideas",
			text: "One idea",
		});
		await first.actions.call("start_vote", { duration_ms: 60_000 });

		const second = await openClient(room, "same-person");
		const votes = await Promise.allSettled(
			Array.from({ length: 6 }, (_, index) =>
				(index % 2 === 0 ? first : second).actions.call("cast_vote", {
					card_id: card.card_id,
				}),
			),
		);
		expect(votes.filter((entry) => entry.status === "fulfilled")).toHaveLength(
			5,
		);
		const budget = await first.store.query("budgets", {
			where: { room_code: room },
		});
		expect(budget[0]?.votes_left).toBe(0);
	});

	test("close is transactional, idempotent, and rejects late votes", async () => {
		const room = generateRoomCode();
		const host = await openClient(room, "close-host");
		const created = await host.actions.call("create_room", {
			name: "Host",
			title: "Close",
			template: "retro",
		});
		const a = await host.actions.call("add_card", {
			lane: "Start",
			text: "First",
		});
		const b = await host.actions.call("add_card", {
			lane: "Stop",
			text: "Second",
		});
		await host.actions.call("start_vote", { duration_ms: 60_000 });
		await host.actions.call("cast_vote", { card_id: a.card_id });
		await host.actions.call("cast_vote", { card_id: b.card_id });
		await host.actions.call("cast_vote", { card_id: b.card_id });

		const closes = await Promise.all([
			host.actions.call("close_vote", {}),
			host.actions.call("close_vote", {}),
		]);
		expect(closes.every((entry) => entry.closed)).toBe(true);
		expect(closes[0].results_count).toBe(2);

		const results = await host.store.query("results", {
			where: { room_code: room, round: 1 },
			orderBy: [{ rank: "asc" }],
		});
		expect(results.reduce((sum, row) => sum + row.votes, 0)).toBe(3);
		const roomRow = await host.store.get(["rooms", created.room_id]);
		expect(roomRow?.phase).toBe("results");
		expect(roomRow?.votes_cast).toBe(3);

		const late = await host.actions
			.call("cast_vote", { card_id: a.card_id })
			.then(() => ({ ok: true }))
			.catch(() => ({ ok: false }));
		expect(late.ok).toBe(false);

		await host.actions.call("start_discussion", {});
		await host.actions.call("focus_topic", { card_id: b.card_id });
		await host.actions.call("add_decision", { text: "Keep the second topic" });
		await host.actions.call("close_room", {});
		const closed = await host.store.get(["rooms", created.room_id]);
		expect(closed?.phase).toBe("closed");
		const decisions = await host.store.query("decisions", {
			where: { room_code: room, round: 1 },
		});
		expect(decisions).toHaveLength(1);
		expect(decisions[0]?.card_id).toBe(b.card_id);
		expect(decisions[0]?.author_name).toBe("Host");
	});

	test("a token for one room cannot enter another room's namespace", async () => {
		const roomA = generateRoomCode();
		const roomB = generateRoomCode();
		const foreign = await sessionToken(roomB, "isolation-subject");
		const client = createClient<
			ZyncBaseSchema,
			ZyncBaseActions,
			ZyncBasePresence
		>({
			url: `ws://127.0.0.1:${databasePort}/ws`,
			auth: { token: foreign },
			storeNamespace: roomNamespace(roomA),
			presenceNamespace: roomNamespace(roomA),
			reconnect: false,
		});
		await expect(client.connect()).rejects.toThrow();
	});

	test("the demo seed is private but included in the reveal", async () => {
		const room = generateRoomCode();
		const host = await openClient(room, "demo-host");
		await host.actions.call("create_room", {
			name: "Host",
			title: "Demo",
			template: "retro",
			vote_budget: 5,
			max_per_card: 3,
			demo: true,
		});
		const roomRow = await host.store.query("rooms", {
			where: { room_code: room },
			limit: 1,
		});
		expect(roomRow[0]?.members_count).toBe(5);
		expect(roomRow[0]?.cards_count).toBe(8);
		expect(roomRow[0]?.votes_cast).toBe(20);

		const cards = await host.store.query("cards", {
			where: { room_code: room, round: 1 },
		});
		await host.actions.call("start_vote", { duration_ms: 60_000 });
		await host.actions.call("cast_vote", { card_id: cards[0].id });
		await host.actions.call("close_vote", {});
		const results = await host.store.query("results", {
			where: { room_code: room, round: 1 },
		});
		expect(results.reduce((sum, row) => sum + row.votes, 0)).toBe(21);
		const ballots = await host.store.query("ballots", {
			where: { room_code: room, round: 1 },
		});
		expect(ballots).toHaveLength(8);
	});
});
