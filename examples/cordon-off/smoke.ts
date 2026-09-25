import assert from "node:assert/strict";
import { mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createClient, type ZyncBaseClient } from "@zyncbase/client";
import { buildBrowser } from "./build";
import { startLocalEdge } from "./dev";
import {
	COUNTRY_COLORS,
	type Country,
	type CountryChunkRow,
	MAX_COUNTRIES,
	NAMESPACE,
	type PlayerRow,
	readColorIndexes,
	readCoordinates,
	type UserChunkRow,
} from "./shared";

async function freePort() {
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

async function eventually<T>(
	check: () => Promise<T>,
	label: string,
	timeoutMs = 30000,
) {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		const value = await check();
		if (value) return value;
		await Bun.sleep(100);
	}
	throw new Error(`Timed out: ${label}`);
}

const dataDir = await mkdtemp(join(tmpdir(), "cordon-off-smoke-"));
// The dev edge binds port 0 and reports its assigned port, so it cannot lose
// a selection race. The game's two ports are selected while every reservation
// listener is open (the OS cannot hand the same port to both), and are
// reselected with a startup retry if the game still loses one before binding.
let [authPort, databasePort] = await Promise.all([freePort(), freePort()]);
const useTls = process.argv.includes("--tls");
const certFile = join(dataDir, "cert.pem");
const keyFile = join(dataDir, "key.pem");
let cert: string | undefined;
if (useTls) {
	const result = Bun.spawnSync([
		"openssl",
		"req",
		"-x509",
		"-newkey",
		"rsa:2048",
		"-nodes",
		"-days",
		"1",
		"-subj",
		"/CN=localhost",
		"-addext",
		"subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1",
		"-keyout",
		keyFile,
		"-out",
		certFile,
	]);
	assert.equal(result.exitCode, 0, result.stderr.toString());
	cert = await readFile(certFile, "utf8");
}
const assets = await buildBrowser(join(dataDir, "assets"));
assert.deepEqual((await readdir(assets)).sort(), [
	"_headers",
	"client.js",
	"favicon.svg",
	"history.html",
	"index.html",
	"og.png",
	"style.css",
]);
const edgeOptions = { port: 0, authPort, databasePort, assets, ca: cert };
const edge = await startLocalEdge(edgeOptions);
const origin = `http://localhost:${edge.port}`;
let processHandle: Bun.Subprocess | undefined;
let logs = "";
const clients: ZyncBaseClient[] = [];
const timers: ReturnType<typeof setInterval>[] = [];

async function capture(stream: ReadableStream<Uint8Array>) {
	for await (const chunk of stream)
		logs = (logs + new TextDecoder().decode(chunk)).slice(-20000);
}

function spawnGame(reset: boolean, env: Record<string, string>) {
	const handle = Bun.spawn(
		["bun", join(import.meta.dir, "server.ts"), ...(reset ? ["--reset"] : [])],
		{
			env: {
				...process.env,
				GAME_DEPLOY: "0",
				GAME_IDLE_WIPE_MS: "0",
				GAME_ASSETS_DIR: assets,
				...env,
				GAME_PORT: String(authPort),
				GAME_DB_PORT: String(databasePort),
				GAME_HOST: useTls ? "::" : "127.0.0.1",
				GAME_TLS_CERT: useTls ? certFile : "",
				GAME_TLS_KEY: useTls ? keyFile : "",
				NODE_EXTRA_CA_CERTS: useTls
					? certFile
					: process.env.NODE_EXTRA_CA_CERTS,
				GAME_DATA_DIR: dataDir,
				GAME_ORIGIN: origin,
			},
			stdout: "pipe",
			stderr: "pipe",
			detached: true,
		},
	);
	void capture(handle.stdout as ReadableStream<Uint8Array>);
	void capture(handle.stderr as ReadableStream<Uint8Array>);
	processHandle = handle;
}

async function waitForStartup() {
	await eventually(async () => {
		if (processHandle?.exitCode != null)
			throw new Error(`Game exited (${processHandle.exitCode})\n${logs}`);
		try {
			return (await fetch(`${origin}/health`)).ok;
		} catch {
			return false;
		}
	}, "game startup");
}

/** Reselect both child ports after another process stole one pre-bind. */
async function reselectPorts() {
	const [nextAuth, nextDatabase] = await Promise.all([freePort(), freePort()]);
	authPort = nextAuth;
	databasePort = nextDatabase;
	edgeOptions.authPort = authPort;
	edgeOptions.databasePort = databasePort;
	await Bun.sleep(200);
}

