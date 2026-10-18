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
// Packed coordinate rows: version, chunk index, dot count, then one 4-byte
// entry per dot (slot u16, chunk-local x u8, chunk-local y u8). The count is a
// u16, so a row holds at most COORDINATES_MAX_DOTS entries.
export const COORDINATES_VERSION = 1;
export const COORDINATES_HEADER_BYTES = 5;
export const COORDINATES_DOT_BYTES = 4;
export const COORDINATES_MAX_DOTS = 0xffff;
export const NAMESPACE = "world-1";
export const RULES = { tickMs: 50, own: 1, neutral: 2, enemy: 4, crossing: 6 };
export const MAX_PLAYERS = 1024;
export const MAX_COUNTRIES = 64;
export const MAX_PLAYER_NAME_LENGTH = 16;
export const COUNTRY_RESERVATION_MS = 10_000;
// A disconnected player can reconnect and resume at the saved cell for this long.
export const PLAYER_RESUME_GRACE_MS = 15_000;
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
// Packed-color words are native-endian Uint32s; byte order depends on the host.
export const LITTLE_ENDIAN =
	new Uint8Array(new Uint16Array([1]).buffer)[0] === 1;

export type Direction = "idle" | "up" | "down" | "left" | "right";
// Cardinal step vectors, shared so server movement and client prediction can
// never disagree about the movement table.
export const steps: Record<Direction, readonly [number, number]> = {
	idle: [0, 0],
	up: [0, -1],
	down: [0, 1],
	left: [-1, 0],
	right: [1, 0],
};
// Hot per-tick position broadcast, packed into user chunk rows. The numeric
// slot is a round-local player identity: names, countries and auth ids live in
// the users table (one cold row per player, subscribed once), joined
// client-side at render.
export type Dot = {
	slot: number;
	x: number;
	y: number;
};
// Cold roster row, stored in the users table keyed by identity: written on
// admission, refreshed on chunk crossing and on leave (tombstone with final
// position for grace reconnects), removed on expiry. last_x/last_y always name
// the chunk the player is (or was) in, so locate() can jump straight to it
// with one direct read. slot links the row to the packed dots.
export type PlayerRow = {
	id: string;
	name?: string;
	country_id: number;
	is_bot: boolean;
	last_x: number;
	last_y: number;
	slot: number;
	// Enclosure fills this player's own step paint triggered; the capture cue
	// watches the row of the local player only.
	captured?: number;
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
	// Round-local loss counter: land taken by enemy enclosure fills only,
	// never ordinary step painting. Clients turn an increment into a sound.
	lost?: number;
};
export type CountryChunkRow = {
	id: string;
	// RLE (count, color index) pairs of COUNTRY_CHUNK_CELLS palette codes.
	color_indexes: Uint8Array;
};
export type UserChunkRow = {
	id: string;
	// Packed Dot[] of the live players inside this user chunk.
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
		((y / COUNTRY_CHUNK_HEIGHT) | 0) * COUNTRY_COLUMNS +
		((x / COUNTRY_CHUNK_WIDTH) | 0)
	);
}

export function userChunkIndex(x: number, y: number) {
	return (
		((y / USER_CHUNK_HEIGHT) | 0) * USER_COLUMNS + ((x / USER_CHUNK_WIDTH) | 0)
	);
}

const ROW_IDS: string[] = Array.from(
	{ length: Math.max(COUNTRY_COLUMNS * COUNTRY_ROWS, USER_CHUNK_COUNT) },
	(_, i) => String(i),
);

