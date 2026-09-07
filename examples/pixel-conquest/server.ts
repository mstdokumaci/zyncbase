import {
	createHmac,
	randomBytes,
	randomUUID,
	timingSafeEqual,
} from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import {
	createServer,
	request as httpRequest,
	type IncomingMessage,
	type ServerResponse,
} from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import type { Duplex } from "node:stream";
import {
	type BatchOperation,
	createClient,
	type JsonValue,
} from "@zyncbase/client";
import {
	type ChunkRow,
	type Country,
	MAX_PLAYERS,
	NAMESPACE,
	RULES,
	terrain,
} from "./shared";
import { World } from "./world";

const directory = import.meta.dir;
const root = resolve(directory, "../..");
const port = Number(process.env.GAME_PORT ?? 8080);
const databasePort = Number(process.env.GAME_DB_PORT ?? 3001);
const host = process.env.GAME_HOST ?? "127.0.0.1";
const origin = process.env.GAME_ORIGIN ?? `http://localhost:${port}`;
const dataDir = resolve(
	process.env.GAME_DATA_DIR ?? join(root, "data/pixel-conquest"),
);
const joinCode = process.env.GAME_JOIN_CODE || randomBytes(6).toString("hex");
const secret = randomBytes(32).toString("hex");
const world = new World(terrain());
let ready = false;
let stopping = false;
let inFlight: Promise<void> | null = null;
let flushes = 0,
	chunkWrites = 0,
	payloadBytes = 0,
	commitMs = 0;
const connections = new Set<Duplex>();

function token(role: "player" | "simulation") {
	const now = Math.floor(Date.now() / 1000);
	const encode = (value: unknown) =>
		Buffer.from(JSON.stringify(value)).toString("base64url");
	const payload = `${encode({ alg: "HS256", typ: "JWT" })}.${encode({ sub: `${role}:${randomUUID()}`, role, iat: now, exp: now + 86400 })}`;
	return `${payload}.${createHmac("sha256", secret).update(payload).digest("base64url")}`;
}

function allowedOrigin(req: IncomingMessage) {
	return !req.headers.origin || req.headers.origin === origin;
}

function reply(res: ServerResponse, status: number, body: unknown) {
	res.writeHead(status, {
		"Content-Type": "application/json",
		"Cache-Control": "no-store",
	});
	res.end(JSON.stringify(body));
}

async function body(req: IncomingMessage) {
	const chunks: Buffer[] = [];
	let size = 0;
	for await (const chunk of req) {
		size += chunk.length;
		if (size > 1024) throw new Error("Request too large");
		chunks.push(Buffer.from(chunk));
	}
	return JSON.parse(Buffer.concat(chunks).toString());
}

const bundle = await Bun.build({
	entrypoints: [join(directory, "client.ts")],
	target: "browser",
	minify: true,
});
if (!bundle.success) throw new Error(bundle.logs.join("\n"));
const assets = new Map([
	[
		"/",
		{
			type: "text/html; charset=utf-8",
			bytes: await readFile(join(directory, "index.html")),
		},
	],
	[
		"/style.css",
		{ type: "text/css", bytes: await readFile(join(directory, "style.css")) },
	],
	[
		"/client.js",
		{
			type: "text/javascript",
			bytes: Buffer.from(await bundle.outputs[0].arrayBuffer()),
		},
	],
]);

// ponytail: one shared login budget for a friends-only demo; use per-client limits for public signup.
let logins = 0,
	loginWindow = Date.now();
// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: these are the complete HTTP routes for this small standalone demo.
const front = createServer(async (req, res) => {
	try {
		const path = new URL(req.url ?? "/", origin).pathname;
		res.setHeader("X-Content-Type-Options", "nosniff");
		res.setHeader("Referrer-Policy", "no-referrer");
		if (!allowedOrigin(req))
			return reply(res, 403, { error: "Origin is not allowed" });
		if (path === "/health")
			return reply(res, ready ? 200 : 503, {
				ready,
				players: world.humanCount,
				bots: world.players.size - world.humanCount,
			});
		if (path === "/session" && req.method === "POST") {
			if (!ready) return reply(res, 503, { error: "The world is starting" });
			if (Date.now() - loginWindow > 60000) {
				logins = 0;
				loginWindow = Date.now();
			}
			if (++logins > 60)
				return reply(res, 429, {
					error: "Please wait a minute before trying again",
				});
			const input = await body(req);
			const provided = Buffer.from(
				typeof input?.code === "string" ? input.code : "",
			);
			const expected = Buffer.from(joinCode);
			if (
				provided.length !== expected.length ||
				!timingSafeEqual(provided, expected)
			)
				return reply(res, 403, { error: "That invite code is incorrect" });
			if (world.humanCount >= MAX_PLAYERS)
				return reply(res, 409, {
					error: "The world is full. Try again after someone leaves.",
				});
			return reply(res, 200, { token: token("player") });
		}
		if (path === "/auth/ticket" && req.method === "POST") {
			if (!ready) return reply(res, 503, { error: "The world is starting" });
			if (!req.headers.authorization)
				return reply(res, 401, { error: "Join the game first" });
			const upstream = httpRequest(
				{
					hostname: "127.0.0.1",
					port: databasePort,
					path,
					method: "POST",
					headers: { Authorization: req.headers.authorization },
				},
				(response) => {
					res.writeHead(response.statusCode ?? 502, {
						"Content-Type": "application/json",
						"Cache-Control": "no-store",
					});
					response.pipe(res);
				},
			);
			upstream.on("error", () => {
				if (!res.headersSent)
					reply(res, 502, { error: "Database unavailable" });
				else res.destroy();
			});
			upstream.setTimeout(10000, () => {
				upstream.destroy(new Error("Database timed out"));
			});
			upstream.end();
			return;
		}
		const asset = assets.get(path);
		if (!asset || req.method !== "GET")
			return reply(res, 404, { error: "Not found" });
		res.writeHead(200, {
			"Content-Type": asset.type,
			"Cache-Control": "no-cache",
		});
		res.end(asset.bytes);
	} catch (error) {
		if (!res.headersSent)
			reply(res, 400, {
				error: error instanceof Error ? error.message : "Invalid request",
			});
		else res.destroy();
	}
});

