// One native Worker per 64 SDK peers keeps load generation off a single JS loop.
import { createClient, type ZyncBaseClient } from "@zyncbase/client";
import {
	CHUNK,
	type ChunkRow,
	COLUMNS,
	HEIGHT,
	NAMESPACE,
	readDots,
} from "./shared";

type Peer = {
	client: ZyncBaseClient;
	input: { name: string; countryCode: number; direction: string; seq: number };
	subscriptions: Map<number, () => void>;
	x: number;
	y: number;
	index: number;
	width: number;
	height: number;
	zoom: number;
	moves: number;
};
type Command = {
	type: "add" | "move" | "reset" | "stats" | "close";
	index: number;
	width: number;
	height: number;
	zoom: number;
	url: string;
	token: string;
	countryCode: number;
	moving: boolean;
};
const peers: Peer[] = [];
const errors: string[] = [];
let lateDeltas = 0;
const warn = console.warn;
console.warn = (message, ...args) => {
	if (
		typeof message === "string" &&
		message.startsWith("[SDK] Received delta for unknown subId:")
	)
		lateDeltas++;
	else warn(message, ...args);
};
let moving = false,
	started = Date.now(),
	callbacks = 0,
	lastBeat = performance.now();
let heartbeatLag: number[] = [];

function subscribe(peer: Peer) {
	const visible = new Set<number>();
	const left = Math.max(
		0,
		Math.floor((peer.x - peer.width / peer.zoom / 2) / CHUNK) - 1,
	);
	const right = Math.min(
		COLUMNS - 1,
		Math.floor((peer.x + peer.width / peer.zoom / 2) / CHUNK) + 1,
	);
	const top = Math.max(
		0,
		Math.floor((peer.y - peer.height / peer.zoom / 2) / CHUNK) - 1,
	);
	const bottom = Math.min(
		Math.ceil(HEIGHT / CHUNK) - 1,
		Math.floor((peer.y + peer.height / peer.zoom / 2) / CHUNK) + 1,
	);
	for (let y = top; y <= bottom; y++)
		for (let x = left; x <= right; x++) visible.add(y * COLUMNS + x);
	for (const [index, unsub] of peer.subscriptions) {
		if (visible.has(index)) continue;
		unsub();
		peer.subscriptions.delete(index);
	}
	for (const index of visible) {
		if (peer.subscriptions.has(index)) continue;
		peer.subscriptions.set(
			index,
			peer.client.store.listen(["chunks", String(index)], (row) => {
				callbacks++;
				if (!row) return;
				const dot = readDots((row as unknown as ChunkRow).dots).find(
					(dot) => dot.player_id === peer.client.presence.localUserId,
				);
				if (!dot || (peer.x === dot.x && peer.y === dot.y)) return;
				peer.moves++;
				peer.x = dot.x;
				peer.y = dot.y;
				subscribe(peer);
			}),
		);
	}
}

const heartbeat = setInterval(() => {
	const now = performance.now();
	heartbeatLag.push(Math.max(0, now - lastBeat - 500));
	lastBeat = now;
	for (const peer of peers) {
		const direction = moving
			? ["right", "down", "left", "up"][
					(Math.floor((Date.now() - started) / 4000) + (peer.index % 4)) % 4
				]
			: "idle";
		if (peer.input.direction !== direction) {
			peer.input.direction = direction;
			peer.input.seq++;
		}
		peer.client.presence.set({ ...peer.input });
	}
}, 500);

self.onmessage = async ({ data }: MessageEvent<Command>) => {
	try {
		if (data.type === "add") {
			const client = createClient({
				url: data.url,
				auth: { tokenProvider: async () => data.token },
				storeNamespace: NAMESPACE,
				presenceNamespace: NAMESPACE,
				reconnect: false,
			});
			client.on("error", (error) => errors.push(String(error)));
			client.on("disconnected", () =>
				errors.push(`Peer ${data.index} disconnected`),
			);
			await client.connect().catch((error) => {
				client.disconnect();
				throw error;
			});
			const peer: Peer = {
				client,
				index: data.index,
				width: data.width,
				height: data.height,
				zoom: data.zoom,
				x: 933,
				y: 276,
				moves: 0,
				subscriptions: new Map(),
				input: {
					name: `Player ${data.index + 1}`,
					countryCode: data.countryCode,
					direction: "idle",
					seq: 0,
				},
			};
			peers.push(peer);
			client.store.subscribe("countries", { limit: 1000 }, () => callbacks++);
			client.store.subscribe("users", { limit: 2048 }, () => callbacks++);
			client.presence.set(peer.input);
			subscribe(peer);
		} else if (data.type === "move") {
			moving = data.moving;
			started = Date.now();
		} else if (data.type === "reset") {
			callbacks = 0;
			lateDeltas = 0;
			heartbeatLag = [];
			for (const peer of peers) peer.moves = 0;
		} else if (data.type === "close") {
			clearInterval(heartbeat);
			for (const peer of peers) peer.client.disconnect();
		}
		self.postMessage({
			lateDeltas,
			callbacks,
			heartbeatLag,
			errors,
			subscriptions: peers.reduce((n, p) => n + p.subscriptions.size + 2, 0),
			movingPeers: peers.filter((p) => p.moves > 0).length,
		});
	} catch (error) {
		self.postMessage({ failure: String(error) });
	}
};
