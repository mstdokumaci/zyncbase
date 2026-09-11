import assert from "node:assert/strict";
import { mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createClient, type ZyncBaseClient } from "@zyncbase/client";
import { buildBrowser } from "./build";
import { startLocalEdge } from "./dev";
import {
	type ChunkRow,
	COUNTRY_COLORS,
	type Country,
	MAX_COUNTRIES,
	NAMESPACE,
	readDots,
	type UserRow,
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

async function eventually<T>(check: () => Promise<T>, label: string) {
	const deadline = Date.now() + 30000;
	while (Date.now() < deadline) {
		const value = await check();
		if (value) return value;
		await Bun.sleep(100);
	}
	throw new Error(`Timed out: ${label}`);
}

const dataDir = await mkdtemp(join(tmpdir(), "pixel-conquest-smoke-"));
const port = await freePort(),
	authPort = await freePort(),
	databasePort = await freePort();
const origin = `http://localhost:${port}`;
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
	"index.html",
	"style.css",
]);
const stopEdge = await startLocalEdge({
	port,
	authPort,
	databasePort,
	assets,
	ca: cert,
});
let processHandle: Bun.Subprocess | undefined;
let logs = "";
const clients: ZyncBaseClient[] = [];
const timers: ReturnType<typeof setInterval>[] = [];

async function capture(stream: ReadableStream<Uint8Array>) {
	for await (const chunk of stream)
		logs = (logs + new TextDecoder().decode(chunk)).slice(-20000);
}