async function start(reset = false, env: Record<string, string> = {}) {
	for (let attempt = 0; attempt < 3; attempt++) {
		spawnGame(reset, env);
		try {
			await waitForStartup();
			return;
		} catch (error) {
			if (processHandle?.exitCode == null) throw error;
			if (!/ListenFailed|EADDRINUSE|address already in use/i.test(logs))
				throw error;
			await reselectPorts();
		}
	}
	throw new Error(`Game could not bind its ports after retries\n${logs}`);
}

async function stop() {
	for (const timer of timers.splice(0)) clearInterval(timer);
	for (const client of clients.splice(0)) client.disconnect();
	if (!processHandle || processHandle.exitCode !== null) return;
	// A terminal sends Ctrl+C to the whole foreground process group.
	process.kill(-processHandle.pid, "SIGINT");
	const code = await processHandle.exited;
	assert.equal(code, 0, logs);
}

async function healthState(): Promise<{
	ready: boolean;
	players: number;
	bots: number;
	now: number;
	round: { number: number; startedAt: number; endsAt: number };
}> {
	return await (await fetch(`${origin}/health`)).json();
}

/**
 * Starts the game and waits until the next round boundary is at least
 * `minRunwayMs` away, restarting when a boundary lands during startup.
 */
async function startWithRunway(
	env: Record<string, string>,
	minRunwayMs: number,
	reset = false,
): Promise<{ number: number; startedAt: number; endsAt: number }> {
	for (let attempt = 0; attempt < 6; attempt++) {
		try {
			await start(reset, env);
		} catch {
			// The boundary landed before startup finished; wait for the exit.
			await eventually(
				async () => processHandle?.exitCode != null,
				"boundary exit during startup",
			);
			continue;
		}
		const health = await healthState();
		if (health.round.endsAt - health.now >= minRunwayMs) return health.round;
		await eventually(
			async () => processHandle?.exitCode != null,
			"boundary exit after startup",
			minRunwayMs + 15_000,
		);
	}
	throw new Error("Could not start the game with enough runway");
}

async function claimedAnyLand(client: ZyncBaseClient) {
	const rows = await countryChunks(client);
	return rows.some((row) =>
		readColorIndexes(row.color_indexes).some((byte) => byte !== 0),
	);
}

