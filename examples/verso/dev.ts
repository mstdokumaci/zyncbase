import { readFile, rm } from "node:fs/promises";
import {
	createServer,
	request as httpRequest,
	type IncomingMessage,
	type ServerResponse,
} from "node:http";
import { join, resolve } from "node:path";
import type { Duplex } from "node:stream";
import { buildBrowser } from "./build";

const ROOT = resolve(import.meta.dir, "../..");
const ASSETS = new Map([
	["/", ["index.html", "text/html"]],
	["/client.js", ["client.js", "text/javascript"]],
	["/style.css", ["style.css", "text/css"]],
	["/favicon.svg", ["favicon.svg", "image/svg+xml"]],
]);

async function serveAsset(
	res: ServerResponse,
	path: string,
	assetsDir: string,
): Promise<boolean> {
	const asset = ASSETS.get(path) ?? (path === "/" ? ASSETS.get("/") : null);
	if (!asset) return false;
	try {
		const bytes = await readFile(join(assetsDir, asset[0]));
		res.writeHead(200, { "Content-Type": asset[1] });
		res.end(bytes);
	} catch {
		res.writeHead(500).end("Build the browser assets first");
	}
	return true;
}

function proxyHttp(
	req: IncomingMessage,
	res: ServerResponse,
	port: number,
): void {
	const target = httpRequest(
		{
			hostname: "127.0.0.1",
			port,
			path: req.url,
			method: req.method,
			headers: { ...req.headers, connection: "close" },
			agent: false,
		},
		(response) => {
			res.writeHead(response.statusCode ?? 502, response.headers);
			response.pipe(res);
		},
	);
	target.on("error", () => {
		if (!res.headersSent) res.writeHead(502);
		res.end();
	});
	res.on("close", () => target.destroy());
	req.pipe(target);
}

async function startEdge(options: {
	port: number;
	appPort: number;
	databasePort: number;
	assets: string;
}) {
	const sockets = new Set<Duplex>();
	const server = createServer(async (req, res) => {
		const path = new URL(req.url ?? "/", "http://localhost").pathname;
		if (await serveAsset(res, path, options.assets)) return;
		if (path === "/session" || path === "/health") {
			proxyHttp(req, res, options.appPort);
			return;
		}
		if (path === "/auth/ticket") {
			proxyHttp(req, res, options.databasePort);
			return;
		}
		res.writeHead(404).end();
	});

	server.on("upgrade", (req, socket, head) => {
		if (new URL(req.url ?? "/", "http://localhost").pathname !== "/ws") {
			socket.end(
				"HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n",
			);
			return;
		}
		const target = httpRequest({
			hostname: "127.0.0.1",
			port: options.databasePort,
			path: req.url,
			headers: req.headers,
			agent: false,
		});
		target.on("upgrade", (response, stream, upstreamHead) => {
			const headers = response.rawHeaders.reduce(
				(all, value, index) =>
					all + (index % 2 === 0 ? `${value}: ` : `${value}\r\n`),
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
		target.on("response", (response) => {
			socket.end(
				`HTTP/1.1 ${response.statusCode ?? 502} Rejected\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`,
			);
			response.resume();
		});
		target.on("error", () => socket.destroy());
		socket.on("error", () => target.destroy());
		socket.on("close", () => target.destroy());
		target.end();
	});

	server.on("connection", (socket) => {
		sockets.add(socket);
		socket.on("close", () => sockets.delete(socket));
	});

	await new Promise<void>((resolveListen, reject) => {
		server.once("error", reject);
		server.listen(options.port, "127.0.0.1", resolveListen);
	});

	return {
		stop: () =>
			new Promise<void>((resolveClose) => {
				server.close(() => resolveClose());
				for (const socket of sockets) socket.destroy();
			}),
	};
}

async function waitForHealth(port: number, timeoutMs = 30_000): Promise<void> {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		try {
			const response = await fetch(`http://127.0.0.1:${port}/health`);
			if (response.ok) return;
		} catch {}
		await Bun.sleep(150);
	}
	throw new Error("Verso app server did not become ready");
}

if (import.meta.main) {
	const devPort = Number(process.env.VERSO_DEV_PORT ?? 8080);
	const appPort = Number(process.env.VERSO_PORT ?? 8081);
	const databasePort = Number(process.env.VERSO_DB_PORT ?? 3001);
	const origin = `http://localhost:${devPort}`;
	const dataDir = resolve(
		process.env.VERSO_DATA_DIR ?? join(ROOT, "data/verso"),
	);
	if (process.argv.includes("--reset")) {
		await rm(dataDir, { recursive: true, force: true });
	}
	const assets = await buildBrowser();

	const app = Bun.spawn(["bun", join(import.meta.dir, "server.ts")], {
		env: {
			...process.env,
			VERSO_PORT: String(appPort),
			VERSO_DB_PORT: String(databasePort),
			VERSO_ORIGIN: origin,
			VERSO_DATA_DIR: dataDir,
		},
		cwd: ROOT,
		stdout: "inherit",
		stderr: "inherit",
		detached: true,
	});

	let stopping = false;
	let edge: Awaited<ReturnType<typeof startEdge>> | undefined;
	const stop = async (exitCode = 0) => {
		if (stopping) return;
		stopping = true;
		await edge?.stop().catch(() => {});
		app.kill("SIGINT");
		await app.exited.catch(() => {});
		process.exit(exitCode);
	};
	process.on("SIGINT", () => void stop(0));
	process.on("SIGTERM", () => void stop(0));

	try {
		await waitForHealth(appPort);
		edge = await startEdge({
			port: devPort,
			appPort,
			databasePort,
			assets,
		});
		console.log(`Verso on ${origin}`);
	} catch (error) {
		console.error("Verso failed to start:", error);
		await stop(1);
	}
}