// Native streams forward the upgrade and apply TCP backpressure without parsing game messages.
front.on("upgrade", (req, socket, head) => {
	if (
		!ready ||
		!allowedOrigin(req) ||
		new URL(req.url ?? "/", origin).pathname !== "/ws"
	) {
		socket.end(
			"HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 0\r\n\r\n",
		);
		return;
	}
	const upstream = httpRequest({
		hostname: "127.0.0.1",
		port: databasePort,
		path: req.url,
		headers: { ...req.headers, host: `127.0.0.1:${databasePort}` },
	});
	upstream.on("upgrade", (response, stream, upstreamHead) => {
		const headers = response.rawHeaders.reduce(
			(all, value, i) => all + (i % 2 === 0 ? `${value}: ` : `${value}\r\n`),
			"",
		);
		socket.write(`HTTP/1.1 101 Switching Protocols\r\n${headers}\r\n`);
		if (head.length) stream.write(head);
		if (upstreamHead.length) socket.write(upstreamHead);
		socket.pipe(stream).pipe(socket);
		stream.on("error", () => socket.destroy());
		stream.on("close", () => socket.destroy());
		socket.on("close", () => stream.destroy());
	});
	upstream.on("response", (response) => {
		socket.end(
			`HTTP/1.1 ${response.statusCode ?? 502} Rejected\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`,
		);
		response.resume();
	});
	upstream.on("error", () => socket.destroy());
	socket.on("error", () => upstream.destroy());
	socket.on("close", () => upstream.destroy());
	upstream.end();
});
front.on("connection", (socket) => {
	connections.add(socket);
	socket.on("close", () => connections.delete(socket));
});
await new Promise<void>((resolve, reject) => {
	front.once("error", reject);
	front.listen(port, host, resolve);
});

await mkdir(dataDir, { recursive: true });
const runtime = await mkdtemp(join(tmpdir(), "pixel-conquest-"));
const configPath = join(runtime, "config.json");
await writeFile(
	configPath,
	JSON.stringify({
		server: { host: "127.0.0.1", port: databasePort },
		dataDir,
		schema: join(directory, "schema.json"),
		authorization: join(directory, "authorization.json"),
		authentication: {
			jwt: { secret, algorithm: "HS256" },
			session: { claims: { role: "role" } },
		},
		security: {
			allowedOrigins: [origin],
			allowLocalhost: true,
			maxConnections: 128,
			maxMessagesPerSecond: 500,
			maxMessageSize: 1048576,
		},
	}),
	{ mode: 0o600 },
);
const database = Bun.spawn(
	[
		process.env.GAME_SERVER_BIN ?? join(root, "zig-out/bin/zyncbase"),
		"--config",
		configPath,
	],
	// Keep terminal Ctrl+C in the game process; stop the database after its final commit.
	{ cwd: root, stdout: "inherit", stderr: "inherit", detached: true },
);
const client = createClient({
	url: `ws://127.0.0.1:${databasePort}/ws`,
	auth: { tokenProvider: async () => token("simulation") },
	storeNamespace: NAMESPACE,
	presenceNamespace: NAMESPACE,
	reconnect: false,
});

async function allRows(collection: string) {
	const rows: JsonValue[] = [];
	let after: string | undefined;
	do {
		const page = await client.store.query(collection, {
			limit: 200,
			...(after ? { after } : {}),
		});
		rows.push(...page);
		after = page.nextCursor ?? undefined;
	} while (after);
	return rows;
}