async function runLifecycle() {
	// 1. A scheduled boundary with a human archives a round and restarts.
	await stop();
	const roundInPlay = await startWithRunway(
		{ GAME_ROUND_MS: "20000" },
		10_000,
		true,
	);
	const player = await connect("Rounders");
	await joinPlayer(
		player.client,
		player.countryId,
		"Rounder",
		player.sessionId,
	);
	const heartbeatTimer = setInterval(
		() => move(player.client, "right", 1),
		500,
	);
	timers.push(heartbeatTimer);
	await eventually(
		async () => claimedAnyLand(player.client),
		"player claims land before the boundary",
	);
	await eventually(
		async () => processHandle?.exitCode != null,
		"boundary restarts the process",
	);
	clearInterval(heartbeatTimer);
	assert.equal(processHandle?.exitCode, 0);
	const historyDir = join(assets, "history");
	const saved = JSON.parse(
		await readFile(join(historyDir, `${roundInPlay.number}.json`), "utf8"),
	);
	assert.equal(saved.number, roundInPlay.number);
	assert.ok(
		saved.humans >= 1,
		"the archive records the human present at the end",
	);
	assert.ok(saved.winner, "the archive records a winner");
	const index = JSON.parse(
		await readFile(join(historyDir, "index.json"), "utf8"),
	);
	assert.equal(index[0].number, roundInPlay.number);
	// The next boot wipes the world and serves results through the edge.
	const next = await startWithRunway({ GAME_ROUND_MS: "20000" }, 10_000);
	assert.equal(next.number, roundInPlay.number + 1);
	assert.equal((await fetch(`${origin}/history.html`)).status, 200);
	assert.equal(
		(await fetch(`${origin}/history/${roundInPlay.number}.json`)).status,
		200,
	);
	const png = await fetch(`${origin}/history/${roundInPlay.number}.png`);
	assert.equal(png.status, 200);
	assert.equal(png.headers.get("content-type"), "image/png");
	const wiped = await connect();
	assert.ok(
		(await countryChunks(wiped.client)).every((row) =>
			readColorIndexes(row.color_indexes).every((byte) => byte === 0),
		),
		"boot after an archive starts a clean world",
	);
	console.log("PASS: scheduled boundary archives, restarts, and wipes");

	// 2. An idle reset restarts without touching the archive or round number.
	await stop();
	const idleRound = await startWithRunway(
		{ GAME_ROUND_MS: "120000", GAME_IDLE_WIPE_MS: "1500" },
		30_000,
		true,
	);
	const idler = await connect("Idlers");
	await joinPlayer(idler.client, idler.countryId, "Idler", idler.sessionId);
	const idleTimer = setInterval(() => move(idler.client, "right", 1), 500);
	timers.push(idleTimer);
	await eventually(
		async () => claimedAnyLand(idler.client),
		"idle player claims land",
	);
	clearInterval(idleTimer);
	idler.client.disconnect();
	await eventually(
		async () => processHandle?.exitCode != null,
		"idle reset restarts the process",
	);
	assert.equal(processHandle?.exitCode, 0);
	const afterIdle = await startWithRunway(
		{ GAME_ROUND_MS: "120000", GAME_IDLE_WIPE_MS: "0" },
		30_000,
	);
	assert.equal(
		afterIdle.number,
		idleRound.number,
		"idle keeps the round number",
	);
	assert.ok(
		!(await readdir(historyDir)).includes(`${idleRound.number}.json`),
		"idle reset writes no history",
	);
	console.log("PASS: idle reset restarts quietly");

	// 3. A boundary without humans also writes no history.
	await stop();
	const emptyRound = await startWithRunway(
		{ GAME_ROUND_MS: "15000" },
		5000,
		true,
	);
	await eventually(
		async () => processHandle?.exitCode != null,
		"empty boundary restarts the process",
	);
	const afterEmpty = await startWithRunway({ GAME_ROUND_MS: "15000" }, 5000);
	assert.equal(
		afterEmpty.number,
		emptyRound.number,
		"an empty boundary keeps the round number",
	);
	assert.ok(
		!(await readdir(historyDir)).includes(`${emptyRound.number}.json`),
		"an empty boundary writes no history",
	);
	console.log("PASS: quiet boundaries write no history");

	// 4. A round whose boundary passed while the process was down is archived
	// by the next boot before the fresh world starts.
	await stop();
	const crashed = await startWithRunway(
		{ GAME_ROUND_MS: "120000" },
		30_000,
		true,
	);
	const crasher = await connect("Crashers");
	await joinPlayer(
		crasher.client,
		crasher.countryId,
		"Crasher",
		crasher.sessionId,
	);
	const crashTimer = setInterval(() => move(crasher.client, "right", 1), 500);
	timers.push(crashTimer);
	await eventually(
		async () => claimedAnyLand(crasher.client),
		"crash-test player claims land",
	);
	clearInterval(crashTimer);
	await stop();
	const cursorPath = join(dataDir, "round.json");
	const cursor = JSON.parse(await readFile(cursorPath, "utf8"));
	await writeFile(
		cursorPath,
		JSON.stringify({ ...cursor, endsAt: Date.now() - 1000 }),
	);
	const recovered = await startWithRunway({ GAME_ROUND_MS: "120000" }, 30_000);
	assert.equal(
		recovered.number,
		crashed.number + 1,
		"an expired round archives at boot",
	);
	assert.ok(
		(await readdir(historyDir)).includes(`${crashed.number}.json`),
		"the expired round's final map is archived",
	);
	const cleaned = await connect();
	assert.ok(
		(await countryChunks(cleaned.client)).every((row) =>
			readColorIndexes(row.color_indexes).every((byte) => byte === 0),
		),
		"the expired round's world is wiped at boot",
	);
	console.log("PASS: an expired round archives at boot and wipes");

	// 5. A played round archives at its boundary even when every human left.
	await stop();
	const leftRound = await startWithRunway(
		{ GAME_ROUND_MS: "30000" },
		15_000,
		true,
	);
	const leaver = await connect("Leavers");
	await joinPlayer(leaver.client, leaver.countryId, "Leaver", leaver.sessionId);
	const leaveTimer = setInterval(() => move(leaver.client, "right", 1), 500);
	timers.push(leaveTimer);
	await eventually(
		async () => claimedAnyLand(leaver.client),
		"departing player claims land",
	);
	clearInterval(leaveTimer);
	leaver.client.disconnect();
	await eventually(async () => {
		try {
			return (await healthState()).players === 0;
		} catch {
			return false;
		}
	}, "player leaves before the boundary");
	await eventually(
		async () => processHandle?.exitCode != null,
		"boundary after the player left restarts the process",
	);
	assert.equal(processHandle?.exitCode, 0);
	const savedLeft = JSON.parse(
		await readFile(join(historyDir, `${leftRound.number}.json`), "utf8"),
	);
	assert.equal(savedLeft.number, leftRound.number);
	assert.equal(
		savedLeft.humans,
		0,
		"the archive records the round after its humans left",
	);
	const afterLeft = await startWithRunway({ GAME_ROUND_MS: "30000" }, 15_000);
	assert.equal(
		afterLeft.number,
		leftRound.number + 1,
		"a played round advances even after its humans left",
	);
	console.log("PASS: a played round archives after its humans leave");

	// 6. A short disconnect keeps the session outliving the tombstone, so a
	// same-token reconnect re-admits the same player.
	await stop();
	await startWithRunway({ GAME_ROUND_MS: "120000" }, 30_000, true);
	const blip = await connect("Blip");
	const blipId = await joinPlayer(
		blip.client,
		blip.countryId,
		"Blipper",
		blip.sessionId,
	);
	const hasDot = async (client: ZyncBaseClient) =>
		(await userChunks(client))
			.flatMap((row) => readCoordinates(row.coordinates))
			.some((dot) => dot.player_id === blipId);
	await eventually(async () => hasDot(blip.client), "blip player has a dot");
	// Claim land first: a landless country is deleted when its player ages out,
	// and then the reconnect would have nothing left to rejoin.
	const blipMoves = setInterval(() => move(blip.client, "right", 1), 500);
	timers.push(blipMoves);
	await eventually(async () => {
		const rows = (await blip.client.store.query(
			"countries",
		)) as unknown as Country[];
		return (
			(rows.find((row) => row.country_id === blip.countryId)?.count ?? 0) > 0
		);
	}, "blip country claims land");
	clearInterval(blipMoves);
	blip.client.disconnect();
	await eventually(
		async () => (await healthState()).players === 0,
		"blip player ages out",
	);
	const revived = createClient({
		url: `ws://localhost:${edge.port}/ws`,
		auth: { token: blip.token },
		storeNamespace: NAMESPACE,
		reconnect: false,
	});
	clients.push(revived);
	await revived.connect();
	const revivedId = await joinPlayer(
		revived,
		blip.countryId,
		"Blipper",
		blip.sessionId,
	);
	assert.equal(revivedId, blipId, "reconnect keeps the player identity");
	await eventually(
		async () => hasDot(revived),
		"reconnect restores the player dot",
	);
	leave(revived);
	revived.disconnect();
	console.log("PASS: a short disconnect resumes the same player");
}

