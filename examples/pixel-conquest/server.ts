import { createHmac, randomBytes, randomUUID } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import {
	createServer,
	type IncomingMessage,
	type ServerResponse,
} from "node:http";
import { createServer as createSecureServer } from "node:https";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import type { Duplex } from "node:stream";
import {
	type BatchOperation,
	createClient,
	type JsonValue,
} from "@zyncbase/client";
import {
	buildPublishOperations,
	drainPublishState,
	type PublishSnapshot,
	restorePublishState,
	runPublishBatches,
} from "./publish";
import {
	type ChunkRow,
	type Country,
	INPUT_LEASE_MS,
	MAX_PLAYERS,
	NAMESPACE,
	RULES,
	terrain,
	type UserRow,
} from "./shared";
import { World } from "./world";

const directory = import.meta.dir;
const root = resolve(directory, "../..");
const port = Number(process.env.GAME_PORT ?? 8081);
const databasePort = Number(process.env.GAME_DB_PORT ?? 3001);
const host = process.env.GAME_HOST ?? "127.0.0.1";
const origin = process.env.GAME_ORIGIN ?? "http://localhost:8080";
const dataDir = resolve(
	process.env.GAME_DATA_DIR ?? join(root, "data/pixel-conquest"),
);
const secret = randomBytes(32).toString("hex");
const certFile = process.env.GAME_TLS_CERT;
const keyFile = process.env.GAME_TLS_KEY;
if (Boolean(certFile) !== Boolean(keyFile))
	throw new Error("Set both GAME_TLS_CERT and GAME_TLS_KEY to enable TLS");
const tlsConfig =
	certFile && keyFile
		? { certFile: resolve(certFile), keyFile: resolve(keyFile) }
		: undefined;
const tls = tlsConfig
	? {
			cert: await readFile(tlsConfig.certFile),
			key: await readFile(tlsConfig.keyFile),
		}
	: undefined;
const databaseUrl = new URL("/ws", origin);
databaseUrl.protocol = tls ? "wss:" : "ws:";
if (!tls) databaseUrl.hostname = "127.0.0.1";
databaseUrl.port = String(databasePort);
const world = new World(terrain());
let ready = false;
let stopping = false;
let inFlight: Promise<void> | null = null;
let flushes = 0,
	chunkWrites = 0,
	payloadBytes = 0,
	commitMs = 0;
let lastPublishedMark = 1;
let tickCount = 0;
// Scoreboard and roster rows dirty on nearly every tick under a crowd, but no
// reader needs them at 20 Hz: flushing them at 2 Hz cuts their global fan-out
// ~10x while chunks (movement) stay per-tick. Worst-case staleness is half a
// second, inside the lobby poll (5 s) and grace (10 s) windows. Shorter than
// 1 Hz keeps each accumulated flush to ~1 batch so the flush tick itself does
// not become a periodic latency spike.
const ROSTER_PUBLISH_EVERY_TICKS = 10;
// Country rows whose write has landed. A held-back new country would let a
// chunk commit owners for a row that does not exist yet, and restart restore
// refuses unknown owner codes; creating a country therefore forces a roster
// flush. Existing count updates stay throttled.
const persistedCountries = new Set<number>();
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
	return size ? JSON.parse(Buffer.concat(chunks).toString()) : {};
}

// ponytail: shared session budget; add per-client quotas if one caller starves others.
let logins = 0,
	loginWindow = Date.now();
// The public demo admits 120 sessions/minute. A load profile that needs a
// 1024-client ramp can raise the budget instead of pacing for ten minutes.
const sessionBudget = Number(process.env.GAME_SESSION_BUDGET || 120);
// A malformed value would turn the guard below into a NaN comparison that
// never trips, silently removing the admission limit. Fail startup instead.
if (!Number.isSafeInteger(sessionBudget) || sessionBudget < 0)
	throw new Error("GAME_SESSION_BUDGET must be a non-negative integer");
// Latest reservation generation per country code; stale timers no-op.
const countryLeases = new Map<number, number>();
// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: login validation stays together with its rate limit and responses.
const handleRequest = async (req: IncomingMessage, res: ServerResponse) => {
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
				countries: [...world.countries.values()],
			});
		if (path === "/session" && req.method === "POST") {
			if (!ready) return reply(res, 503, { error: "The world is starting" });
			if (Date.now() - loginWindow > 60000) {
				logins = 0;
				loginWindow = Date.now();
			}
			if (++logins > sessionBudget)
				return reply(res, 429, {
					error: "Please wait a minute before trying again",
				});
			const input = await body(req);
			if (!input || typeof input !== "object" || Array.isArray(input))
				throw new Error("Expected a session request object");
			if (!ready) return reply(res, 503, { error: "The world is starting" });
			if (world.humanCount >= MAX_PLAYERS)
				return reply(res, 409, {
					error: "The world is full. Try again after someone leaves.",
				});
			let country: Country | undefined;
			if (Object.hasOwn(input, "countryName")) {
				country = world.country(input.countryName);
				if (!country)
					return reply(res, 409, {
						error: "All country slots are taken. Join an existing country.",
					});
				if (country.is_bot)
					return reply(res, 409, {
						error: "That country is reserved for bots.",
					});
				// Release an unused slot if the browser never completes admission.
				const code = country.code;
				const lease = (countryLeases.get(code) ?? 0) + 1;
				countryLeases.set(code, lease);
				setTimeout(() => {
					if (countryLeases.get(code) !== lease) return;
					countryLeases.delete(code);
					world.maybeDeleteCountry(code);
				}, INPUT_LEASE_MS * 5).unref();
			}
			return reply(res, 200, {
				token: token("player"),
				countryCode: country?.code,
			});
		}
		return reply(res, 404, { error: "Not found" });
	} catch (error) {
		if (!res.headersSent)
			reply(res, 400, {
				error: error instanceof Error ? error.message : "Invalid request",
			});
		else res.destroy();
	}
};
const front = tls
	? createSecureServer(tls, handleRequest)
	: createServer(handleRequest);
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
		server: {
			host,
			port: databasePort,
			...(tlsConfig ? { tls: tlsConfig } : {}),
		},
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
			maxConnections: 2048,
			maxMessagesPerSecond: 2000,
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
	url: databaseUrl.toString(),
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

