// One native Worker per 64 SDK peers keeps load generation off a single JS loop.
// Peers run the same data plane as the browser client (viewport.ts): decoded
// chunk caches, LocalMotion prediction, eased camera, key-gated subscriptions,
// and change-only move publishing.
import { createClient } from "@zyncbase/client";
import type { ZyncBaseActions, ZyncBaseSchema } from "./schema-types";
import type { AppClient } from "./shared";
import {
	COUNTRY_COLOR_INDEX,
	type CountryChunkRow,
	findCoordinate,
	NAMESPACE,
	readColorIndexes,
	terrain,
	type UserChunkRow,
} from "./shared";
import { FRAME_MS, ownerAt, ViewSession } from "./viewport";

type Peer = {
	client: AppClient;
	id: string;
	slot: number;
	name: string;
	countryId: number;
	colorIndex: number;
	// Decoded country chunks, exactly the browser's palette-code cache: the
	// motion prediction joins owners through it.
	chunks: Map<number, { colorIndexes: Uint8Array }>;
	session: ViewSession;
	x: number;
	y: number;
	positioned: boolean;
	index: number;
	width: number;
	height: number;
	zoom: number;
	moves: number;
	lastRowAt: number;
};
type Command = {
	type: "add" | "move" | "reset" | "stats" | "close";
	index: number;
	width: number;
	height: number;
	zoom: number;
	url: string;
	token: string;
	session_id?: string;
	country_id: number;
	moving: boolean;
};
const peers: Peer[] = [];
const errors: string[] = [];
const land = terrain();
// Wire bytes across every peer in this worker: the SDK owns the sockets, so
// count at the global WebSocket the SDK constructs.
let wireRxBytes = 0,
	wireTxBytes = 0;
const byteLength = (data: unknown): number => {
	if (typeof data === "string")
		return new TextEncoder().encode(data).byteLength;
	if (data instanceof Blob) return data.size;
	return (data as ArrayBuffer | ArrayBufferView).byteLength;
};
const NativeWebSocket = globalThis.WebSocket;
globalThis.WebSocket = new Proxy(NativeWebSocket, {
	construct(target, args) {
		const socket = Reflect.construct(target, args) as WebSocket;
		const send = socket.send.bind(socket);
		socket.send = (data) => {
			wireTxBytes += byteLength(data);
			send(data);
		};
		socket.addEventListener("message", (event) => {
			wireRxBytes += byteLength((event as MessageEvent).data);
		});
		return socket;
	},
});
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
let rowIntervals: number[] = [];
const moveAcks: number[] = [];
let moveAckGeneration = 0;

function receiveCountryChunk(peer: Peer, row: CountryChunkRow) {
	const index = Number(row.id);
	if (!Number.isSafeInteger(index)) return;
	peer.chunks.set(index, { colorIndexes: readColorIndexes(row.color_indexes) });
	peer.session.dirty = true;
}

function receiveUserChunk(peer: Peer, row: UserChunkRow) {
	const index = Number(row.id);
	if (!Number.isSafeInteger(index)) return;
	peer.session.dirty = true;
	// Slots, not arrays: only this peer's own dot matters here.
	const self = findCoordinate(row.coordinates, peer.slot);
	if (!self) return;
	// Server responsiveness: cadence of own-dot rows, independent of terrain
	// movement cost.
	const arrived = performance.now();
	if (peer.lastRowAt) rowIntervals.push(arrived - peer.lastRowAt);
	peer.lastRowAt = arrived;
	// Own dot: mirror the browser's updateSelfMotion + eased follow.
	const dot = { ...self, colorIndex: peer.colorIndex };
	if (peer.x !== self.x || peer.y !== self.y) peer.moves++;
	peer.x = self.x;
	peer.y = self.y;
	peer.session.receiveSelf(dot, performance.now());
}

// The committed roster row carries the admitted cell; the roster publishes on a
// slower cadence, so read it in the background rather than blocking admission.
async function readSpawn(peer: Peer) {
	const id = peer.id;
	if (!id) return undefined;
	try {
		const me = await peer.client.store.get(["users", id]);
		const x = me?.last_x;
		const y = me?.last_y;
		if (
			typeof x !== "number" ||
			typeof y !== "number" ||
			!Number.isSafeInteger(x) ||
			!Number.isSafeInteger(y)
		)
			return undefined;
		if (typeof me?.slot === "number" && me.slot > 0) peer.slot = me.slot;
		return { x, y };
	} catch {
		return undefined;
	}
}

async function locate(peer: Peer) {
	for (let attempt = 0; attempt < 100 && !peer.positioned; attempt++) {
		const position = await readSpawn(peer);
		if (position) {
			peer.positioned = true;
			peer.x = position.x;
			peer.y = position.y;
			peer.session.retarget(position.x, position.y);
			return;
		}
		await new Promise((resolve) => setTimeout(resolve, 100));
	}
}