async function connect(countryName?: string) {
	const response = await fetch(`${origin}/session`, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify(countryName === undefined ? {} : { countryName }),
	});
	assert.equal(response.status, 200);
	const {
		token,
		country_id: countryId,
		session_id: sessionId,
	} = await response.json();
	if (countryName !== undefined) assert.equal(typeof countryId, "number");
	const ticketResponse = await fetch(`${origin}/auth/ticket`, {
		method: "POST",
		headers: { Authorization: `Bearer ${token}` },
	});
	assert.equal(ticketResponse.status, 200);
	const { ticket } = await ticketResponse.json();
	const payload = JSON.parse(
		Buffer.from(
			ticket.slice("zyc_tk_".length).split(".")[0],
			"base64url",
		).toString(),
	);
	const jwt = JSON.parse(
		Buffer.from(token.split(".")[1], "base64url").toString(),
	);
	assert.equal(payload.session.tokenExpiresAt, jwt.exp);
	assert.ok(payload.session.tokenExpiresAt > payload.exp);
	const client = createClient({
		url: `ws://localhost:${edge.port}/ws`,
		auth: { token },
		storeNamespace: NAMESPACE,
		reconnect: false,
	});
	clients.push(client);
	await client.connect();
	return { client, countryId, sessionId, token };
}

