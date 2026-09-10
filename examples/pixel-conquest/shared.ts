import map from "./land.json";

export const WIDTH = map.width;
export const HEIGHT = map.height;
export const CHUNK = 32;
export const COLUMNS = Math.ceil(WIDTH / CHUNK);
export const NAMESPACE = "pixel-conquest";
export const RULES = { tickMs: 50, own: 1, neutral: 2, enemy: 4, crossing: 6 };
export const MAX_PLAYERS = 1024;
export const MAX_COUNTRIES = 64;
export const MAX_PLAYER_NAME_LENGTH = 16;
export const INPUT_LEASE_MS = 2000;
// Departed players keep their store row briefly so a same-id reconnect
// respawns in place; rows never draw anything. ponytail: raise only if
// flap-reconnects still jump on slow networks.
export const PLAYER_GRACE_MS = INPUT_LEASE_MS * 5;
// Farthest-point sampling in OKLab, seeded with eight vivid colors.
// Lightness 0.55–0.94 and chroma >= 0.055 keep claims visible on the dark map.
export const COUNTRY_COLORS = [
	"#ef4444",
	"#2588f5",
	"#ffe14a",
	"#a66bff",
	"#31c96a",
	"#ff8a2b",
	"#f46ac1",
	"#35dfdb",
	"#707850",
	"#ffd0ff",
	"#70ff00",
	"#c000a8",
	"#a8a8d8",
	"#f000ff",
	"#a06898",
	"#009800",
	"#00a8b0",
	"#c0c088",
	"#c8f8d8",
	"#a89800",
	"#9008ff",
	"#ffa0b0",
	"#4078a0",
	"#c08878",
	"#b05800",
	"#50ffb0",
	"#b0d000",
	"#20b8ff",
	"#f80088",
	"#6058e8",
	"#ff98ff",
	"#c03868",
	"#ffd0a8",
	"#a8d8ff",
	"#9848c8",
	"#8088c8",
	"#f0b800",
	"#00e000",
	"#60a068",
	"#d8ff00",
	"#c888e8",
	"#c000e8",
	"#ff7080",
	"#d87000",
	"#d050d0",
	"#80b8b0",
	"#58ffff",
	"#f068ff",
	"#ff20c8",
	"#b8e888",
	"#008878",
	"#d06888",
	"#d02010",
	"#d0b8ff",
	"#788800",
	"#78d898",
	"#9098ff",
	"#7068b8",
	"#986860",
	"#d0a050",
	"#70a800",
	"#f8b078",
	"#98b858",
	"#d090b0",
];
export const encoder = new TextEncoder();
export const decoder = new TextDecoder();

export type Direction = "idle" | "up" | "down" | "left" | "right";
// Hot per-tick position broadcast, embedded in chunks.dots. Only x/y change
// often; identity and country live in the players table (one cold row per
// player, subscribed once) and are joined client-side at render.
export type Dot = {
	player_id: string;
	x: number;
	y: number;
};
// Cold roster row: written on admission, refreshed on chunk crossing and on
// leave (tombstone with final position for grace reconnects), removed on
// expiry. lastX/lastY always name the chunk the player is (or was) in, so
// locate() can jump straight to it with one direct read.
export type PlayerRow = {
	id: string;
	name?: string;
	country_id: number;
	is_bot: boolean;
	lastX: number;
	lastY: number;
};
export type Country = {
	id: string;
	code: number;
	name: string;
	color: string;
	count: number;
};
export type ChunkRow = {
	id: string;
	owners: Uint8Array;
	dots: Uint8Array;
};

export function terrain() {
	const result = new Uint8Array(WIDTH * HEIGHT);
	for (let i = 0; i < map.runs.length; i += 2) {
		const start = map.runs[i];
		result.fill(1, start, start + map.runs[i + 1]);
	}
	return result;
}

export function chunkIndex(x: number, y: number) {
	return Math.floor(y / CHUNK) * COLUMNS + Math.floor(x / CHUNK);
}

export function rowId(index: number) {
	return String(index);
}

export function readOwners(bytes: Uint8Array) {
	if (bytes.byteLength !== CHUNK * CHUNK * 2)
		throw new Error("Invalid chunk size");
	const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
	return Uint16Array.from({ length: CHUNK * CHUNK }, (_, i) =>
		view.getUint16(i * 2, true),
	);
}

export function readDots(bytes: Uint8Array): Dot[] {
	return JSON.parse(decoder.decode(bytes));
}

export function countryName(value: unknown): string {
	return displayName(value, "Country", 24);
}

export function playerName(value: unknown): string {
	return displayName(value, "Player", MAX_PLAYER_NAME_LENGTH);
}

function displayName(value: unknown, label: string, limit: number): string {
	if (typeof value !== "string")
		throw new Error(`Enter a ${label.toLowerCase()} name`);
	const name = value.normalize("NFKC").trim().replace(/\s+/gu, " ");
	if (!name || [...name].length > limit || /[\p{Cc}\p{Cf}]/u.test(name)) {
		throw new Error(
			`${label} names must contain 1–${limit} visible characters`,
		);
	}
	return name;
}