const heartbeat = setInterval(() => {
	const now = performance.now();
	heartbeatLag.push(Math.max(0, now - lastBeat - 500));
	lastBeat = now;
	for (const peer of peers) {
		const direction = moving
			? (["right", "down", "left", "up"] as const)[
					(Math.floor((Date.now() - started) / 4000) + (peer.index % 4)) % 4
				]
			: "idle";
		// The session sends only when the direction actually changes.
		peer.session.setDirection(direction);
	}
}, 500);

// The browser's frame loop, per worker: motion prediction, camera easing, and
// key-gated subscription bounds for every local peer.
const frame = setInterval(() => {
	const now = performance.now();
	for (const peer of peers) peer.session.frame(now);
}, FRAME_MS);

/** Builds one peer end to end: connect, join, subscribe, admit, locate. */
async function addPeer(data: Command, sessionId: string): Promise<void> {
	const client = createClient<ZyncBaseSchema, ZyncBaseActions>({
		url: data.url,
		auth: { tokenProvider: async () => data.token },
		storeNamespace: NAMESPACE,
		reconnect: false,
	});
	// Server responsiveness: time player_move action round trips.
	const call = client.actions.call.bind(client.actions);
	client.actions.call = (name, params, options) => {
		if (name !== "player_move") return call(name, params, options);
		const sent = performance.now();
		const generation = moveAckGeneration;
		const pending = call(name, params, options);
		void pending.then(
			() => {
				if (generation === moveAckGeneration)
					moveAcks.push(performance.now() - sent);
			},
			() => {},
		);
		return pending;
	};
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
		id: "",
		slot: 0,
		name: `Player ${data.index + 1}`,
		countryId: data.country_id,
		colorIndex: 0,
		chunks: new Map(),
		session: undefined as unknown as ViewSession,
		x: 933,
		y: 276,
		positioned: false,
		index: data.index,
		width: data.width,
		height: data.height,
		zoom: data.zoom,
		moves: 0,
		lastRowAt: 0,
	};
	peer.session = new ViewSession({
		store: () => client.store,
		width: peer.width,
		height: peer.height,
		scale: peer.zoom,
		land,
		ownerAt: (x, y) => ownerAt(peer.chunks, land, x, y),
		isOnline: () => true,
		client: () => client,
		sinks: {
			country: {
				receive: (row) => {
					callbacks++;
					receiveCountryChunk(peer, row as unknown as CountryChunkRow);
				},
				removed: (index) => {
					callbacks++;
					peer.chunks.delete(index);
					peer.session.dirty = true;
				},
			},
			user: {
				receive: (row) => {
					callbacks++;
					receiveUserChunk(peer, row as unknown as UserChunkRow);
				},
				removed: () => callbacks++,
			},
		},
	});
	try {
		const joined = await client.actions.call("player_join", {
			name: peer.name,
			country_id: peer.countryId,
			session_id: sessionId,
		});
		peer.id = joined.user_id;
		peer.slot = joined.slot;
		await client.presence.set({});
		// Browser order: publish the initial move, subscribe the cold
		// stores, then snap the camera to the admitted cell.
		peer.session.publishDirection();
		await client.store.subscribe("countries", { limit: 1000 }, (rows) => {
			callbacks++;
			const mine = rows.find((row) => row.country_id === peer.countryId);
			if (mine) peer.colorIndex = COUNTRY_COLOR_INDEX.get(mine.color) ?? 0;
		});
		await client.store.subscribe("users", { limit: 2048 }, () => {
			callbacks++;
		});
		peer.session.admit(
			Number.isSafeInteger(joined.x) && Number.isSafeInteger(joined.y)
				? { x: joined.x as number, y: joined.y as number }
				: undefined,
		);
		peers.push(peer);
		void locate(peer);
	} catch (error) {
		client.disconnect();
		throw error;
	}
}

self.onmessage = async ({ data }: MessageEvent<Command>) => {
	try {
		if (data.type === "add") {
			const sessionId = data.session_id;
			if (!sessionId) throw new Error("Player session lease is missing");
			await addPeer(data, sessionId);
		} else if (data.type === "move") {
			moving = data.moving;
			started = Date.now();
		} else if (data.type === "reset") {
			callbacks = 0;
			lateDeltas = 0;
			heartbeatLag = [];
			lastBeat = performance.now();
			rowIntervals = [];
			moveAcks.length = 0;
			moveAckGeneration++;
			wireRxBytes = 0;
			wireTxBytes = 0;
			for (const peer of peers) {
				peer.moves = 0;
				peer.lastRowAt = 0;
			}
		} else if (data.type === "close") {
			clearInterval(heartbeat);
			clearInterval(frame);
			for (const peer of peers) peer.client.disconnect();
		}
		self.postMessage({
			lateDeltas,
			callbacks,
			heartbeatLag,
			errors,
			rxBytes: wireRxBytes,
			txBytes: wireTxBytes,
			moveAcks,
			rowIntervals,
			subscriptions: peers.reduce(
				(n, p) => n + p.session.subscriptions.count + 2,
				0,
			),
			movingPeers: peers.filter((p) => p.moves > 0).length,
			positioned: peers.filter((p) => p.positioned).length,
		});
	} catch (error) {
		self.postMessage({ failure: String(error) });
	}
};