/** Admit a player through the sync join action and return its identity. */
async function joinPlayer(
	client: ZyncBaseClient,
	countryId: number | undefined,
	name: string,
	sessionId: string,
) {
	assert.equal(typeof countryId, "number");
	// The worker registers handlers just after /health turns ready; retry
	// briefly so tests do not race that registration.
	const deadline = Date.now() + 5000;
	for (;;) {
		try {
			const result = (await client.actions.call("player_join", {
				name,
				country_id: countryId,
				session_id: sessionId,
			})) as { user_id?: string };
			assert.equal(typeof result.user_id, "string");
			return result.user_id as string;
		} catch (error) {
			if (Date.now() >= deadline) throw error;
			await Bun.sleep(50);
		}
	}
}

/** Fire-and-forget input, mirroring the browser's publish(). */
function move(client: ZyncBaseClient, direction: string, seq = 1) {
	void client.actions.call("player_move", { direction, seq }).catch(() => {});
}

/** Best-effort immediate leave on top of the input lease. */
function leave(client: ZyncBaseClient) {
	void client.actions.call("player_leave", {}).catch(() => {});
}

async function countryChunks(client: ZyncBaseClient) {
	return (await client.store.query("country_chunks", {
		limit: 2048,
	})) as unknown as CountryChunkRow[];
}

async function userChunks(client: ZyncBaseClient) {
	return (await client.store.query("user_chunks", {
		limit: 100,
	})) as unknown as UserChunkRow[];
}

