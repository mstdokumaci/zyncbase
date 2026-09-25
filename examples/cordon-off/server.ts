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
	ActionError,
	type BatchOperation,
	createClient,
	type JsonValue,
} from "@zyncbase/client";
import { deployIfChanged, publishAssets } from "./deploy";
import {
	archiveRound,
	maxHistoryNumber,
	type RoundResult,
	type RoundStanding,
	readRoundCursor,
	writeRoundCursor,
} from "./history";
import {
	buildPublishOperations,
	drainPublishState,
	type PublishSnapshot,
	restorePublishState,
	runPublishBatches,
} from "./publish";
import {
	type Country,
	type CountryChunkRow,
	HEIGHT,
	MAX_PLAYERS,
	NAMESPACE,
	nextRoundBoundary,
	PLAYER_GRACE_MS,
	type PlayerRow,
	type RoundCursor,
	RULES,
	rowId,
	terrain,
	type UserChunkRow,
	WIDTH,
} from "./shared";
import { reservedBotCountry, World } from "./world";

const directory = import.meta.dir;
const root = resolve(directory, "../..");
const port = Number(process.env.GAME_PORT ?? 8081);
const databasePort = Number(process.env.GAME_DB_PORT ?? 3001);
const host = process.env.GAME_HOST ?? "127.0.0.1";
const origin = process.env.GAME_ORIGIN ?? "http://localhost:8080";
const dataDir = resolve(
	process.env.GAME_DATA_DIR ?? join(root, "data/cordon-off"),
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
// Rounds end on absolute multiples of this period; 1 h lands on the hour.
const roundMs = Number(process.env.GAME_ROUND_MS ?? 3_600_000);
if (!Number.isSafeInteger(roundMs) || roundMs <= 0)
	throw new Error("GAME_ROUND_MS must be a positive integer");
// A quiet world resets early so the next visitor starts fresh; 0 disables.
const idleWipeMs = Number(process.env.GAME_IDLE_WIPE_MS ?? 600_000);
if (!Number.isSafeInteger(idleWipeMs) || idleWipeMs < 0)
	throw new Error("GAME_IDLE_WIPE_MS must be a non-negative integer");
// History is generated into the assets directory so the Worker deploy ships it.
const assetsDir = resolve(
	process.env.GAME_ASSETS_DIR ?? join(directory, "dist"),
);
const historyDir = join(assetsDir, "history");
const cloudflareAccountId = process.env.CLOUDFLARE_ACCOUNT_ID;
const cloudflareApiToken = process.env.CLOUDFLARE_API_TOKEN;
const deployEnabled =
	process.env.GAME_DEPLOY !== "0" &&
	Boolean(cloudflareApiToken) &&
	Boolean(cloudflareAccountId);
let world = new World(terrain());
let round: RoundCursor = {
	number: 1,
	startedAt: 0,
	endsAt: 0,
	fresh: true,
};
let ending = false;
let roundActive = false;
let emptySince = 0;
let deployTimer: ReturnType<typeof setTimeout> | undefined;
let ready = false;
let stopping = false;
let inFlight: Promise<void> | null = null;
let flushes = 0,
	countryChunkWrites = 0,
	countryChunkBytes = 0,
	userChunkWrites = 0,
	userChunkBytes = 0,
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

function token(role: "player" | "simulation", sub = `${role}:${randomUUID()}`) {
	const now = Math.floor(Date.now() / 1000);
	const encode = (value: unknown) =>
		Buffer.from(JSON.stringify(value)).toString("base64url");
	const payload = `${encode({ alg: "HS256", typ: "JWT" })}.${encode({ sub, role, iat: now, exp: now + 86400 })}`;
	return `${payload}.${createHmac("sha256", secret).update(payload).digest("base64url")}`;
}

function allowedOrigin(req: IncomingMessage) {
	return !req.headers.origin || req.headers.origin === origin;
}

function roundInfo() {
	return {
		number: round.number,
		startedAt: round.startedAt,
		endsAt: round.endsAt,
	};
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
// An unused country reservation expires if the browser never joins. Tests
// shorten it so the cleanup path does not sit on the production grace window.
const countryLeaseMs = Number(
	process.env.GAME_COUNTRY_LEASE_MS ?? PLAYER_GRACE_MS,
);
if (!Number.isSafeInteger(countryLeaseMs) || countryLeaseMs < 0)
	throw new Error("GAME_COUNTRY_LEASE_MS must be a non-negative integer");
// A session slot outlives its player by the tombstone window so a reconnect
// inside the resume window can re-join in place. Tests shorten it.
const sessionLeaseMs = Number(
	process.env.GAME_SESSION_LEASE_MS ?? PLAYER_GRACE_MS * 2,
);
if (!Number.isSafeInteger(sessionLeaseMs) || sessionLeaseMs < 0)
	throw new Error("GAME_SESSION_LEASE_MS must be a non-negative integer");
// Latest reservation generation per country id; stale timers no-op.
const countryLeases = new Map<number, number>();
// Per-network player cap. 0 disables it. Active slots renew on input and expire
// one resume window after the last heartbeat: a fairness guard, not security.
const playersPerIp = Number(process.env.GAME_PLAYERS_PER_IP ?? 5);
if (!Number.isSafeInteger(playersPerIp) || playersPerIp < 0)
	throw new Error("GAME_PLAYERS_PER_IP must be a non-negative integer");
const ipSessions = new Map<string, Set<string>>();
type SessionLease = {
	key: string;
	userId?: string;
	name?: string;
	countryId?: number;
	expiresAt: number;
};
const sessionLeases = new Map<string, SessionLease>();
const playerSessions = new Map<string, string>();

/** Network key: IPv4 exact, IPv6 grouped by /64 so rotating interface ids
 * share one pool. Cloudflare sets cf-connecting-ip and strips client copies. */
function clientKey(req: IncomingMessage) {
	const header =
		req.headers["cf-connecting-ip"] ?? req.headers["x-forwarded-for"];
	const raw =
		(Array.isArray(header) ? header[0] : header)?.split(",")[0]?.trim() ||
		req.socket.remoteAddress ||
		"unknown";
	const ip = raw.toLowerCase().replace(/^::ffff:/, "");
	if (!ip.includes(":")) return ip;
	const [head, tail = ""] = ip.split("::");
	const h = head ? head.split(":") : [];
	const t = tail ? tail.split(":").filter(Boolean) : [];
	const full = [
		...h,
		...Array(Math.max(0, 8 - h.length - t.length)).fill("0"),
		...t,
	];
	return `${full
		.slice(0, 4)
		.map((part) => Number.parseInt(part, 16).toString(16))
		.join(":")}::/64`;
}

/** Renew by writing a deadline: no per-move timer allocation, just a sweep. */
function renewSession(sessionId: string) {
	const lease = sessionLeases.get(sessionId);
	if (!lease) return false;
	lease.expiresAt = performance.now() + sessionLeaseMs;
	return true;
}

function holdSession(key: string, sessionId: string) {
	let subs = ipSessions.get(key);
	if (!subs) {
		subs = new Set();
		ipSessions.set(key, subs);
	}
	subs.add(sessionId);
	sessionLeases.set(sessionId, { key, expiresAt: 0 });
	renewSession(sessionId);
}

function releaseSession(sessionId: string) {
	const lease = sessionLeases.get(sessionId);
	if (!lease) return;
	if (lease.userId && playerSessions.get(lease.userId) === sessionId)
		playerSessions.delete(lease.userId);
	sessionLeases.delete(sessionId);
	const subs = ipSessions.get(lease.key);
	subs?.delete(sessionId);
	if (!subs?.size) ipSessions.delete(lease.key);
}

/** Release every session past its deadline. Runs from the game tick, before
 * the commit-pending guard, so expiry never waits on storage. */
function sweepSessions(now: number) {
	for (const [sessionId, lease] of sessionLeases)
		if (lease.expiresAt <= now) releaseSession(sessionId);
}

/** `world.join` throws only when no land is available; callers treat that as a
 * rejection instead of a game-stopping error. */
function tryJoin(
	id: string,
	data: Record<string, unknown>,
	now: number,
): ReturnType<World["join"]> {
	try {
		return world.join(id, data, now);
	} catch {
		return undefined;
	}
}

/** Re-admit a player whose world entity aged out while the session survived,
 * using the identity the session stored at join. */
function readmitPlayer(userId: string, lease: SessionLease): boolean {
	if (lease.name === undefined || lease.countryId === undefined) return false;
	return (
		tryJoin(
			userId,
			{ name: lease.name, country_id: lease.countryId },
			performance.now(),
		) !== undefined
	);
}
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
				round: roundInfo(),
				now: Date.now(),
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
			const key = clientKey(req);
			if (playersPerIp && (ipSessions.get(key)?.size ?? 0) >= playersPerIp)
				return reply(res, 429, {
					error: `Only ${playersPerIp} players can join from one network.`,
				});
			roundActive = true;
			let country: Country | undefined;
			if (Object.hasOwn(input, "countryName")) {
				// Bot countries are created lazily, so the name check must run
				// before creation, not just against existing rows.
				if (reservedBotCountry(input.countryName))
					return reply(res, 409, {
						error: "That country is reserved for bots.",
					});
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
				const countryId = country.country_id;
				const lease = (countryLeases.get(countryId) ?? 0) + 1;
				countryLeases.set(countryId, lease);
				setTimeout(() => {
					if (countryLeases.get(countryId) !== lease) return;
					countryLeases.delete(countryId);
					world.maybeDeleteCountry(countryId);
				}, countryLeaseMs).unref();
			}
			// Held only on success: rejected country requests must not burn a slot.
			const sub = `player:${randomUUID()}`;
			const sessionId = randomUUID();
			holdSession(key, sessionId);
			return reply(res, 200, {
				token: token("player", sub),
				session_id: sessionId,
				country_id: country?.country_id,
				round: roundInfo(),
				now: Date.now(),
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
const runtime = await mkdtemp(join(tmpdir(), "cordon-off-"));
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
			// 500-op slices of 1 KB owner rows plus bounded dots/roster rows
			// stay under ~1 MB; keep headroom for the SDK's msgpack framing.
			maxMessageSize: 4194304,
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
// a retired id and its tombstone commit atomically: crash before batch 1
// retries everything, crash after keeps the mark past every retired id.
function allocatorOp(): BatchOperation[] {
	if (world.allocatorMark === lastPublishedMark) return [];
	return [
		{
			op: "set" as const,
			path: ["meta", "allocator"],
			value: { next_country_id: world.allocatorMark },
		},
	];
}

/** Roster rows are throttled; a brand-new country forces a flush so its chunk
 * writes never reference a row that has not landed yet. */
function shouldPublishRosters(force: boolean) {
	if (force || tickCount % ROSTER_PUBLISH_EVERY_TICKS === 0) return true;
	for (const countryId of world.dirtyCountries)
		if (!persistedCountries.has(countryId)) return true;
	return false;
}

/** Roster rows whose write has landed; also advances the allocator mark. */
function recordRosterCommit(snapshot: PublishSnapshot) {
	for (const countryId of snapshot.countries) persistedCountries.add(countryId);
	for (const countryId of snapshot.removed)
		persistedCountries.delete(countryId);
	lastPublishedMark = world.allocatorMark;
}

/** Split-tables metrics: one counter pair per chunk grid. */
function recordChunkWrites(operations: BatchOperation[]) {
	for (const op of operations) {
		if (op.op !== "set") continue;
		if (op.path[0] === "country_chunks") {
			const value = op.value as unknown as { color_indexes: Uint8Array };
			countryChunkWrites++;
			countryChunkBytes += value.color_indexes.byteLength;
		} else if (op.path[0] === "user_chunks") {
			const value = op.value as unknown as { coordinates: Uint8Array };
			userChunkWrites++;
			userChunkBytes += value.coordinates.byteLength;
		}
	}
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
	recordChunkWrites(operations);
}

let tick: ReturnType<typeof setInterval> | undefined;
let statistics: ReturnType<typeof setInterval> | undefined;

function totalClaimed() {
	let total = 0;
	for (const country of world.countries.values()) total += country.count;
	return total;
}

function standings(): RoundStanding[] {
	return [...world.countries.values()]
		.filter((country) => country.count > 0)
		.map(({ name, color, count, is_bot }) => ({
			name,
			color,
			count,
			isBot: is_bot,
		}))
		.sort((a, b) => b.count - a.count);
}

async function archiveWorld(
	number: number,
	startedAt: number | null,
	endedAt: number,
) {
	const countries = standings();
	const humans = world.humanCount;
	const result: RoundResult = {
		number,
		startedAt,
		endedAt,
		humans,
		bots: world.players.size - humans,
		winner: countries[0] ?? null,
		countries,
	};
	const colors = new Map(
		[...world.countries].map(([countryId, country]) => [
			countryId,
			country.color,
		]),
	);
	await archiveRound(
		historyDir,
		result,
		world.owners,
		world.land,
		colors,
		WIDTH,
		HEIGHT,
	);
	console.log(
		`Round ${number} archived: ${countries.length} countries, ${humans} humans.`,
	);
}

async function wipeWorldRows(
	countries: Country[],
	countryChunks: CountryChunkRow[],
	playerRows: PlayerRow[],
	meta: { id: string }[],
) {
	const operations: BatchOperation[] = [
		...countryChunks.map((row) => ({
			op: "remove" as const,
			path: ["country_chunks", row.id],
		})),
		...playerRows.map((row) => ({
			op: "remove" as const,
			path: ["users", row.id],
		})),
		...countries.map((row) => ({
			op: "remove" as const,
			path: ["countries", rowId(row.country_id)],
		})),
		...meta.map((row) => ({ op: "remove" as const, path: ["meta", row.id] })),
	];
	if (!operations.length) return;
	await runPublishBatches(
		(batch) => client.store.batch(batch, { confirm: "committed" }),
		operations,
	);
}

function startRound(number: number) {
	const now = Date.now();
	round = { number, startedAt: now, endsAt: nextRoundBoundary(now, roundMs) };
	return writeRoundCursor(dataDir, round);
}

/** Archive when a scheduled round produced a claimed map, then exit; boot wipes. */
async function endRound(now: number, reason: "boundary" | "idle") {
	if (reason === "boundary" && totalClaimed() > 0) {
		await archiveWorld(round.number, round.startedAt, round.endsAt);
		round = {
			number: round.number + 1,
			startedAt: now,
			endsAt: nextRoundBoundary(now, roundMs),
			fresh: true,
		};
	} else {
		round = {
			number: round.number,
			startedAt: now,
			endsAt: nextRoundBoundary(now, roundMs),
			fresh: true,
		};
	}
	await writeRoundCursor(dataDir, round);
	console.log(
		reason === "boundary"
			? "Round ended; restarting."
			: "Idle reset; restarting.",
	);
	void stop(0);
}

/** Hash-gated Worker publish; failures retry a few times and never stop the game. */
async function runDeploy(attempt: number) {
	if (!cloudflareAccountId || !cloudflareApiToken) return;
	try {
		const result = await deployIfChanged({
			assetsDir,
			stateDir: dataDir,
			publish: (dir) =>
				publishAssets(dir, {
					accountId: cloudflareAccountId,
					apiToken: cloudflareApiToken,
					configPath: join(directory, "wrangler.jsonc"),
					log: (message) => console.log(message),
				}),
			log: (message) => console.log(message),
		});
		if (result === "deployed") console.log("Cloudflare assets deployed.");
		else if (result === "failed" && attempt < 6) scheduleDeploy(attempt + 1);
	} catch (error) {
		console.error("Deploy failed:", error);
		if (attempt < 6) scheduleDeploy(attempt + 1);
	}
}

function scheduleDeploy(attempt: number) {
	deployTimer = setTimeout(() => void runDeploy(attempt), 300_000);
	deployTimer.unref();
}
async function stop(code = 0) {
	if (stopping) return;
	stopping = true;
	ready = false;
	clearInterval(tick);
	clearInterval(statistics);
	clearTimeout(deployTimer);
	front.close();
	for (const socket of connections) socket.destroy();
	try {
		// A round end already archived the world; the next boot wipes it.
		if (code === 0 && !ending) {
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
	const countryChunks = (await allRows("country_chunks")) as CountryChunkRow[];
	const userChunks = (await allRows("user_chunks")) as UserChunkRow[];
	const playerRows = (await allRows("users")) as PlayerRow[];
	const meta = (await allRows("meta")) as {
		id: string;
		next_country_id: number;
	}[];
	// Coordinates are live state: rows from a previous process never survive.
	if (userChunks.length)
		await runPublishBatches(
			(batch) => client.store.batch(batch, { confirm: "committed" }),
			userChunks.map((row) => ({
				op: "remove" as const,
				path: ["user_chunks", row.id],
			})),
		);
	const savedRound = await readRoundCursor(dataDir);
	const maxHistory = await maxHistoryNumber(historyDir);
	const startup = Date.now();
	if (process.argv.includes("--reset")) {
		await wipeWorldRows(countries, countryChunks, playerRows, meta);
		await startRound(Math.max(maxHistory + 1, savedRound?.number ?? 0));
		console.log("World reset.");
	} else if (savedRound?.fresh) {
		await wipeWorldRows(countries, countryChunks, playerRows, meta);
		await startRound(Math.max(savedRound.number, maxHistory + 1));
	} else if (!savedRound || startup >= savedRound.endsAt) {
		// The round expired while the process was down: archive its final map.
		world.restore(
			countries,
			countryChunks,
			playerRows,
			meta[0]?.next_country_id ?? 0,
		);
		let number = Math.max(savedRound?.number ?? 0, maxHistory + 1);
		if (totalClaimed() > 0) {
			await archiveWorld(
				number,
				savedRound?.startedAt ?? null,
				savedRound?.endsAt ?? startup,
			);
			number += 1;
		}
		await wipeWorldRows(countries, countryChunks, playerRows, meta);
		world = new World(terrain());
		await startRound(number);
	} else {
		world.restore(
			countries,
			countryChunks,
			playerRows,
			meta[0]?.next_country_id ?? 0,
		);
		round = savedRound;
	}
	roundActive = totalClaimed() > 0;
	// Rows surviving the restart are already committed; only later creations
	// need the force-flush above.
	for (const countryId of world.countries.keys())
		persistedCountries.add(countryId);
	world.startBots(performance.now());
	// A restart can need more reconciliation than one normal movement batch.
	// Force the roster flush: startup reconciliation must be complete, not throttled.
	await publish(true);
	client.on("error", failed);
	client.on("disconnected", () => {
		if (!stopping) failed("Database disconnected");
	});
	client.actions.handle("player_join", (ctx, params) => {
		if (stopping || ending)
			throw new ActionError("JOIN_REJECTED", "The world is restarting");
		const sessionId = params.session_id;
		if (typeof sessionId !== "string")
			throw new ActionError("JOIN_REJECTED", "Session expired; please rejoin");
		const lease = sessionLeases.get(sessionId);
		if (!lease || (lease.userId && lease.userId !== ctx.userId))
			throw new ActionError("JOIN_REJECTED", "Session expired; please rejoin");
		const name = params.name;
		const countryId = params.country_id;
		if (typeof name !== "string" || typeof countryId !== "number")
			throw new ActionError("JOIN_REJECTED", "Invalid join request");
		const player = tryJoin(ctx.userId, params, performance.now());
		if (!player)
			throw new ActionError("JOIN_REJECTED", "Could not join this country");
		lease.userId = ctx.userId;
		lease.name = name;
		lease.countryId = countryId;
		playerSessions.set(ctx.userId, sessionId);
		renewSession(sessionId);
		return { user_id: ctx.userId };
	});
	client.actions.handle("player_move", (ctx, params) => {
		if (stopping || ending) return;
		const sessionId = playerSessions.get(ctx.userId);
		if (!sessionId) return;
		const lease = sessionLeases.get(sessionId);
		if (!lease) {
			playerSessions.delete(ctx.userId);
			return;
		}
		// A blip can outlive the world player but not the session: re-admit so a
		// still-connected tab resumes on its tombstone without a reconnect.
		if (!world.players.has(ctx.userId) && !readmitPlayer(ctx.userId, lease)) {
			releaseSession(sessionId);
			return;
		}
		if (!renewSession(sessionId)) return;
		world.input(ctx.userId, params, performance.now());
	});
	client.actions.handle("player_leave", (ctx) => {
		if (stopping || ending) return;
		const sessionId = playerSessions.get(ctx.userId);
		if (sessionId) releaseSession(sessionId);
		world.remove(ctx.userId, performance.now());
	});
	ready = true;
	if (deployEnabled) void runDeploy(0);
	tick = setInterval(() => {
		sweepSessions(performance.now());
		if (inFlight || stopping || ending) return;
		const now = Date.now();
		if (world.humanCount > 0) {
			roundActive = true;
			emptySince = 0;
		} else if (roundActive && !emptySince) {
			emptySince = now;
		}
		const reason =
			now >= round.endsAt
				? ("boundary" as const)
				: idleWipeMs > 0 && emptySince && now - emptySince >= idleWipeMs
					? ("idle" as const)
					: undefined;
		if (reason) {
			ending = true;
			ready = false;
			inFlight = endRound(now, reason)
				.catch(failed)
				.finally(() => {
					inFlight = null;
				});
			return;
		}
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
					round: round.number,
					ticks: world.ticks,
					inputs: world.inputMessages,
					flushes,
					countryChunkWrites,
					countryChunkBytes,
					userChunkWrites,
					userChunkBytes,
					lastCommitMs: Math.round(commitMs),
				}),
			),
		10000,
	);
	console.log(
		`\nCordon Off: ${origin}\nData: ${dataDir}\nAssets: ${assetsDir}\nStop with Ctrl+C.\n`,
	);
} catch (error) {
	failed(error);
}
