import { createHmac, randomBytes } from "node:crypto";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import {
	createServer,
	type IncomingMessage,
	type ServerResponse,
} from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { startWorker, type WorkerHandle } from "./worker";

const DEFAULT_PORT = 8081;
const DEFAULT_DATABASE_PORT = 3001;
const DEFAULT_ORIGIN = "http://localhost:8080";
const ROOT = resolve(import.meta.dir, "../..");

export interface QuorumServerOptions {
	port?: number;
	databasePort?: number;
	host?: string;
	origin?: string;
	dataDir?: string;
	serverBin?: string;
	quiet?: boolean;
}

export interface QuorumServerHandle {
	port: number;
	databasePort: number;
	stop: () => Promise<void>;
}

function reply(res: ServerResponse, status: number, body: unknown) {
	res.writeHead(status, {
		"Content-Type": "application/json",
		"Cache-Control": "no-store",
	});
	res.end(JSON.stringify(body));
}

async function readJson(
	req: IncomingMessage,
): Promise<Record<string, unknown>> {
	const chunks: Buffer[] = [];
	let size = 0;
	for await (const chunk of req) {
		size += chunk.length;
		if (size > 2048) throw new Error("Request too large");
		chunks.push(Buffer.from(chunk));
	}
	if (size === 0) return {};
	const value: unknown = JSON.parse(Buffer.concat(chunks).toString());
	if (!value || typeof value !== "object" || Array.isArray(value)) {
		throw new Error("Expected a JSON object");
	}
	return value as Record<string, unknown>;
}

function validSubject(value: unknown): value is string {
	return (
		typeof value === "string" &&
		value.length >= 8 &&
		value.length <= 64 &&
		/^[a-zA-Z0-9:_-]+$/.test(value)
	);
}

function validRoom(value: unknown): value is string {
	return (
		typeof value === "string" &&
		value.length >= 6 &&
		value.length <= 12 &&
		/^[a-z0-9]+$/.test(value)
	);
}