try {
	await start();
	const {
		countries: lobbyCountries,
		round: lobbyRound,
		now: healthNow,
		...health
	} = await (await fetch(`${origin}/health`)).json();
	assert.deepEqual(health, {
		ready: true,
		players: 0,
		bots: 0,
	});
	assert.equal(typeof healthNow, "number");
	assert.equal(typeof lobbyRound.number, "number");
	assert.equal(
		lobbyRound.endsAt % 3_600_000,
		0,
		"round boundaries land on the hour",
	);
	assert.ok(lobbyRound.endsAt > healthNow);
	assert.equal(
		lobbyCountries.length,
		0,
		"bot countries wait until a point has its first human",
	);
	assert.equal((await fetch(origin)).status, 200);
	assert.equal((await fetch(`${origin}/client.js`)).status, 200);
	// The VM's token issuer serves neither browser assets nor database tickets.
	for (const path of ["/", "/client.js", "/auth/ticket"]) {
		const response = await fetch(
			`${useTls ? "https://[::1]" : "http://127.0.0.1"}:${authPort}${path}`,
			{
				method: path === "/auth/ticket" ? "POST" : "GET",
				// Match the local edge's certificate name while connecting over IPv6.
				tls: { ca: cert, serverName: "localhost" },
			},
		);
		assert.equal(response.status, 404);
	}
	assert.equal(
		(
			await fetch(`${origin}/auth/ticket`, {
				method: "POST",
				headers: { Authorization: "Bearer invalid" },
			})
		).status,
		401,
	);
	assert.equal((await fetch(`${origin}/session`)).status, 404);
	assert.equal(
		(
			await fetch(`${origin}/session`, {
				method: "POST",
				headers: { Origin: "https://untrusted.example" },
			})
		).status,
		403,
	);
	const alice = await connect("North"),
		bob = await connect("South");
	// Subscribe before anyone joins: the admitted rows must arrive as deltas,
	// not the initial snapshot (the browser creates the roster subscription
	// before its join too).
	const subscribed = new Map<string, PlayerRow>();
	bob.client.store.subscribe("users", { limit: 2048 }, (rows) => {
		subscribed.clear();
		for (const row of rows as PlayerRow[]) subscribed.set(row.id, row);
	});
	const aliceId = await joinPlayer(
		alice.client,
		alice.countryId,
		"Ａlice",
		alice.sessionId,
	);
	let direction = "idle",
		seq = 1;
	const send = () => move(alice.client, direction, seq);
	send();
	timers.push(setInterval(send, 500));
	const bobId = await joinPlayer(
		bob.client,
		bob.countryId,
		"Bob",
		bob.sessionId,
	);
	assert.notEqual(aliceId, bobId);
	let visible: UserChunkRow[] = [];
	bob.client.store.subscribe("user_chunks", { limit: 100 }, (rows) => {
		visible = rows as UserChunkRow[];
	});
	const dot = () =>
		visible
			.flatMap((row) => readCoordinates(row.coordinates))
			.find((dot) => dot.player_id === aliceId);
	const rosterOf = async (client: ZyncBaseClient) =>
		new Map(
			((await client.store.query("users", { limit: 2048 })) as PlayerRow[]).map(
				(row) => [row.id, row],
			),
		);
	const first = await eventually(
		async () => dot(),
		"join action creates a subscribed dot",
	);
	const aliceRow = await eventually(async () => {
		const row = (await rosterOf(bob.client)).get(aliceId);
		return row?.name === "Alice" ? row : undefined;
	}, "roster carries normalized player names");
	await eventually(
		async () => subscribed.get(aliceId)?.name === "Alice",
		"users subscription receives live roster deltas",
	);
	assert.equal(aliceRow.country_id, alice.countryId);
	assert.equal(aliceRow.is_bot, false);
	assert.deepEqual([aliceRow.last_x, aliceRow.last_y], [first.x, first.y]);
	await eventually(
		async () =>
			visible
				.flatMap((row) => readCoordinates(row.coordinates))
				.some((dot) => dot.player_id === bobId) &&
			(await rosterOf(bob.client)).get(bobId)?.name === "Bob",
		"other humans have roster-backed map dots",
	);
	const roster = (await (await fetch(`${origin}/health`)).json())
		.countries as Country[];
	const north = roster.find((country) => country.name === "North");
	assert.ok(north, "new countries appear in the lobby");
	assert.equal(north.is_bot, false, "human countries are not flagged as bots");
	assert.equal(
		north.country_id,
		alice.countryId,
		"session returns the persisted country id",
	);
	const teammate = await connect();
	const teammateId = await joinPlayer(
		teammate.client,
		north.country_id,
		"Teammate",
		teammate.sessionId,
	);
	await eventually(
		async () =>
			visible
				.flatMap((row) => readCoordinates(row.coordinates))
				.some((dot) => dot.player_id === teammateId) &&
			(await rosterOf(bob.client)).get(teammateId)?.country_id ===
				north.country_id,
		"lobby selection joins an existing country by id",
	);
	await eventually(
		async () => (await (await fetch(`${origin}/health`)).json()).bots === 3,
		"a point's second human leaves one bot",
	);
	leave(teammate.client);
	teammate.client.disconnect();
	const botRoster = await eventually(async () => {
		const state = await (await fetch(`${origin}/health`)).json();
		return state.bots === 4 ? (state.countries as Country[]) : undefined;
	}, "the point's second bot returns when its second human leaves");
	assert.equal(
		botRoster.filter((country) => country.is_bot).length,
		2,
		"each occupied point has its own bot country",
	);
	assert.ok(
		botRoster.every((country) => COUNTRY_COLORS.includes(country.color)),
		"bot country colors come from the palette",
	);
	console.log(
		`PASS: open admission, identity, player names, same-origin routing, ${useTls ? "IPv6 HTTPS/WSS" : "HTTP/WS"}, actions → store subscription`,
	);
	direction = "right";
	seq++;
	send();
	await eventually(async () => {
		const current = dot();
		return current && current.x > first.x + 2;
	}, "movement");
	direction = "idle";
	seq++;
	send();
	// No per-dot ack echo remains: wait until the dot holds still instead.
	const stopped = await eventually(async () => {
		const a = dot();
		if (!a) return undefined;
		await Bun.sleep(150);
		const b = dot();
		return b && b.x === a.x && b.y === a.y ? b : undefined;
	}, "idle acknowledgment");
	await Bun.sleep(700);
	assert.deepEqual(
		[dot()?.x, dot()?.y],
		[stopped.x, stopped.y],
		"key release stops movement",
	);
	const row = visible.find((row) =>
		readCoordinates(row.coordinates).some((dot) => dot.player_id === aliceId),
	);
	assert.ok(row);
	await assert.rejects(
		alice.client.store.set(
			["user_chunks", row.id, "coordinates"],
			new Uint8Array(),
		),
		{ code: "PERMISSION_DENIED" },
	);
	await assert.rejects(
		alice.client.store.create("countries", {
			country_id: 99,
			name: "Cheat",
			color: "red",
			count: 999,
		}),
		{ code: "PERMISSION_DENIED" },
	);
	let actionDenied = false;
	alice.client.on("error", (error) => {
		if ((error as { code?: string })?.code === "PERMISSION_DENIED")
			actionDenied = true;
	});
	alice.client.actions.handle("player_move", () => {});
	await eventually(
		async () => actionDenied,
		"player worker registration denied",
	);
	await assert.rejects(
		alice.client.actions.call("player_move", { direction: "sideways", seq: 2 }),
		{ code: "SCHEMA_VALIDATION_FAILED" },
	);
	for (const timer of timers.splice(0)) clearInterval(timer);
	leave(alice.client);
	alice.client.disconnect();
	await eventually(async () => !dot(), "disconnected dot removed");
	leave(bob.client);
	bob.client.disconnect();
	const observer = await connect();
	await eventually(async () => {
		const health = await (await fetch(`${origin}/health`)).json();
		return health.players === 0 && health.bots === 0;
	}, "an empty world holds no bots");
	await eventually(async () => {
		const dots = (await userChunks(observer.client)).flatMap((row) =>
			readCoordinates(row.coordinates),
		);
		return dots.length === 0;
	}, "bot dots cleared without humans");
	// Country rows publish on a slower cadence than chunk writes, so a just-
	// frozen world can still have a roster flush pending. Snapshot only once
	// two reads across a flush interval agree, or the saved counts may lag the
	// chunks and the restart comparison fails on a pixel that moved since.
	const savedCountries = (await eventually(async () => {
		const before = (await observer.client.store.query(
			"countries",
		)) as unknown as Country[];
		await Bun.sleep(750);
		const after = (await observer.client.store.query(
			"countries",
		)) as unknown as Country[];
		return JSON.stringify(before) === JSON.stringify(after) ? after : undefined;
	}, "roster settled")) as Country[];
	assert.ok(savedCountries.some((country) => country.count > 0));
	const savedChunks = await countryChunks(observer.client);
	console.log("PASS: movement, stop, authorization, disconnected dot cleanup");
	await stop();
	await start();
	const returning = await connect();
	const restoredChunks = await countryChunks(returning.client);
	for (const row of savedChunks) {
		const saved = restoredChunks.find((restored) => restored.id === row.id);
		assert.ok(saved, "every saved chunk row survives the restart");
		assert.deepEqual(
			readColorIndexes(saved.color_indexes),
			readColorIndexes(row.color_indexes),
		);
	}
	assert.ok(
		(await userChunks(returning.client)).every(
			(row) => readCoordinates(row.coordinates).length === 0,
		),
		"restart clears every dot: no humans, so no bots",
	);
	const restoredRoster = await rosterOf(returning.client);
	// Reads materialize absent optional fields as explicit nulls; identity
	// stubs (connected-but-never-admitted clients) carry no roster data.
	const isStub = (row: PlayerRow) => row.country_id == null;
	assert.ok(
		![aliceId, bobId, teammateId].some((id) => restoredRoster.has(id)),
		"stale human roster rows purged on restart",
	);
	assert.ok(
		[...restoredRoster.values()].every(
			(row) => row.is_bot === true || isStub(row),
		),
		"only fieldless identity stubs remain without humans",
	);
	const restoredCountries = (await returning.client.store.query(
		"countries",
	)) as unknown as Country[];
	for (const country of savedCountries) {
		assert.equal(
			restoredCountries.find((saved) => saved.country_id === country.country_id)
				?.count,
			country.count,
		);
		assert.equal(
			restoredCountries.find((saved) => saved.country_id === country.country_id)
				?.color,
			country.color,
		);
	}
	await assert.rejects(returning.client.setStoreNamespace("another-world"), {
		code: "NAMESPACE_SWITCH_REJECTED",
	});
	console.log(
		"PASS: committed territory and counts restored, stale dots cleared, namespace isolated",
	);
	await stop();
	// Only this start creates reserved-but-abandoned countries (the cap test
	// below), so shorten the lease here; earlier starts keep the default so a
	// real admission cannot race the reaper. That test opens dozens of
	// sessions from one address, so it disables the per-network cap.
	await start(true, {
		GAME_COUNTRY_LEASE_MS: "500",
		GAME_PLAYERS_PER_IP: "0",
	});
	const clean = await connect();
	assert.ok(
		(await countryChunks(clean.client)).every((row) =>
			readColorIndexes(row.color_indexes).every((byte) => byte === 0),
		),
	);
	const fresh = (await clean.client.store.query(
		"countries",
	)) as unknown as Country[];
	assert.equal(
		fresh.length,
		0,
		"reset defers bot countries until a human arrives",
	);
	// Reset clears territory and the roster; bot countries appear lazily with
	// their point's first human, so only this client's fieldless stub remains.
	const resetRoster = await rosterOf(clean.client);
	assert.equal(
		[...resetRoster.values()].filter((row) => row.is_bot === true).length,
		0,
	);
	assert.ok(
		[...resetRoster.values()].every(
			(row) => row.is_bot === true || row.country_id == null,
		),
	);
	console.log("PASS: manual world reset");
	for (const body of [
		"null",
		"[]",
		"{",
		JSON.stringify({ countryName: "\u0000" }),
		JSON.stringify({ countryName: "x".repeat(1024) }),
	]) {
		assert.equal(
			(await fetch(`${origin}/session`, { method: "POST", body })).status,
			400,
		);
	}
	assert.equal(
		(
			await fetch(`${origin}/session`, {
				method: "POST",
				body: JSON.stringify({ countryName: "Polandia" }),
			})
		).status,
		409,
		"bot country names are rejected",
	);
	// Concurrent creation requests cannot exceed the live-country cap.
	const attempts = await Promise.all(
		Array.from({ length: MAX_COUNTRIES - fresh.length + 1 }, (_, i) =>
			fetch(`${origin}/session`, {
				method: "POST",
				body: JSON.stringify({ countryName: `Reserved ${i}` }),
			}),
		),
	);
	assert.equal(
		attempts.filter((response) => response.status === 200).length,
		MAX_COUNTRIES - fresh.length,
	);
	assert.equal(
		attempts.filter((response) => response.status === 409).length,
		1,
	);
	assert.equal(
		(await (await fetch(`${origin}/health`)).json()).countries.length,
		MAX_COUNTRIES,
	);
	assert.equal(
		(await fetch(`${origin}/session`, { method: "POST" })).status,
		200,
		"existing-country players still receive sessions",
	);
	await eventually(
		async () =>
			(await (await fetch(`${origin}/health`)).json()).countries.length ===
			fresh.length,
		"unused country reservations expire",
	);
	console.log(
		"PASS: session country creation, request validation, concurrent country cap, abandoned-slot cleanup",
	);
	await stop();
	// Per-network admission: a joined player holds its slot, a leave frees it,
	// and an issued-but-unjoined session expires on its lease.
	await start(true, {
		GAME_PLAYERS_PER_IP: "1",
		GAME_SESSION_LEASE_MS: "5000",
	});
	const askSession = (ip?: string) =>
		fetch(`${origin}/session`, {
			method: "POST",
			...(ip ? { headers: { "X-Forwarded-For": ip } } : {}),
		});
	const solo = await connect("Soloers");
	await joinPlayer(solo.client, solo.countryId, "Solo", solo.sessionId);
	assert.equal(
		(await askSession()).status,
		429,
		"a second session from one network is rejected",
	);
	leave(solo.client);
	solo.client.disconnect();
	await eventually(
		async () => (await healthState()).players === 0,
		"leave removes the player before its session lease expires",
		1000,
	);
	await eventually(
		async () => (await askSession()).status === 200,
		"leave frees the network slot before its session lease expires",
		1000,
	);
	// The eventual's successful call issued an unjoined session; it holds the
	// slot until its lease expires.
	assert.equal(
		(await askSession()).status,
		429,
		"an unjoined session holds its slot",
	);
	await eventually(
		async () => (await askSession()).status === 200,
		"abandoned sessions expire",
	);
	await stop();
	// The same IPv6 /64 shares its five slots whatever the notation; abandoned
	// sessions expire, and a different /64 keeps its own pool.
	await start(true, {
		GAME_PLAYERS_PER_IP: "5",
		GAME_COUNTRY_LEASE_MS: "500",
		GAME_SESSION_LEASE_MS: "500",
	});
	for (const ip of [
		"2001:db8:1:1::1",
		"2001:0DB8:0001:0001:0:0:0:2",
		"2001:db8:1:1:abcd::3",
		"2001:db8:1:1::4",
		"2001:db8:1:1::5",
	])
		assert.equal((await askSession(ip)).status, 200, `same /64 admits ${ip}`);
	assert.equal(
		(await askSession("2001:db8:1:1::6")).status,
		429,
		"the sixth address in a /64 is rejected",
	);
	assert.equal(
		(await askSession("2001:db8:1:2::1")).status,
		200,
		"a different /64 is admitted",
	);
	await eventually(
		async () => (await askSession("2001:db8:1:1::6")).status === 200,
		"abandoned sessions expire",
	);
	console.log(
		"PASS: per-network player limit, IPv6 /64 grouping, lease and leave release",
	);
	if (!useTls) await runLifecycle();
} catch (error) {
	console.error(logs);
	throw error;
} finally {
	await stop();
	await edge.stop();
	await rm(dataDir, { recursive: true, force: true });
}
