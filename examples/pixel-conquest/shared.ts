import map from "./land.json";

export const WIDTH = map.width;
export const HEIGHT = map.height;
export const CHUNK = 32;
export const COLUMNS = Math.ceil(WIDTH / CHUNK);
export const NAMESPACE = "pixel-conquest";
export const RULES = { tickMs: 50, own: 1, neutral: 2, enemy: 4, crossing: 6 };
export const MAX_PLAYERS = 1024;
export const MAX_COUNTRIES = 64;
export const INPUT_LEASE_MS = 2000;
const COUNTRY_COLORS = [
	"#ef4444",
	"#2588f5",
	"#ffe14a",
	"#a66bff",
	"#31c96a",
	"#ff8a2b",
	"#f46ac1",
	"#35dfdb",
	"#f1eee5",
	"#abc92d",
	"#a65a39",
	"#8eafcf",
	"#bc2458",
	"#3958ba",
	"#d6ac72",
	"#aaf3b1",
	"#7a3685",
	"#008d88",
	"#ffc3b0",
	"#bfb5fa",
];

export function countryColor(code: number) {
	return (
		COUNTRY_COLORS[code - 1] ??
		`hsl(${(code * 137.508) % 360} 95% ${code % 2 ? 78 : 42}%)`
	);
}
export const encoder = new TextEncoder();
export const decoder = new TextDecoder();

export type Direction = "idle" | "up" | "down" | "left" | "right";
export type Dot = {
	id: string;
	code: number;
	x: number;
	y: number;
	seq: number;
	sentAt: number;
	bot?: boolean;
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
	index: number;
	owners: Uint8Array;
	dots: Uint8Array;
	occupied: boolean;
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
	if (typeof value !== "string") throw new Error("Enter a country name");
	const name = value.normalize("NFKC").trim().replace(/\s+/gu, " ");
	if (!name || [...name].length > 24 || /[\p{Cc}\p{Cf}]/u.test(name)) {
		throw new Error("Country names must contain 1–24 visible characters");
	}
	return name;
}