export function rowId(index: number) {
	return ROW_IDS[index] ?? String(index);
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

/** A predicted country-chunk paint from a confirmed one-cell move. */
export type MovementPaint = {
	chunk: number;
	cell: number;
	code: number;
};

const RING_STEPS = [
	[-1, -1],
	[0, -1],
	[1, -1],
	[-1, 0],
	[1, 0],
	[-1, 1],
	[0, 1],
	[1, 1],
] as const;

/** True when a cell and all eight neighbours belong to one enemy country: the
 * claim is a one-pixel hole its owner's enclosure pass is certain to refill. */
export function surroundedByEnemy(
	ownerAt: (x: number, y: number) => number | undefined,
	x: number,
	y: number,
	code: number,
): boolean {
	const owner = ownerAt(x, y);
	if (!owner || owner === code) return false;
	for (const [dx, dy] of RING_STEPS) {
		const nx = x + dx,
			ny = y + dy;
		// Movement wraps, but enclosure treats the map edge as exterior.
		if (nx < 0 || nx >= WIDTH || ny < 0 || ny >= HEIGHT) return false;
		if (ownerAt(nx, ny) !== owner) return false;
	}
	return true;
}

/** Paints implied by confirmed one-cell cardinal moves. Prediction is only
 * used for immediate visual feedback; full country chunks reconcile later.
 * Moves into a pixel fully surrounded by one enemy country predict nothing:
 * the server's enclosure pass will claim it straight back. */
export function movementPaints(
	previous: ReadonlyMap<number, { x: number; y: number }>,
	dots: readonly Dot[],
	land: Uint8Array,
	codeForSlot: (slot: number) => number | undefined,
	ownerAt: (x: number, y: number) => number | undefined,
): MovementPaint[] {
	const paints: MovementPaint[] = [];
	for (const dot of dots) {
		const before = previous.get(dot.slot);
		if (!before) continue;
		let dx = dot.x - before.x;
		if (dx > WIDTH / 2) dx -= WIDTH;
		else if (dx < -WIDTH / 2) dx += WIDTH;
		const dy = dot.y - before.y;
		if (Math.abs(dx) + Math.abs(dy) !== 1) continue;
		const cell = dot.y * WIDTH + dot.x;
		if (!land[cell]) continue;
		const code = codeForSlot(dot.slot);
		if (!code) continue;
		if (surroundedByEnemy(ownerAt, dot.x, dot.y, code)) continue;
		paints.push({ chunk: countryChunkIndex(dot.x, dot.y), cell, code });
	}
	return paints;
}

/** Decode an RLE color-index chunk; rejects any stream that is not exact. */
export function readColorIndexes(bytes: Uint8Array) {
	if (bytes.length % 2 !== 0) throw new Error("Invalid chunk size");
	const codes = new Uint8Array(COUNTRY_CHUNK_CELLS);
	let out = 0;
	for (let i = 0; i < bytes.length; i += 2) {
		const run = bytes[i];
		if (run === 0) throw new Error("Invalid chunk size");
		const code = bytes[i + 1];
		// Battlefield chunks carry many single-cell runs; a fill() call per run
		// costs more than the write itself there. Overflowing writes clamp and
		// the exact-length check below rejects the stream.
		if (run === 1) codes[out++] = code;
		else {
			codes.fill(code, out, out + run);
			out += run;
		}
	}
	if (out !== codes.length) throw new Error("Invalid chunk size");
	return codes;
}

/** Pack the live dots of one user chunk into a coordinate row. */
export function encodeCoordinates(chunkIndex: number, dots: Dot[]): Uint8Array {
	if (
		!Number.isSafeInteger(chunkIndex) ||
		chunkIndex < 0 ||
		chunkIndex >= USER_CHUNK_COUNT
	)
		throw new RangeError("User chunk index is out of range");
	if (dots.length > COORDINATES_MAX_DOTS)
		throw new RangeError("Too many dots for a user chunk");
	const bytes = new Uint8Array(
		COORDINATES_HEADER_BYTES + dots.length * COORDINATES_DOT_BYTES,
	);
	bytes[0] = COORDINATES_VERSION;
	bytes[1] = chunkIndex & 0xff;
	bytes[2] = (chunkIndex >> 8) & 0xff;
	bytes[3] = dots.length & 0xff;
	bytes[4] = (dots.length >> 8) & 0xff;
	const originX = (chunkIndex % USER_COLUMNS) * USER_CHUNK_WIDTH;
	const originY = ((chunkIndex / USER_COLUMNS) | 0) * USER_CHUNK_HEIGHT;
	let at = COORDINATES_HEADER_BYTES;
	for (const dot of dots) {
		const lx = dot.x - originX;
		const ly = dot.y - originY;
		if (
			!Number.isInteger(dot.slot) ||
			dot.slot < 1 ||
			dot.slot > 65535 ||
			lx < 0 ||
			lx >= USER_CHUNK_WIDTH ||
			ly < 0 ||
			ly >= USER_CHUNK_HEIGHT
		)
			throw new RangeError("Dot is outside its user chunk");
		bytes[at] = dot.slot & 0xff;
		bytes[at + 1] = (dot.slot >> 8) & 0xff;
		bytes[at + 2] = lx;
		bytes[at + 3] = ly;
		at += COORDINATES_DOT_BYTES;
	}
	return bytes;
}

/** Validate a packed coordinate row's header and locate its chunk origin. */
function coordinateHeader(bytes: Uint8Array) {
	if (
		bytes.byteLength < COORDINATES_HEADER_BYTES ||
		bytes[0] !== COORDINATES_VERSION
	)
		throw new Error("Invalid coordinates encoding");
	const chunkIndex = bytes[1] | ((bytes[2] as number) << 8);
	if (chunkIndex >= USER_CHUNK_COUNT)
		throw new Error("Invalid coordinates encoding");
	const count = bytes[3] | ((bytes[4] as number) << 8);
	if (bytes.byteLength !== COORDINATES_HEADER_BYTES + count * 4)
		throw new Error("Invalid coordinates encoding");
	return {
		originX: (chunkIndex % USER_COLUMNS) * USER_CHUNK_WIDTH,
		originY: Math.floor(chunkIndex / USER_COLUMNS) * USER_CHUNK_HEIGHT,
		count,
	};
}

/** Decode a packed coordinate row; rejects any stream that is not exact. */
export function readCoordinates(bytes: Uint8Array): Dot[] {
	const { originX, originY, count } = coordinateHeader(bytes);
	const dots: Dot[] = new Array(count);
	let at = COORDINATES_HEADER_BYTES;
	for (let i = 0; i < count; i++) {
		const slot = bytes[at] | ((bytes[at + 1] as number) << 8);
		if (slot < 1) throw new Error("Invalid coordinates encoding");
		const lx = bytes[at + 2] as number;
		const ly = bytes[at + 3] as number;
		if (lx >= USER_CHUNK_WIDTH || ly >= USER_CHUNK_HEIGHT)
			throw new Error("Invalid coordinates encoding");
		dots[i] = {
			slot,
			x: originX + lx,
			y: originY + ly,
		};
		at += 4;
	}
	return dots;
}

/** Find one slot in a packed coordinate row without materializing the dots. */
export function findCoordinate(
	bytes: Uint8Array,
	slot: number,
): Dot | undefined {
	const { originX, originY, count } = coordinateHeader(bytes);
	let at = COORDINATES_HEADER_BYTES;
	for (let i = 0; i < count; i++) {
		const candidate = bytes[at] | ((bytes[at + 1] as number) << 8);
		if (candidate < 1) throw new Error("Invalid coordinates encoding");
		if (candidate === slot) {
			const lx = bytes[at + 2] as number;
			const ly = bytes[at + 3] as number;
			if (lx >= USER_CHUNK_WIDTH || ly >= USER_CHUNK_HEIGHT)
				throw new Error("Invalid coordinates encoding");
			return { slot, x: originX + lx, y: originY + ly };
		}
		at += 4;
	}
	return undefined;
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
