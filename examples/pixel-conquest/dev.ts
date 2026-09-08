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
	};
	const assets = new Map([
		["/", ["index.html", "text/html"]],
		["/client.js", ["client.js", "text/javascript"]],
		["/style.css", ["style.css", "text/css"]],
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
				headers: req.headers,
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
	return () =>
		new Promise<void>((resolve) => {
			server.close(() => resolve());
			for (const socket of sockets) socket.destroy();
		});
}

if (import.meta.main) {
	if (process.env.GAME_TLS_CERT || process.env.GAME_TLS_KEY)
		throw new Error("Use demo:game:start for deployment with TLS");
	const port = Number(process.env.GAME_DEV_PORT ?? 8080);
	const stopEdge = await startLocalEdge({
		port,
		authPort: Number(process.env.GAME_PORT ?? 8081),
		databasePort: Number(process.env.GAME_DB_PORT ?? 3001),
		assets: await buildBrowser(),
	});
	const game = Bun.spawn(
		["bun", join(import.meta.dir, "server.ts"), ...process.argv.slice(2)],
		{
			env: {
				...process.env,
				GAME_HOST: "127.0.0.1",
				GAME_ORIGIN: `http://localhost:${port}`,
			},
			stdout: "inherit",
			stderr: "inherit",
			detached: true,
		},
	);
	process.on("SIGINT", () => game.kill("SIGINT"));
	process.on("SIGTERM", () => game.kill("SIGTERM"));
	const code = await game.exited;
	await stopEdge();
	process.exit(code);
}