// The allocator mark rides in the first batch with the country removes so
// a retired code and its tombstone commit atomically: crash before batch 1
// retries everything, crash after keeps the mark past every retired code.
function allocatorOp(): BatchOperation[] {
	if (world.allocatorMark === lastPublishedMark) return [];
	return [
		{
			op: "set" as const,
			path: ["meta", "allocator"],
			value: { nextCode: world.allocatorMark },
		},
	];
}

/** Roster rows are throttled; a brand-new country forces a flush so its chunk
 * writes never reference a row that has not landed yet. */
function shouldPublishRosters(force: boolean) {
	if (force || tickCount % ROSTER_PUBLISH_EVERY_TICKS === 0) return true;
	for (const code of world.dirtyCountries)
		if (!persistedCountries.has(code)) return true;
	return false;
}

/** Roster rows whose write has landed; also advances the allocator mark. */
function recordRosterCommit(snapshot: PublishSnapshot) {
	for (const code of snapshot.countries) persistedCountries.add(code);
	for (const code of snapshot.removed) persistedCountries.delete(code);
	lastPublishedMark = world.allocatorMark;
}

async function publish(forceRosters = false) {
	tickCount++;
	const rosters = shouldPublishRosters(forceRosters);
	const snapshot = drainPublishState(world, { rosters });
	const operations = buildPublishOperations(
		world,
		snapshot,
		rosters ? allocatorOp() : [],
	);
	if (!operations.length) return;
	// A rejected batch restores every drained entry, so a retry resends all
	// uncommitted operations instead of silently dropping them.
	const started = performance.now();
	try {
		await runPublishBatches(
			(batch) => client.store.batch(batch, { confirm: "committed" }),
			operations,
		);
	} catch (error) {
		restorePublishState(world, snapshot);
		throw error;
	}
	// The allocator mark rides with the country removes (see allocatorOp), so
	// it only advances on roster flushes.
	if (rosters) recordRosterCommit(snapshot);
	commitMs = performance.now() - started;
	flushes++;
	for (const op of operations) {
		if (op.op !== "set" || op.path[0] !== "chunks") continue;
		const value = op.value as unknown as {
			owners: Uint8Array;
			dots: Uint8Array;
		};
		chunkWrites++;
		payloadBytes += value.owners.byteLength + value.dots.byteLength;
	}
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
			for (const id of world.players.keys())
				world.remove(id, performance.now());
			// Final save must flush held-back roster rows too.
			await publish(true);
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
			await fetch(`${tls ? "https:" : "http:"}//${databaseUrl.host}/`, {
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
	const users = (await allRows("users")) as UserRow[];
	const meta = (await allRows("meta")) as { id: string; nextCode: number }[];
	if (process.argv.includes("--reset")) {
		const operations: BatchOperation[] = [
			...chunks.map((row) => ({
				op: "remove" as const,
				path: ["chunks", row.id],
			})),
			...users.map((row) => ({
				op: "remove" as const,
				path: ["users", row.id],
			})),
			...countries.map((row) => ({
				op: "remove" as const,
				path: ["countries", row.id],
			})),
			...meta.map((row) => ({
				op: "remove" as const,
				path: ["meta", row.id],
			})),
		];
		for (let i = 0; i < operations.length; i += 100)
			await client.store.batch(operations.slice(i, i + 100), {
				confirm: "committed",
			});
		console.log("World reset.");
	} else world.restore(countries, chunks, users, meta[0]?.nextCode ?? 0);
	// Rows surviving the restart are already committed; only later creations
	// need the force-flush above.
	for (const code of world.countries.keys()) persistedCountries.add(code);
	world.startBots(performance.now());
	// A restart can need more reconciliation than one normal movement batch.
	// Force the roster flush: startup reconciliation must be complete, not throttled.
	await publish(true);
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
				if (!player.is_bot && !connected.has(id)) world.remove(id, now);
			for (const user of batch.users) world.input(user.userId, user.data, now);
		} else {
			for (const change of batch.changes) {
				if (change.type === "leave") world.remove(change.userId, now);
				else world.input(change.entry.userId, change.entry.data, now);
			}
		}
	});
	ready = true;
	tick = setInterval(() => {
		if (inFlight || stopping) return;
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
		`\nPixel Conquest: ${origin}\nData: ${dataDir}\nStop with Ctrl+C.\n`,
	);
} catch (error) {
	failed(error);
}
