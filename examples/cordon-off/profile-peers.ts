// One native Worker per 64 SDK peers keeps load generation off a single JS loop.
import { createClient, type ZyncBaseClient } from "@zyncbase/client";
import {
	COUNTRY_CHUNK_HEIGHT,
	COUNTRY_CHUNK_WIDTH,
	COUNTRY_COLUMNS,
	COUNTRY_ROWS,
	NAMESPACE,
	type PlayerRow,
	readCoordinates,
	USER_CHUNK_HEIGHT,
	USER_CHUNK_WIDTH,
	USER_COLUMNS,
	USER_ROWS,
	type UserChunkRow,
	WATER_COUNTRY_CHUNKS,
} from "./shared";

type Peer = {
	client: ZyncBaseClient;
	id: string;
	name: string;
	countryId: number;
	input: { direction: string; seq: number };
	subscriptions: Map<number, () => void>;
	userSubscriptions: Map<number, () => void>;
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

// Peers mirror the browser: one subscription set per grid, viewport-sized.
function visibleFor(
	peer: Peer,
	chunkWidth: number,
	chunkHeight: number,
	columns: number,
	rows: number,
	margin: number,
	water?: Uint8Array,
) {
	const visible = new Set<number>();
	const left = Math.max(
		0,
		Math.floor((peer.x - peer.width / peer.zoom / 2) / chunkWidth) - margin,
	);
	const right = Math.min(
		columns - 1,
		Math.floor((peer.x + peer.width / peer.zoom / 2) / chunkWidth) + margin,
	);
	const top = Math.max(
		0,
		Math.floor((peer.y - peer.height / peer.zoom / 2) / chunkHeight) - margin,
	);
	const bottom = Math.min(
		rows - 1,
		Math.floor((peer.y + peer.height / peer.zoom / 2) / chunkHeight) + margin,
	);
	for (let y = top; y <= bottom; y++)
		for (let x = left; x <= right; x++) {
			const index = y * columns + x;
			if (!water?.[index]) visible.add(index);
		}
	return visible;
}

// Bring one grid's subscription set in line with its viewport.
function syncSubscriptions(
	subscriptions: Map<number, () => void>,
	visible: Set<number>,
	listenFor: (index: number) => () => void,
) {
	for (const [index, unsub] of subscriptions) {
		if (visible.has(index)) continue;
		unsub();
		subscriptions.delete(index);
	}
	for (const index of visible) {
		if (subscriptions.has(index)) continue;
		subscriptions.set(index, listenFor(index));
	}
}

function subscribe(peer: Peer) {
	syncSubscriptions(
		peer.subscriptions,
		visibleFor(
			peer,
			COUNTRY_CHUNK_WIDTH,
			COUNTRY_CHUNK_HEIGHT,
			COUNTRY_COLUMNS,
			COUNTRY_ROWS,
			// client.ts COUNTRY_PREFETCH_CHUNKS
			1,
			WATER_COUNTRY_CHUNKS,
		),
		(index) =>
			peer.client.store.listen(["country_chunks", String(index)], () => {
				callbacks++;
			}),
	);
	syncSubscriptions(
		peer.userSubscriptions,
		visibleFor(
			peer,
			USER_CHUNK_WIDTH,
			USER_CHUNK_HEIGHT,
			USER_COLUMNS,
			USER_ROWS,
			// client.ts USER_PREFETCH_CHUNKS
			0,
		),
		(index) =>
			peer.client.store.listen(["user_chunks", String(index)], (row) => {
				callbacks++;
				if (!row) return;
				const dot = readCoordinates(
					(row as unknown as UserChunkRow).coordinates,
				).find((dot) => dot.player_id === peer.id);
				if (!dot || (peer.x === dot.x && peer.y === dot.y)) return;
				peer.moves++;
				peer.x = dot.x;
				peer.y = dot.y;
				subscribe(peer);
			}),
	);
}

// The committed roster row carries the admitted spawn cell. Roster fanout is
// eventual, so read committed state and retry until the row lands; derive the
// position from delta timing instead and a slow flush silently leaves the
// peer framed on the wrong chunks.
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
			subscribe(peer);
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
			? ["right", "down", "left", "up"][
					(Math.floor((Date.now() - started) / 4000) + (peer.index % 4)) % 4
				]
			: "idle";
		if (peer.input.direction !== direction) {
			peer.input.direction = direction;
			peer.input.seq++;
		}
		void peer.client.actions
			.call("player_move", {
				direction: peer.input.direction,
				seq: peer.input.seq,
			})
			.catch(() => {});
	}
}, 500);

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
				name: `Player ${data.index + 1}`,
				countryId: data.country_id,
				index: data.index,
				width: data.width,
				height: data.height,
				zoom: data.zoom,
				x: 933,
				y: 276,
				positioned: false,
				moves: 0,
				subscriptions: new Map(),
				userSubscriptions: new Map(),
				input: { direction: "idle", seq: 0 },
			};
			peers.push(peer);
			client.store.subscribe("countries", { limit: 1000 }, () => callbacks++);
			client.store.subscribe("users", { limit: 2048 }, () => callbacks++);
			const joined = (await client.actions.call("player_join", {
				name: peer.name,
				country_id: peer.countryId,
				session_id: sessionId,
			})) as { user_id?: string };
			peer.id = joined.user_id ?? "";
			subscribe(peer);
			// Spawn regions are server state, so the placeholder above is only
			// a camera start. The committed roster row carries the admitted
			// cell; the roster publishes on a slower cadence, so read it in
			// the background rather than blocking admission.
			void locate(peer);
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
			subscriptions: peers.reduce(
				(n, p) => n + p.subscriptions.size + p.userSubscriptions.size + 2,
				0,
			),
			movingPeers: peers.filter((p) => p.moves > 0).length,
			positioned: peers.filter((p) => p.positioned).length,
		});
	} catch (error) {
		self.postMessage({ failure: String(error) });
	}
};