export async function startQuorumServer(
	options: QuorumServerOptions = {},
): Promise<QuorumServerHandle> {
	const port = options.port ?? DEFAULT_PORT;
	const databasePort = options.databasePort ?? DEFAULT_DATABASE_PORT;
	const host = options.host ?? "127.0.0.1";
	const origin = options.origin ?? DEFAULT_ORIGIN;
	const dataDir = resolve(options.dataDir ?? join(ROOT, "data/quorum"));
	const serverBin =
		options.serverBin ??
		process.env.QUORUM_SERVER_BIN ??
		join(ROOT, "zig-out/bin/zyncbase");
	const secret = randomBytes(32).toString("hex");
	const schemaPath = join(import.meta.dir, "schema.json");
	const authorizationPath = join(import.meta.dir, "authorization.json");
	const quiet = options.quiet === true;

	const nowSeconds = () => Math.floor(Date.now() / 1000);
	const encode = (value: unknown) =>
		Buffer.from(JSON.stringify(value)).toString("base64url");
	function token(role: "member" | "service", room: string, sub: string) {
		const issued = nowSeconds();
		const payload = `${encode({ alg: "HS256", typ: "JWT" })}.${encode({
			sub,
			role,
			room,
			iat: issued,
			exp: issued + 86_400,
		})}`;
		return `${payload}.${createHmac("sha256", secret).update(payload).digest("base64url")}`;
	}

	await mkdir(dataDir, { recursive: true });
	const runtime = await mkdtemp(join(tmpdir(), "quorum-"));
	const configPath = join(runtime, "config.json");
	await writeFile(
		configPath,
		JSON.stringify({
			server: { host, port: databasePort, idleTimeoutSeconds: 10 },
			dataDir,
			schema: schemaPath,
			authorization: authorizationPath,
			authentication: {
				jwt: { secret, algorithm: "HS256" },
				session: {
					claims: { role: "role", room: "room", sub: "external" },
				},
			},
			security: {
				allowedOrigins: [origin],
				allowLocalhost: true,
				maxConnections: 2048,
				maxMessagesPerSecond: 2000,
				maxMessageSize: 1_048_576,
			},
		}),
		{ mode: 0o600 },
	);

	const database = Bun.spawn([serverBin, "--config", configPath], {
		cwd: ROOT,
		stdout: quiet ? "ignore" : "inherit",
		stderr: quiet ? "ignore" : "inherit",
		detached: true,
	});

	const databaseUrl = `ws://127.0.0.1:${databasePort}/ws`;
	const workers = new Map<string, Promise<WorkerHandle>>();
	async function ensureRoomWorker(code: string): Promise<WorkerHandle> {
		const existing = workers.get(code);
		if (existing) return existing;
		if (workers.size >= 100) {
			throw new Error("Too many active rooms on this server");
		}
		const started = startWorker({
			code,
			url: databaseUrl,
			tokenProvider: async () => token("service", code, `service:${code}`),
		});
		workers.set(code, started);
		try {
			return await started;
		} catch (error) {
			workers.delete(code);
			throw error;
		}
	}

	let ready = true;
	let logins = 0;
	let loginWindow = Date.now();
	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: request routing and session minting stay in one place.
	const server = createServer(async (req, res) => {
		try {
			const path = new URL(req.url ?? "/", origin).pathname;
			res.setHeader("X-Content-Type-Options", "nosniff");
			res.setHeader("Referrer-Policy", "no-referrer");
			if (req.headers.origin && req.headers.origin !== origin) {
				return reply(res, 403, { error: "Origin is not allowed" });
			}
			if (path === "/health") {
				return reply(res, ready ? 200 : 503, {
					ready,
					rooms: workers.size,
					now: Date.now(),
				});
			}
			if (path === "/session" && req.method === "POST") {
				if (!ready) return reply(res, 503, { error: "Quorum is starting" });
				if (Date.now() - loginWindow > 60_000) {
					logins = 0;
					loginWindow = Date.now();
				}
				if (++logins > 240) {
					return reply(res, 429, { error: "Please wait a minute" });
				}
				const input = await readJson(req);
				if (!validRoom(input.room)) {
					return reply(res, 400, { error: "Invalid room code" });
				}
				if (!validSubject(input.subject)) {
					return reply(res, 400, { error: "Invalid subject" });
				}
				try {
					await ensureRoomWorker(input.room);
				} catch {
					return reply(res, 503, { error: "That room could not be started" });
				}
				return reply(res, 200, {
					token: token("member", input.room, `u:${input.subject}`),
					room: input.room,
				});
			}
			return reply(res, 404, { error: "Not found" });
		} catch (error) {
			if (!res.headersSent) {
				reply(res, 400, {
					error: error instanceof Error ? error.message : "Invalid request",
				});
			} else {
				res.destroy();
			}
		}
	});

	await new Promise<void>((resolveListen, reject) => {
		server.once("error", reject);
		server.listen(port, host, resolveListen);
	});

	let stopped = false;
	const stop = async () => {
		if (stopped) return;
		stopped = true;
		ready = false;
		server.closeAllConnections();
		await new Promise<void>((resolveClose) =>
			server.close(() => resolveClose()),
		);
		const handles = await Promise.allSettled([...workers.values()]);
		await Promise.allSettled(
			handles.map((entry) =>
				entry.status === "fulfilled" ? entry.value.stop() : Promise.resolve(),
			),
		);
		database.kill("SIGINT");
		await database.exited.catch(() => {});
	};

	return { port, databasePort, stop };
}

if (import.meta.main) {
	const handle = await startQuorumServer({
		port: Number(process.env.QUORUM_PORT ?? DEFAULT_PORT),
		databasePort: Number(process.env.QUORUM_DB_PORT ?? DEFAULT_DATABASE_PORT),
		host: process.env.QUORUM_HOST ?? "127.0.0.1",
		origin: process.env.QUORUM_ORIGIN ?? DEFAULT_ORIGIN,
		dataDir: process.env.QUORUM_DATA_DIR,
		serverBin: process.env.QUORUM_SERVER_BIN,
	});
	console.log(
		`Quorum app server on :${handle.port} (database :${handle.databasePort})`,
	);
	const shutdown = () => {
		void handle.stop().then(() => process.exit(0));
	};
	process.on("SIGINT", shutdown);
	process.on("SIGTERM", shutdown);
}
