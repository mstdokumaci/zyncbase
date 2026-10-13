// One native Worker per 64 SDK peers keeps load generation off a single JS loop.
// Peers run the same data plane as the browser client (viewport.ts): decoded
// chunk caches, LocalMotion prediction, eased camera, key-gated subscriptions,
// and change-only move publishing.
import { createClient, type ZyncBaseClient } from "@zyncbase/client";
import {
	COUNTRY_COLOR_INDEX,
	type Country,
	type CountryChunkRow,
	findCoordinate,
	NAMESPACE,
	type PlayerRow,
	readColorIndexes,
	terrain,
	type UserChunkRow,
} from "./shared";
import { FRAME_MS, ownerAt, ViewSession } from "./viewport";

type Peer = {
	client: ZyncBaseClient;
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
		const me = (await peer.client.store.get(["users", id])) as unknown as
			| PlayerRow
			| undefined;
		if (
			!me ||
			!Number.isSafeInteger(me.last_x) ||
			!Number.isSafeInteger(me.last_y)
		)
			return undefined;
		if (Number.isSafeInteger(me.slot) && me.slot > 0) peer.slot = me.slot;
		return { x: me.last_x, y: me.last_y };
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

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: keep validation next to the worker message it protects.
self.onmessage = async ({ data }: MessageEvent<Command>) => {
	try {
		if (data.type === "add") {
			const sessionId = data.session_id;
			if (!sessionId) throw new Error("Player session lease is missing");
			const client = createClient({
				url: data.url,
				auth: { tokenProvider: async () => data.token },
				storeNamespace: NAMESPACE,
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
				const joined = (await client.actions.call("player_join", {
					name: peer.name,
					country_id: peer.countryId,
					session_id: sessionId,
				})) as {
					user_id?: unknown;
					slot?: unknown;
					x?: unknown;
					y?: unknown;
				};
				peer.id = typeof joined.user_id === "string" ? joined.user_id : "";
				peer.slot = Number.isSafeInteger(joined.slot)
					? (joined.slot as number)
					: 0;
				await client.presence.set({});
				// Browser order: publish the initial move, subscribe the cold
				// stores, then snap the camera to the admitted cell.
				peer.session.publishDirection();
				await client.store.subscribe("countries", { limit: 1000 }, (rows) => {
					callbacks++;
					const mine = (rows as Country[]).find(
						(row) => row.country_id === peer.countryId,
					);
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
			clearInterval(frame);
			for (const peer of peers) peer.client.disconnect();
		}
		self.postMessage({
			lateDeltas,
			callbacks,
			heartbeatLag,
			errors,
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