async function publish() {
	const chunks = [...world.dirtyChunks].map((index) => world.chunk(index));
	const countries = [...world.dirtyCountries]
		.map((code) => world.countries.get(code))
		.filter((c) => c !== undefined);
	world.dirtyChunks.clear();
	world.dirtyCountries.clear();
	const operations: BatchOperation[] = [
		...countries.map(({ id, ...value }) => ({
			op: "set" as const,
			path: ["countries", id],
			value,
		})),
		...chunks.map(({ id, ...value }) => ({
			op: "set" as const,
			path: ["chunks", id],
			value,
		})),
	];
	if (!operations.length) return;
	const started = performance.now();
	await client.store.batch(operations, { confirm: "committed" });
	commitMs = performance.now() - started;
	flushes++;
	chunkWrites += chunks.length;
	payloadBytes += chunks.reduce(
		(sum, chunk) => sum + chunk.owners.byteLength + chunk.dots.byteLength,
		0,
	);
}

let tick: ReturnType<typeof setInterval> | undefined;
let statistics: ReturnType<typeof setInterval> | undefined;
async function stop(code = 0) {
	if (stopping) return;
	stopping = true;
	ready = false;
	clearInterval(tick);
	clearInterval(statistics);
	front.close();
	for (const socket of connections) socket.destroy();
	try {
		if (code === 0) {
			await inFlight;
			for (const id of world.players.keys()) world.remove(id);
			await publish();
		}
	} catch (error) {
		console.error("Uncommitted updates were not saved:", error);
		code = 1;
	}
	client.disconnect();
	database.kill();
	const databaseExit = await database.exited;
	if (databaseExit !== 0) {
		console.error(`ZyncBase shutdown failed (${databaseExit})`);
		code = 1;
	}
	await rm(runtime, { recursive: true, force: true });
	process.exit(code);
}
function failed(error: unknown) {
	console.error("Game paused:", error);
	// Leave recovery to a restart: only committed territory is authoritative on disk.
	void stop(1);
}
process.on("SIGINT", () => void stop());
process.on("SIGTERM", () => void stop());
void database.exited.then((code) => {
	if (!stopping) failed(`ZyncBase exited (${code})`);
});

try {
	for (let attempt = 0; attempt < 120; attempt++) {
		try {
			await fetch(`http://127.0.0.1:${databasePort}/`, {
				signal: AbortSignal.timeout(500),
			});
			break;
		} catch {
			if (attempt === 119)
				throw new Error("ZyncBase did not start within 30 seconds");
			await Bun.sleep(250);
		}
	}
	await client.connect();
	const countries = (await allRows("countries")) as Country[];
	const chunks = (await allRows("chunks")) as ChunkRow[];
	if (process.argv.includes("--reset")) {
		const operations: BatchOperation[] = [
			...chunks.map((row) => ({
				op: "remove" as const,
				path: ["chunks", row.id],
			})),
			...countries.map((row) => ({
				op: "remove" as const,
				path: ["countries", row.id],
			})),
		];
		for (let i = 0; i < operations.length; i += 100)
			await client.store.batch(operations.slice(i, i + 100), {
				confirm: "committed",
			});
		console.log("World reset.");
	} else world.restore(countries, chunks);
	world.startBots(performance.now());
	// A restart can need more reconciliation than one normal movement batch.
	await publish();
	client.on("error", failed);
	client.on("disconnected", () => {
		if (!stopping) failed("Database disconnected");
	});
	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: both SDK snapshot and delta shapes reconcile the same player set.
	client.presence.subscribeChanges((batch) => {
		if (stopping) return;
		const now = performance.now();
		if (batch.type === "snapshot") {
			const connected = new Set(batch.users.map((user) => user.userId));
			for (const [id, player] of world.players)
				if (!player.bot && !connected.has(id)) world.remove(id);
			for (const user of batch.users) world.input(user.userId, user.data, now);
		} else {
			for (const change of batch.changes) {
				if (change.type === "leave") world.remove(change.userId);
				else world.input(change.entry.userId, change.entry.data, now);
			}
		}
	});
	ready = true;
	tick = setInterval(() => {
		if (inFlight || stopping) return;
		// ponytail: pause ticks during commit; decouple with a bounded queue if VPS measurements justify it.
		world.tick(performance.now());
		inFlight = publish()
			.catch(failed)
			.finally(() => {
				inFlight = null;
			});
	}, RULES.tickMs);
	statistics = setInterval(
		() =>
			console.log(
				JSON.stringify({
					players: world.humanCount,
					bots: world.players.size - world.humanCount,
					ticks: world.ticks,
					inputs: world.inputMessages,
					flushes,
					chunkWrites,
					chunkPayloadBytes: payloadBytes,
					lastCommitMs: Math.round(commitMs),
				}),
			),
		10000,
	);
	console.log(
		`\nPixel Conquest: ${origin}\nInvite code: ${joinCode}\nData: ${dataDir}\nStop with Ctrl+C.\n`,
	);
} catch (error) {
	failed(error);
}
