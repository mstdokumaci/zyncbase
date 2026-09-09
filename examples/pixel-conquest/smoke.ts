import assert from "node:assert/strict";
import { mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createClient, type ZyncBaseClient } from "@zyncbase/client";
import { buildBrowser } from "./build";
import { startLocalEdge } from "./dev";
import { type ChunkRow, type Country, NAMESPACE, readDots } from "./shared";

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

async function start(reset = false) {
	processHandle = Bun.spawn(
		["bun", join(import.meta.dir, "server.ts"), ...(reset ? ["--reset"] : [])],
		{
			env: {
				...process.env,
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
				GAME_JOIN_CODE: "smoke-test",
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

async function connect() {
	const response = await fetch(`${origin}/session`, {
		method: "POST",
		body: JSON.stringify({ code: "smoke-test" }),
	});
	assert.equal(response.status, 200);
	const { token } = await response.json();
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
	const users = await client.store.query("users");
	assert.equal(users.length, 1, "players only see their own identity");
	return { client, id: String((users[0] as { id: string }).id) };
}

async function chunks(client: ZyncBaseClient) {
	return (await client.store.query("chunks", {
		limit: 100,
	})) as unknown as ChunkRow[];
}

try {
	await start();
	assert.deepEqual(await (await fetch(`${origin}/health`)).json(), {
		ready: true,
		players: 0,
		bots: 10,
	});
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
	assert.equal(
		(
			await fetch(`${origin}/session`, {
				method: "POST",
				body: '{"code":"wrong"}',
			})
		).status,
		403,
	);
	assert.equal(
		(
			await fetch(`${origin}/session`, {
				method: "POST",
				headers: { Origin: "https://untrusted.example" },
			})
		).status,
		403,
	);
	const alice = await connect(),
		bob = await connect();
	assert.notEqual(alice.id, bob.id);
	const input = {
		country: "North",
		direction: "idle",
		seq: 1,
		sentAt: Date.now(),
		pulse: 0,
	};
	const send = () =>
		alice.client.presence.set({ ...input, pulse: ++input.pulse });
	send();
	timers.push(setInterval(send, 500));
	bob.client.presence.set({
		country: "South",
		direction: "idle",
		seq: 1,
		sentAt: Date.now(),
		pulse: 1,
	});
	let visible: ChunkRow[] = [];
	bob.client.store.subscribe("chunks", { limit: 100 }, (rows) => {
		visible = rows as ChunkRow[];
	});
	const dot = () =>
		visible
			.flatMap((row) => readDots(row.dots))
			.find((dot) => dot.id === alice.id);
	const first = await eventually(
		async () => dot(),
		"presence input creates a subscribed dot",
	);
	await eventually(
		async () => (await (await fetch(`${origin}/health`)).json()).bots === 9,
		"two humans replace one bot",
	);
	console.log(
		`PASS: invite, identity, same-origin routing, ${useTls ? "IPv6 HTTPS/WSS" : "HTTP/WS"}, presence → store subscription`,
	);
	input.direction = "right";
	input.seq++;
	input.sentAt = Date.now();
	send();
	await eventually(async () => {
		const current = dot();
		return current && current.x > first.x + 2;
	}, "movement");
	input.direction = "idle";
	input.seq++;
	input.sentAt = Date.now();
	send();
	const stopped = await eventually(async () => {
		const current = dot();
		return current?.seq === input.seq ? current : undefined;
	}, "idle acknowledgment");
	await Bun.sleep(700);
	assert.deepEqual(
		[dot()?.x, dot()?.y],
		[stopped.x, stopped.y],
		"key release stops movement",
	);
	const row = visible.find((row) =>
		readDots(row.dots).some((dot) => dot.id === alice.id),
	);
	assert.ok(row);
	await assert.rejects(
		alice.client.store.set(["chunks", row.id, "occupied"], false),
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
		return dots.length === 10 && dots.every((dot) => dot.bot);
	}, "idle bot state committed");
	const savedCountries = (await observer.client.store.query(
		"countries",
	)) as unknown as Country[];
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
		restoredChunks.every((row) => readDots(row.dots).every((dot) => dot.bot)),
	);
	const restoredCountries = (await returning.client.store.query(
		"countries",
	)) as unknown as Country[];
	for (const country of savedCountries)
		assert.equal(
			restoredCountries.find((saved) => saved.code === country.code)?.count,
			country.count,
		);
	await assert.rejects(returning.client.setStoreNamespace("another-world"), {
		code: "NAMESPACE_UNAUTHORIZED",
	});
	console.log(
		"PASS: committed territory and counts restored, stale dots cleared, namespace isolated",
	);
	await stop();
	await start(true);
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
	console.log("PASS: manual world reset");
} catch (error) {
	console.error(logs);
	throw error;
} finally {
	await stop();
	await stopEdge();
	await rm(dataDir, { recursive: true, force: true });
}
