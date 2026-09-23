import map from "./land.json";

export const WIDTH = map.width;
export const HEIGHT = map.height;
// Country chunks: ownership bitmaps on a 40x40 grid of 50x25-cell chunks.
// Both dimensions divide the map exactly, so every chunk is full-sized.
export const COUNTRY_CHUNK_WIDTH = 50;
export const COUNTRY_CHUNK_HEIGHT = 25;
export const COUNTRY_COLUMNS = WIDTH / COUNTRY_CHUNK_WIDTH;
export const COUNTRY_ROWS = HEIGHT / COUNTRY_CHUNK_HEIGHT;
export const COUNTRY_CHUNK_CELLS = COUNTRY_CHUNK_WIDTH * COUNTRY_CHUNK_HEIGHT;
// Run-length pairs (count 1..255, color index): worst case every cell flips.
export const COUNTRY_COLOR_INDEXES_MAX = COUNTRY_CHUNK_CELLS * 2;
// User chunks: player coordinates on a 10x10 grid of 200x100-cell chunks. A
// movement only rewrites its chunk's row, so the grid is coarse on purpose.
export const USER_CHUNK_WIDTH = 200;
export const USER_CHUNK_HEIGHT = 100;
export const USER_COLUMNS = WIDTH / USER_CHUNK_WIDTH;
export const USER_ROWS = HEIGHT / USER_CHUNK_HEIGHT;
export const USER_CHUNK_COUNT = USER_COLUMNS * USER_ROWS;
export const NAMESPACE = "world-1";
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
// Wire owner codes: 0 = unowned, 1..MAX_COUNTRIES = COUNTRY_COLORS[code - 1].
// Chunk bitmaps store these codes; country ids stay simulation-only.
export const COUNTRY_COLOR_INDEX = new Map(
	COUNTRY_COLORS.map((color, index) => [color, index + 1]),
);
// Snapshot and canvas must agree on terrain colors.
export const LAND_RGB = [80, 87, 94] as const;
export const WATER_RGB = [19, 37, 52] as const;
export const encoder = new TextEncoder();
export const decoder = new TextDecoder();
// Packed-color words are native-endian Uint32s; byte order depends on the host.
export const LITTLE_ENDIAN =
	new Uint8Array(new Uint16Array([1]).buffer)[0] === 1;

export type Direction = "idle" | "up" | "down" | "left" | "right";
// Hot per-tick position broadcast, embedded in chunks.dots. Only x/y change
// often; identity and country live in the users table (one cold row per
// player, subscribed once) and are joined client-side at render.
export type Dot = {
	player_id: string;
	x: number;
	y: number;
};
// Cold roster row, stored in the users table keyed by identity: written on
// admission, refreshed on chunk crossing and on leave (tombstone with final
// position for grace reconnects), removed on expiry. last_x/last_y always name
// the chunk the player is (or was) in, so locate() can jump straight to it
// with one direct read.
export type PlayerRow = {
	id: string;
	name?: string;
	country_id: number;
	is_bot: boolean;
	last_x: number;
	last_y: number;
};
// A country's numeric identity: referenced by PlayerRow.country_id. Its row key
// in the countries table is the string form, and its palette color selects the
// owner code written into chunk bitmaps.
export type Country = {
	country_id: number;
	name: string;
	color: string;
	count: number;
	is_bot: boolean;
};
export type CountryChunkRow = {
	id: string;
	// RLE (count, color index) pairs of COUNTRY_CHUNK_CELLS palette codes.
	color_indexes: Uint8Array;
};
export type UserChunkRow = {
	id: string;
	// JSON Dot[] of the live players inside this user chunk.
	coordinates: Uint8Array;
};
export type RoundInfo = {
	number: number;
	startedAt: number;
	endsAt: number;
};
/** Round state persisted in `round.json`; `fresh` means boot wipes before restoring. */
export type RoundCursor = RoundInfo & { fresh?: boolean };

// Round boundaries are absolute multiples of the period since the Unix epoch,
// so the default 1 h period lands on the hour and restarts cannot drift.
export function nextRoundBoundary(now: number, periodMs: number) {
	return (Math.floor(now / periodMs) + 1) * periodMs;
}

export function terrain() {
	const result = new Uint8Array(WIDTH * HEIGHT);
	for (let i = 0; i < map.runs.length; i += 2) {
		const start = map.runs[i];
		result.fill(1, start, start + map.runs[i + 1]);
	}
	return result;
}

// The world wraps horizontally; every canonical storage/lookup coordinate
// stays inside [0, WIDTH).
export function wrapX(x: number) {
	return ((x % WIDTH) + WIDTH) % WIDTH;
}

export function countryChunkIndex(x: number, y: number) {
	return (
		Math.floor(y / COUNTRY_CHUNK_HEIGHT) * COUNTRY_COLUMNS +
		Math.floor(x / COUNTRY_CHUNK_WIDTH)
	);
}

export function userChunkIndex(x: number, y: number) {
	return (
		Math.floor(y / USER_CHUNK_HEIGHT) * USER_COLUMNS +
		Math.floor(x / USER_CHUNK_WIDTH)
	);
}

export function rowId(index: number) {
	return String(index);
}

// Country chunks that hold no land can never change owner: no row exists for
// them and clients never subscribe. Derived from the same land runs as terrain.
export const WATER_COUNTRY_CHUNKS = (() => {
	const water = new Uint8Array(COUNTRY_COLUMNS * COUNTRY_ROWS).fill(1);
	for (let i = 0; i < map.runs.length; i += 2) {
		let start = map.runs[i];
		const end = start + map.runs[i + 1];
		while (start < end) {
			const y = Math.floor(start / WIDTH);
			const rowEnd = Math.min(end, (y + 1) * WIDTH);
			const first = Math.floor((start % WIDTH) / COUNTRY_CHUNK_WIDTH);
			const last = Math.floor(((rowEnd - 1) % WIDTH) / COUNTRY_CHUNK_WIDTH);
			const row = Math.floor(y / COUNTRY_CHUNK_HEIGHT);
			for (let column = first; column <= last; column++)
				water[row * COUNTRY_COLUMNS + column] = 0;
			start = rowEnd;
		}
	}
	return water;
})();

/** RLE-encode a chunk's palette codes as (count 1..255, index) pairs. */
export function encodeColorIndexes(codes: Uint8Array) {
	const encoded = new Uint8Array(codes.length * 2);
	let out = 0;
	let i = 0;
	while (i < codes.length) {
		const index = codes[i];
		let run = 1;
		while (run < 255 && i + run < codes.length && codes[i + run] === index)
			run++;
		encoded[out++] = run;
		encoded[out++] = index;
		i += run;
	}
	return encoded.slice(0, out);
}

/** Decode an RLE color-index chunk; rejects any stream that is not exact. */
export function readColorIndexes(bytes: Uint8Array) {
	const codes = new Uint8Array(COUNTRY_CHUNK_CELLS);
	let out = 0;
	for (let i = 0; i < bytes.length; i += 2) {
		if (i + 1 >= bytes.length) throw new Error("Invalid chunk size");
		const run = bytes[i];
		if (!run || out + run > codes.length) throw new Error("Invalid chunk size");
		codes.fill(bytes[i + 1], out, out + run);
		out += run;
	}
	if (out !== codes.length) throw new Error("Invalid chunk size");
	return codes;
}

export function readCoordinates(bytes: Uint8Array): Dot[] {
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
