// Local development/test substitute for Cloudflare path routing. Not used on the VM.
import { readFile } from "node:fs/promises";
import { createServer, request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { join } from "node:path";
import type { Duplex } from "node:stream";
import { buildBrowser } from "./build";

export async function startLocalEdge(options: {
	port: number;
	authPort: number;
	databasePort: number;
	assets: string;
	ca?: string;
}) {
	const sockets = new Set<Duplex>();
	const request = options.ca ? httpsRequest : httpRequest;
	const upstream = {
		hostname: options.ca ? "::1" : "127.0.0.1",
		servername: "localhost",
		ca: options.ca,
		// A fresh socket per proxy request. A pooled keep-alive socket the
		// upstream closed on its idle timeout races the next request and
		// surfaces as a spurious 502 on /session or /health.
		agent: false,
	};
	const assets = new Map([
		["/", ["index.html", "text/html"]],
		["/client.js", ["client.js", "text/javascript"]],
		["/style.css", ["style.css", "text/css"]],
		["/history.html", ["history.html", "text/html"]],
		["/favicon.svg", ["favicon.svg", "image/svg+xml"]],
		["/og.png", ["og.png", "image/png"]],
	]);
	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: this development-only handler mirrors static and HTTP origin routing.
	const server = createServer(async (req, res) => {
		const path = new URL(req.url ?? "/", "http://localhost").pathname;
		const asset = assets.get(path);
		if (asset && req.method === "GET") {
			try {
				const bytes = await readFile(join(options.assets, asset[0]));
				res.writeHead(200, { "Content-Type": asset[1] });
				res.end(bytes);
			} catch {
				res.writeHead(500).end("Build browser assets first");
			}
			return;
		}
		// History is written into the assets directory by the game process and
		// is a Worker asset in production; the local edge serves it from disk.
		if (path.startsWith("/history/")) {
			const name = path.slice("/history/".length);
			if (!/^(?:\d+\.(?:json|png)|index\.json)$/.test(name)) {
				res.writeHead(404).end();
				return;
			}
			try {
				const bytes = await readFile(join(options.assets, "history", name));
				res.writeHead(200, {
					"Content-Type": name.endsWith(".png")
						? "image/png"
						: "application/json",
				});
				res.end(bytes);
			} catch {
				res.writeHead(404).end();
			}
			return;
		}
		if (!["/session", "/health", "/auth/ticket"].includes(path)) {
			res.writeHead(404).end();
			return;
		}
		const target = request(
			{
				...upstream,
				port: path === "/auth/ticket" ? options.databasePort : options.authPort,
				path: req.url,
				method: req.method,
				headers: { ...req.headers, connection: "close" },
			},
			(response) => {
				res.writeHead(response.statusCode ?? 502, response.headers);
				response.pipe(res);
			},
		);
		target.on("error", (error) => {
			// /health is polled while the upstream starts; a refused /session
			// or /auth/ticket is a real failure and stays logged.
			const refused = (error as { code?: string }).code === "ECONNREFUSED";
			if (path !== "/health" || !refused)
				console.error(`Proxy error for ${path}:`, error);
			if (!res.headersSent) res.writeHead(502);
			res.end();
		});
		res.on("close", () => target.destroy());
		req.pipe(target);
	});
	server.on("upgrade", (req, socket, head) => {
		if (new URL(req.url ?? "/", "http://localhost").pathname !== "/ws") {
			socket.end(
				"HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n",
			);
			return;
		}
		const target = request({
			...upstream,
			port: options.databasePort,
			path: req.url,
			headers: req.headers,
		});
		target.on("upgrade", (response, stream, upstreamHead) => {
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
	await new Promise<void>((resolve, reject) => {
		server.once("error", reject);
		server.listen(options.port, "127.0.0.1", resolve);
	});
	const address = server.address();
	const boundPort =
		typeof address === "object" && address ? address.port : options.port;
	const stop = () =>
		new Promise<void>((resolve) => {
			server.close(() => resolve());
			for (const socket of sockets) socket.destroy();
		});
	return { port: boundPort, stop };
}

if (import.meta.main) {
	if (process.env.GAME_TLS_CERT || process.env.GAME_TLS_KEY)
		throw new Error("Use demo:game:start for deployment with TLS");
	const edge = await startLocalEdge({
		port: Number(process.env.GAME_DEV_PORT ?? 8080),
		authPort: Number(process.env.GAME_PORT ?? 8081),
		databasePort: Number(process.env.GAME_DB_PORT ?? 3001),
		assets: await buildBrowser(),
	});
	let game: Bun.Subprocess | undefined;
	let stopping = false;
	const stopGame = () => {
		stopping = true;
		game?.kill("SIGINT");
	};
	process.on("SIGINT", stopGame);
	process.on("SIGTERM", stopGame);
	let code = 0;
	do {
		game = Bun.spawn(
			["bun", join(import.meta.dir, "server.ts"), ...process.argv.slice(2)],
			{
				env: {
					...process.env,
					GAME_HOST: "127.0.0.1",
					GAME_ORIGIN: `http://localhost:${edge.port}`,
				},
				stdout: "inherit",
				stderr: "inherit",
				detached: true,
			},
		);
		code = await game.exited;
		// A scheduled round restart exits 0; respawn unless the user stopped us.
		if (code === 0 && !stopping) await Bun.sleep(500);
	} while (code === 0 && !stopping);
	await edge.stop();
	process.exit(stopping ? 0 : code);
}
