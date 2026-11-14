import assert from "node:assert/strict";
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

async function session(port: number, room: string, subject: string) {
	const response = await fetch(`http://127.0.0.1:${port}/session`, {
		method: "POST",
		headers: { "content-type": "application/json" },
		body: JSON.stringify({ room, subject }),
	});
	assert.equal(response.status, 200);
	return ((await response.json()) as { token: string }).token;
}

function clientFor(port: number, room: string, token: string) {
	return createClient<ZyncBaseSchema, ZyncBaseActions, ZyncBasePresence>({
		url: `ws://127.0.0.1:${port}/ws`,
		auth: { token },
		storeNamespace: roomNamespace(room),
		presenceNamespace: roomNamespace(room),
	});
}

const dataDir = await mkdtemp(join(tmpdir(), "quorum-smoke-"));
const [appPort, databasePort] = await Promise.all([freePort(), freePort()]);
const server = await startQuorumServer({
	port: appPort,
	databasePort,
	dataDir,
	origin: `http://127.0.0.1:${appPort}`,
	quiet: true,
});

const room = generateRoomCode();
const hostToken = await session(appPort, room, "smoke-host-subject-1");
const guestToken = await session(appPort, room, "smoke-guest-subject-2");
const host = clientFor(databasePort, room, hostToken);
const guest = clientFor(databasePort, room, guestToken);

try {
	await Promise.all([host.connect(), guest.connect()]);

	const created = await host.actions.call("create_room", {
		name: "Host",
		title: "Smoke test",
		template: "retro",
	});
	const cardA = await host.actions.call("add_card", {
		lane: "Start",
		text: "First idea",
	});
	const cardB = await host.actions.call("add_card", {
		lane: "Stop",
		text: "Second idea",
	});
	const joined = await guest.actions.call("join_room", { name: "Guest" });
	assert.equal(joined.read_only, false);

	await host.actions.call("start_vote", { duration_ms: 60_000 });
	await host.actions.call("cast_vote", { card_id: cardA.card_id });
	await host.actions.call("cast_vote", { card_id: cardA.card_id });
	await host.actions.call("cast_vote", { card_id: cardA.card_id });
	await host.actions.call("cast_vote", { card_id: cardB.card_id });
	await host.actions.call("cast_vote", { card_id: cardB.card_id });
	await guest.actions.call("cast_vote", { card_id: cardA.card_id });
	await guest.actions.call("cast_vote", { card_id: cardA.card_id });

	const closed = await host.actions.call("close_vote", {});
	assert.equal(closed.closed, true);
	assert.equal(closed.results_count, 2);

	const results = await host.store.query("results", {
		where: { room_code: room, round: 1 },
		orderBy: [{ rank: "asc" }],
	});
	assert.equal(results.length, 2);
	assert.equal(results[0].card_id, cardA.card_id);
	assert.equal(results[0].votes, 5);
	assert.equal(results[1].votes, 2);

	const hostBallots = await host.store.query("ballots", {
		where: { room_code: room, round: 1 },
	});
	const guestBallots = await guest.store.query("ballots", {
		where: { room_code: room, round: 1 },
	});
	assert.equal(hostBallots.length, 2);
	assert.equal(guestBallots.length, 2);
	assert.equal(
		hostBallots.reduce((sum, row) => sum + row.count, 0),
		5,
	);
	assert.equal(
		guestBallots.find((row) => row.card_id === cardA.card_id)?.count,
		2,
	);
	const hiddenId = hostBallots[0].id;
	const byId = await guest.store.query("ballots", {
		where: { id: hiddenId },
	});
	assert.equal(byId.length, 0);
	const hiddenRow = await guest.store.get(["ballots", hiddenId]);
	assert.equal(hiddenRow, null);

	const roomRow = await host.store.get(["rooms", created.room_id]);
	assert.equal(roomRow?.phase, "results");
	assert.equal(roomRow?.votes_cast, 7);

	console.log("quorum smoke ok", {
		room,
		results: results.map((row) => ({ votes: row.votes, text: row.text })),
	});
} finally {
	await Promise.allSettled([host.disconnect(), guest.disconnect()]);
	await server.stop();
	await rm(dataDir, { recursive: true, force: true });
}
