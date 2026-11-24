import { createHash, createHmac, randomBytes } from "node:crypto";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import {
	createServer,
	type IncomingMessage,
	type ServerResponse,
} from "node:http";
import { connect } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createClient } from "@zyncbase/client";
import { ZyncBaseYjsProvider } from "@zyncbase/client/yjs";
import { startYjsCompactor } from "@zyncbase/client/yjs/compactor";
import * as Y from "yjs";
import { writeWelcome } from "./seed";
import { type AppClient, collections, STORE_NAMESPACE } from "./shared";

const DEFAULT_PORT = 8081;
const DEFAULT_DATABASE_PORT = 3001;
const DEFAULT_ORIGIN = "http://localhost:8080";
const ROOT = resolve(import.meta.dir, "../..");
const WORKSPACE = "main";
const WELCOME_SLUG = "welcome";

export { collections };

export interface VersoServerOptions {
	port?: number;
	databasePort?: number;
	host?: string;
	origin?: string;
	dataDir?: string;
	serverBin?: string;
	quiet?: boolean;
	/** Compactor pass interval; tests shorten it. */
	compactorIntervalMs?: number;
}

export interface VersoServerHandle {
	port: number;
	databasePort: number;
	client: AppClient;
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

/**
 * Claimed identity: the same email always resolves to the same user id, so two
 * tabs with different emails are two users. No verification — see README.
 */
export function subjectForEmail(email: string): string {
	const hex = createHash("sha256").update(email).digest("hex");
	const variant = ((Number.parseInt(hex[16] ?? "8", 16) & 0x3) | 0x8).toString(
		16,
	);
	const id = `${hex.slice(0, 8)}-${hex.slice(8, 12)}-8${hex.slice(13, 16)}-${variant}${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
	return `u:${id}`;
}

export function normalizeEmail(value: string): string {
	return value.trim().toLowerCase();
}

async function waitForDatabase(port: number, deadline: number): Promise<void> {
	while (Date.now() < deadline) {
		const open = await new Promise<boolean>((resolveOpen) => {
			const socket = connect({ host: "127.0.0.1", port });
			socket.setTimeout(250);
			socket.once("connect", () => {
				socket.destroy();
				resolveOpen(true);
			});
			socket.once("error", () => resolveOpen(false));
			socket.once("timeout", () => {
				socket.destroy();
				resolveOpen(false);
			});
		});
		if (open) return;
		await Bun.sleep(100);
	}
	throw new Error("ZyncBase did not accept connections");
}

async function ensureWelcome(client: AppClient): Promise<void> {
	const existing = await client.store.query("pages", {
		where: { slug: WELCOME_SLUG },
		limit: 1,
	});
	if (existing.length > 0) return;
	let pageId: string;
	try {
		pageId = await client.store.create("pages", {
			slug: WELCOME_SLUG,
			title: "Welcome",
			icon: "🌱",
			position: 1000,
			compaction_version: 0,
		});
	} catch {
		// Another server instance claimed the slug first.
		return;
	}
	const doc = new Y.Doc();
	const provider = new ZyncBaseYjsProvider(client, pageId, doc, {
		collections,
		connect: false,
	});
	await provider.connect();
	doc.transact(() => writeWelcome(doc.getXmlFragment("default")));
	await provider.flush();
	provider.destroy();
}

export async function startVersoServer(
	options: VersoServerOptions = {},
): Promise<VersoServerHandle> {
	const port = options.port ?? DEFAULT_PORT;
	const databasePort = options.databasePort ?? DEFAULT_DATABASE_PORT;
	const host = options.host ?? "127.0.0.1";
	const origin = options.origin ?? DEFAULT_ORIGIN;
	const dataDir = resolve(options.dataDir ?? join(ROOT, "data/verso"));
	const serverBin =
		options.serverBin ??
		process.env.VERSO_SERVER_BIN ??
		join(ROOT, "zig-out/bin/zyncbase");
	const quiet = options.quiet === true;
	const secret = randomBytes(32).toString("hex");

	const nowSeconds = () => Math.floor(Date.now() / 1000);
	const encode = (value: unknown) =>
		Buffer.from(JSON.stringify(value)).toString("base64url");
	function token(sub: string) {
		const issued = nowSeconds();
		const payload = `${encode({ alg: "HS256", typ: "JWT" })}.${encode({
			sub,
			workspace: WORKSPACE,
			iat: issued,
			exp: issued + 86_400,
		})}`;
		return `${payload}.${createHmac("sha256", secret).update(payload).digest("base64url")}`;
	}

	await mkdir(dataDir, { recursive: true });
	const runtime = await mkdtemp(join(tmpdir(), "verso-"));
	const configPath = join(runtime, "config.json");
	await writeFile(
		configPath,
		JSON.stringify({
			server: { host, port: databasePort, idleTimeoutSeconds: 10 },
			dataDir,
			schema: join(import.meta.dir, "schema.json"),
			authorization: join(import.meta.dir, "authorization.json"),
			authentication: {
				jwt: { secret, algorithm: "HS256" },
				session: {
					claims: { sub: "external", workspace: "workspace" },
				},
			},
			security: {
				allowedOrigins: [origin],
				allowLocalhost: true,
				maxConnections: 256,
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

	const client = createClient({
		url: `ws://127.0.0.1:${databasePort}/ws`,
		auth: { token: token("service:compactor") },
		storeNamespace: STORE_NAMESPACE,
		presenceNamespace: STORE_NAMESPACE,
		reconnect: false,
		maxReconnectAttempts: 3,
	}) as AppClient;
	await waitForDatabase(databasePort, Date.now() + 30_000);
	await client.connect();
	await ensureWelcome(client);

	const compactor = startYjsCompactor(client, {
		collections,
		intervalMs: options.compactorIntervalMs ?? 20_000,
		updateRetentionMs: 7 * 24 * 60 * 60_000,
		snapshotRetentionMs: 60 * 60_000,
		onError: (error, context) => {
			if (!quiet) console.error("Verso compactor:", context.phase, error);
		},
	});

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
				return reply(res, 200, { ready: true, now: Date.now() });
			}
			if (path === "/session" && req.method === "POST") {
				if (Date.now() - loginWindow > 60_000) {
					logins = 0;
					loginWindow = Date.now();
				}
				if (++logins > 240) {
					return reply(res, 429, { error: "Please wait a minute" });
				}
				const input = await readJson(req);
				if (typeof input.email !== "string" || input.email.length > 200) {
					return reply(res, 400, { error: "Enter an email address" });
				}
				const email = normalizeEmail(input.email);
				if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
					return reply(res, 400, { error: "That is not an email address" });
				}
				return reply(res, 200, {
					token: token(subjectForEmail(email)),
					email,
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

	let stopping = false;
	return {
		port,
		databasePort,
		client,
		stop: async () => {
			if (stopping) return;
			stopping = true;
			await compactor.stop().catch(() => {});
			client.disconnect();
			await new Promise<void>((resolveClose) =>
				server.close(() => resolveClose()),
			);
			database.kill("SIGINT");
			await database.exited.catch(() => {});
			await rm(runtime, { recursive: true, force: true }).catch(() => {});
		},
	};
}

if (import.meta.main) {
	const handle = await startVersoServer({
		port: Number(process.env.VERSO_PORT ?? DEFAULT_PORT),
		databasePort: Number(process.env.VERSO_DB_PORT ?? DEFAULT_DATABASE_PORT),
		origin: process.env.VERSO_ORIGIN ?? DEFAULT_ORIGIN,
		dataDir: process.env.VERSO_DATA_DIR,
	});
	console.log(
		`Verso app on ${handle.port}, ZyncBase on ${handle.databasePort}`,
	);
	for (const signal of ["SIGINT", "SIGTERM"] as const) {
		process.on(signal, () => {
			void handle.stop().then(() => process.exit(0));
		});
	}
}
