import {
	mkdir,
	readdir,
	readFile,
	rename,
	unlink,
	writeFile,
} from "node:fs/promises";
import { join } from "node:path";
import { crc32, deflateSync } from "node:zlib";
import { LAND_RGB, type RoundCursor, WATER_RGB } from "./shared";

export const HISTORY_LIMIT = 20;
const CURSOR_FILE = "round.json";
const INDEX_FILE = "index.json";

export type RoundStanding = {
	name: string;
	color: string;
	count: number;
	isBot: boolean;
};
export type RoundResult = {
	number: number;
	startedAt: number | null;
	endedAt: number;
	humans: number;
	bots: number;
	winner: RoundStanding | null;
	countries: RoundStanding[];
};
export type HistoryEntry = {
	number: number;
	endedAt: number;
	humans: number;
	winner: { name: string; color: string } | null;
};

export async function readRoundCursor(
	dataDir: string,
): Promise<RoundCursor | undefined> {
	try {
		const value: unknown = JSON.parse(
			await readFile(join(dataDir, CURSOR_FILE), "utf8"),
		);
		if (!isRoundInfo(value)) return undefined;
		return value;
	} catch {
		// A missing or torn cursor is treated as an expired round at boot.
		return undefined;
	}
}

export async function writeRoundCursor(dataDir: string, cursor: RoundCursor) {
	await writeAtomic(join(dataDir, CURSOR_FILE), JSON.stringify(cursor));
}

function isRoundInfo(value: unknown): value is RoundCursor {
	if (!value || typeof value !== "object") return false;
	const { number, startedAt, endsAt } = value as Record<string, unknown>;
	return (
		Number.isSafeInteger(number) &&
		Number(number) >= 1 &&
		Number.isSafeInteger(startedAt) &&
		Number(startedAt) >= 0 &&
		Number.isSafeInteger(endsAt) &&
		Number(endsAt) >= 0
	);
}

/** Highest archived round number; 0 when nothing has been archived yet. */
export async function maxHistoryNumber(historyDir: string) {
	let max = 0;
	try {
		for (const name of await readdir(historyDir)) {
			const match = /^(\d+)\.json$/.exec(name);
			if (match) max = Math.max(max, Number(match[1]));
		}
	} catch {
		// A missing directory means no history yet.
	}
	return max;
}

export async function archiveRound(
	historyDir: string,
	result: RoundResult,
	owners: Uint16Array,
	land: Uint8Array,
	colors: Map<number, string>,
	width: number,
	height: number,
) {
	await mkdir(historyDir, { recursive: true });
	await writeAtomic(
		join(historyDir, `${result.number}.json`),
		JSON.stringify(result),
	);
	await writeAtomic(
		join(historyDir, `${result.number}.png`),
		renderMapPng(owners, land, colors, width, height),
	);
	await pruneHistory(historyDir);
	await writeHistoryIndex(historyDir);
}

export async function pruneHistory(
	historyDir: string,
	keep = HISTORY_LIMIT,
): Promise<number> {
	let names: string[];
	try {
		names = await readdir(historyDir);
	} catch {
		return 0;
	}
	const numbers = names
		.map((name) => /^(\d+)\.json$/.exec(name)?.[1])
		.filter((value): value is string => value !== undefined)
		.map(Number)
		.sort((a, b) => b - a);
	let removed = 0;
	for (const number of numbers.slice(keep)) {
		for (const name of [`${number}.json`, `${number}.png`]) {
			try {
				await unlink(join(historyDir, name));
				removed++;
			} catch {
				// Already gone; pruning is best effort.
			}
		}
	}
	return removed;
}

async function writeHistoryIndex(historyDir: string) {
	const entries: HistoryEntry[] = [];
	for (const name of await readdir(historyDir)) {
		if (!/^\d+\.json$/.test(name)) continue;
		try {
			const result = JSON.parse(
				await readFile(join(historyDir, name), "utf8"),
			) as RoundResult;
			entries.push({
				number: result.number,
				endedAt: result.endedAt,
				humans: result.humans,
				winner: result.winner
					? { name: result.winner.name, color: result.winner.color }
					: null,
			});
		} catch {
			// A torn round file is skipped rather than breaking the index.
		}
	}
	entries.sort((a, b) => b.number - a.number);
	await writeAtomic(
		join(historyDir, INDEX_FILE),
		JSON.stringify(entries.slice(0, HISTORY_LIMIT)),
	);
}

async function writeAtomic(path: string, data: string | Uint8Array) {
	const tmp = `${path}.tmp`;
	await writeFile(tmp, data);
	await rename(tmp, path);
}

/** Full-map snapshot; owner codes win over terrain and unknown codes fall back. */
export function renderMapPng(
	owners: Uint16Array,
	land: Uint8Array,
	colors: Map<number, string>,
	width: number,
	height: number,
): Uint8Array {
	const stride = 1 + width * 3;
	const raw = Buffer.alloc(height * stride);
	const palette = new Map<number, readonly number[]>();
	const colorOf = (cell: number): readonly number[] => {
		const owner = owners[cell];
		if (!owner) return land[cell] ? LAND_RGB : WATER_RGB;
		let rgb = palette.get(owner);
		if (!rgb) {
			rgb = parseColor(colors.get(owner));
			palette.set(owner, rgb);
		}
		return rgb;
	};
	for (let y = 0; y < height; y++) {
		const row = y * stride;
		raw[row] = 0;
		for (let x = 0; x < width; x++) {
			const rgb = colorOf(y * width + x);
			const at = row + 1 + x * 3;
			raw[at] = rgb[0] as number;
			raw[at + 1] = rgb[1] as number;
			raw[at + 2] = rgb[2] as number;
		}
	}
	const header = Buffer.alloc(13);
	header.writeUInt32BE(width, 0);
	header.writeUInt32BE(height, 4);
	header[8] = 8;
	header[9] = 2;
	return Buffer.concat([
		Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
		pngChunk("IHDR", header),
		pngChunk("IDAT", deflateSync(raw)),
		pngChunk("IEND", Buffer.alloc(0)),
	]);
}

function pngChunk(type: string, data: Uint8Array) {
	const head = Buffer.alloc(8);
	head.writeUInt32BE(data.length, 0);
	head.write(type, 4, "latin1");
	const checksum = Buffer.alloc(4);
	checksum.writeUInt32BE(
		(crc32 as (value: Uint8Array) => number)(
			Buffer.concat([head.subarray(4), data]),
		) >>> 0,
		0,
	);
	return Buffer.concat([head, data, checksum]);
}

function parseColor(hex: string | undefined): readonly number[] {
	if (!hex || !/^#[0-9a-f]{6}$/i.test(hex)) return LAND_RGB;
	return [
		Number.parseInt(hex.slice(1, 3), 16),
		Number.parseInt(hex.slice(3, 5), 16),
		Number.parseInt(hex.slice(5, 7), 16),
	];
}