async function start(reset = false, env: Record<string, string> = {}) {
	processHandle = Bun.spawn(
		["bun", join(import.meta.dir, "server.ts"), ...(reset ? ["--reset"] : [])],
		{
			env: {
				...process.env,
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
	void capture(processHandle.stdout as ReadableStream<Uint8Array>);
	void capture(processHandle.stderr as ReadableStream<Uint8Array>);
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

async function stop() {
	for (const timer of timers.splice(0)) clearInterval(timer);
	for (const client of clients.splice(0)) client.disconnect();
	if (!processHandle || processHandle.exitCode !== null) return;
	// A terminal sends Ctrl+C to the whole foreground process group.
	process.kill(-processHandle.pid, "SIGINT");
	const code = await processHandle.exited;
	assert.equal(code, 0, logs);
}

async function connect(countryName?: string) {
	const response = await fetch(`${origin}/session`, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify(countryName === undefined ? {} : { countryName }),
	});
	assert.equal(response.status, 200);
	const { token, countryCode } = await response.json();
	if (countryName !== undefined) assert.equal(typeof countryCode, "number");
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
		url: `ws://localhost:${port}/ws`,
		auth: { token },
		storeNamespace: NAMESPACE,
		presenceNamespace: NAMESPACE,
		reconnect: false,
	});
	clients.push(client);
	await client.connect();
	// Identity comes from scope setup: the users table now holds the whole
	// public roster, so a table scan can no longer identify self.
	let id = client.presence.localUserId ?? "";
	for (let i = 0; i < 100 && !id; i++) {
		await Bun.sleep(100);
		id = client.presence.localUserId ?? "";
	}
	assert.ok(id, "scope setup resolves our own identity");
	return { client, id, countryCode };
}

async function chunks(client: ZyncBaseClient) {
	return (await client.store.query("chunks", {
		limit: 100,
	})) as unknown as ChunkRow[];
}

try {
	await start();
	const { countries: lobbyCountries, ...health } = await (
		await fetch(`${origin}/health`)
	).json();
	assert.deepEqual(health, {
		ready: true,
		players: 0,
		bots: 10,
	});
	assert.equal(lobbyCountries.length, 5, "lobby lists countries before login");
	assert.equal(
		new Set(lobbyCountries.map((country: Country) => country.color)).size,
		5,
	);
	assert.ok(
		lobbyCountries.every((country: Country) =>
			COUNTRY_COLORS.includes(country.color),
		),
	);
	assert.ok(
		lobbyCountries.every((country: Country) => country.is_bot === true),
		"starting countries are bot countries",
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
	assert.notEqual(alice.id, bob.id);
	// Subscribe before any presence is set: the admitted rows must arrive as
	// deltas, not the initial snapshot (the browser creates the roster
	// subscription before its first presence.set too).
	const subscribed = new Map<string, UserRow>();
	bob.client.store.subscribe("users", { limit: 2048 }, (rows) => {
		subscribed.clear();
		for (const row of rows as UserRow[]) subscribed.set(row.id, row);
	});
	const input = {
		name: "Ａlice",
		countryCode: alice.countryCode,
		direction: "idle",
		seq: 1,
	};
	const send = () => alice.client.presence.set({ ...input });
	send();
	timers.push(setInterval(send, 500));
	bob.client.presence.set({
		name: "Bob",
		countryCode: bob.countryCode,
		direction: "idle",
		seq: 1,
	});
	let visible: ChunkRow[] = [];
	bob.client.store.subscribe("chunks", { limit: 100 }, (rows) => {
		visible = rows as ChunkRow[];
	});
	const dot = () =>
		visible
			.flatMap((row) => readDots(row.dots))
			.find((dot) => dot.player_id === alice.id);
	const rosterOf = async (client: ZyncBaseClient) =>
		new Map(
			((await client.store.query("users", { limit: 2048 })) as UserRow[]).map(
				(row) => [row.id, row],
			),
		);
	const first = await eventually(
		async () => dot(),
		"presence input creates a subscribed dot",
	);
	const aliceRow = await eventually(async () => {
		const row = (await rosterOf(bob.client)).get(alice.id);
		return row?.name === "Alice" ? row : undefined;
	}, "roster carries normalized player names");
	await eventually(
		async () => subscribed.get(alice.id)?.name === "Alice",
		"users subscription receives live roster deltas",
	);
	assert.equal(aliceRow.country_id, alice.countryCode);
	assert.equal(aliceRow.is_bot, false);
	assert.deepEqual([aliceRow.lastX, aliceRow.lastY], [first.x, first.y]);
	await eventually(
		async () =>
			visible
				.flatMap((row) => readDots(row.dots))
				.some((dot) => dot.player_id === bob.id) &&
			(await rosterOf(bob.client)).get(bob.id)?.name === "Bob",
		"other humans have roster-backed map dots",
	);
	const roster = (await (await fetch(`${origin}/health`)).json())
		.countries as Country[];
	const north = roster.find((country) => country.name === "North");
	assert.ok(north, "new countries appear in the lobby");
	assert.equal(north.is_bot, false, "human countries are not flagged as bots");
	assert.equal(
		north.code,
		alice.countryCode,
		"session returns the persisted country code",
	);
	const teammate = await connect();
	teammate.client.presence.set({
		name: "Teammate",
		countryCode: north.code,
		direction: "idle",
		seq: 1,
	});
	await eventually(
		async () =>
			visible
				.flatMap((row) => readDots(row.dots))
				.some((dot) => dot.player_id === teammate.id) &&
			(await rosterOf(bob.client)).get(teammate.id)?.country_id === north.code,
		"lobby selection joins an existing country by code",
	);
	teammate.client.disconnect();
	await eventually(
		async () => (await (await fetch(`${origin}/health`)).json()).bots === 9,
		"two humans replace one bot",
	);
	console.log(
		`PASS: open admission, identity, player names, same-origin routing, ${useTls ? "IPv6 HTTPS/WSS" : "HTTP/WS"}, presence → store subscription`,
	);
	input.direction = "right";
	input.seq++;
	send();
	await eventually(async () => {
		const current = dot();
		return current && current.x > first.x + 2;
	}, "movement");
	input.direction = "idle";
	input.seq++;
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
		readDots(row.dots).some((dot) => dot.player_id === alice.id),
	);
	assert.ok(row);
	await assert.rejects(
		alice.client.store.set(["chunks", row.id, "dots"], new Uint8Array()),
		{ code: "PERMISSION_DENIED" },
	);
	await assert.rejects(
		alice.client.store.create("countries", {
			code: 99,
			name: "Cheat",
			color: "red",
			count: 999,
		}),
		{ code: "PERMISSION_DENIED" },
	);
	let sharedDenied = false;
	alice.client.on("error", (error) => {
		if ((error as { code?: string })?.code === "NAMESPACE_UNAUTHORIZED")
			sharedDenied = true;
	});
	alice.client.presence.setShared({});
	await eventually(async () => sharedDenied, "shared presence write denied");
	for (const timer of timers.splice(0)) clearInterval(timer);
	alice.client.disconnect();
	await eventually(async () => !dot(), "disconnected dot removed");
	bob.client.disconnect();
	const observer = await connect();
	await eventually(async () => {
		const health = await (await fetch(`${origin}/health`)).json();
		return health.players === 0 && health.bots === 10;
	}, "bots return when humans leave");
	await eventually(async () => {
		const dots = (await chunks(observer.client)).flatMap((row) =>
			readDots(row.dots),
		);
		if (dots.length !== 10) return false;
		const roster = await rosterOf(observer.client);
		return dots.every((dot) => roster.get(dot.player_id)?.is_bot === true);
	}, "idle bot state committed");
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
	const savedChunks = await chunks(observer.client);
	console.log("PASS: movement, stop, authorization, disconnected dot cleanup");
	await stop();
	await start();
	const returning = await connect();
	const restoredChunks = await chunks(returning.client);
	for (const row of savedChunks)
		assert.deepEqual(
			restoredChunks.find((saved) => saved.id === row.id)?.owners,
			row.owners,
		);
	assert.ok(
		restoredChunks.every((row) => {
			const dots = readDots(row.dots);
			return dots.every((dot) => dot.player_id.startsWith("bot-"));
		}),
		"stale human dots cleared, bot dots republished slim",
	);
	const restoredRoster = await rosterOf(returning.client);
	// Reads materialize absent optional fields as explicit nulls; identity
	// stubs (connected-but-never-admitted clients) carry no roster data.
	const isStub = (row: UserRow) => row.country_id == null;
	assert.ok(
		![alice.id, bob.id, teammate.id].some((id) => restoredRoster.has(id)),
		"stale human roster rows purged on restart",
	);
	assert.ok(
		[...restoredRoster.values()].every(
			(row) => row.is_bot === true || isStub(row),
		),
		"only bots and fieldless identity stubs remain",
	);
	const restoredCountries = (await returning.client.store.query(
		"countries",
	)) as unknown as Country[];
	for (const country of savedCountries) {
		assert.equal(
			restoredCountries.find((saved) => saved.code === country.code)?.count,
			country.count,
		);
		assert.equal(
			restoredCountries.find((saved) => saved.code === country.code)?.color,
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
	// real admission cannot race the reaper.
	await start(true, { GAME_COUNTRY_LEASE_MS: "500" });
	const clean = await connect();
	assert.ok(
		(await chunks(clean.client)).every((row) =>
			row.owners.every((byte) => byte === 0),
		),
	);
	const fresh = (await clean.client.store.query(
		"countries",
	)) as unknown as Country[];
	assert.equal(fresh.length, 5);
	assert.ok(fresh.every((country) => country.count === 0));
	assert.ok(
		fresh.every((country) => country.is_bot === true),
		"reset repopulates bot countries",
	);
	// Reset clears territory and the roster, then bots immediately repopulate
	// (plus this client's own fieldless identity row).
	const resetRoster = await rosterOf(clean.client);
	assert.equal(
		[...resetRoster.values()].filter((row) => row.is_bot === true).length,
		10,
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
				body: JSON.stringify({ countryName: "Bot · Amber" }),
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
} catch (error) {
	console.error(logs);
	throw error;
} finally {
	await stop();
	await stopEdge();
	await rm(dataDir, { recursive: true, force: true });
}
