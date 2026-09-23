import { expect, test } from "bun:test";
import { mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { inflateSync } from "node:zlib";
import {
	archiveRound,
	HISTORY_LIMIT,
	maxHistoryNumber,
	type RoundResult,
	readRoundCursor,
	renderMapPng,
	writeRoundCursor,
} from "./history";
import { LAND_RGB, nextRoundBoundary, WATER_RGB } from "./shared";

const DAY = 24 * 60 * 60 * 1000;

function parsePng(bytes: Uint8Array) {
	const buffer = Buffer.from(bytes);
	expect([...buffer.subarray(0, 8)]).toEqual([
		0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
	]);
	const chunks: { type: string; data: Buffer }[] = [];
	let offset = 8;
	while (offset < buffer.length) {
		const length = buffer.readUInt32BE(offset);
		const type = buffer.toString("latin1", offset + 4, offset + 8);
		chunks.push({
			type,
			data: buffer.subarray(offset + 8, offset + 8 + length),
		});
		offset += 12 + length;
	}
	const header = chunks.find((chunk) => chunk.type === "IHDR");
	if (!header) throw new Error("Missing IHDR");
	const idat = Buffer.concat(
		chunks.filter((chunk) => chunk.type === "IDAT").map((chunk) => chunk.data),
	);
	return {
		width: header.data.readUInt32BE(0),
		height: header.data.readUInt32BE(4),
		colorType: header.data[9],
		raw: inflateSync(idat),
	};
}

function pixel(raw: Buffer, width: number, x: number, y: number) {
	const stride = 1 + width * 3;
	expect(raw[y * stride]).toBe(0);
	const at = y * stride + 1 + x * 3;
	return [raw[at], raw[at + 1], raw[at + 2]];
}

test("round boundaries land on absolute period multiples", () => {
	const period = 3_600_000;
	const thirteenThirtySeven = Date.UTC(2026, 0, 1, 13, 37, 12);
	expect(nextRoundBoundary(thirteenThirtySeven, period)).toBe(
		Date.UTC(2026, 0, 1, 14, 0, 0),
	);
	// Exactly on a boundary always advances to the next one.
	const boundary = Date.UTC(2026, 0, 1, 14, 0, 0);
	expect(nextRoundBoundary(boundary, period)).toBe(
		Date.UTC(2026, 0, 1, 15, 0, 0),
	);
	// A custom period still aligns to epoch multiples.
	expect(nextRoundBoundary(1000, 1000)).toBe(2000);
});

test("map snapshots encode owners over terrain in a valid PNG", () => {
	const width = 4;
	const height = 2;
	const land = new Uint8Array([1, 1, 1, 0, 1, 0, 1, 1]);
	const owners = new Uint16Array(width * height);
	owners[0] = 5;
	owners[1] = 7;
	owners[6] = 7;
	const png = parsePng(
		renderMapPng(
			owners,
			land,
			new Map([
				[5, "#ef4444"],
				[7, "#31c96a"],
			]),
			width,
			height,
		),
	);
	expect([png.width, png.height, png.colorType]).toEqual([width, height, 2]);
	expect(pixel(png.raw, width, 0, 0)).toEqual([0xef, 0x44, 0x44]);
	expect(pixel(png.raw, width, 1, 0)).toEqual([0x31, 0xc9, 0x6a]);
	expect(pixel(png.raw, width, 3, 0)).toEqual([...WATER_RGB]);
	expect(pixel(png.raw, width, 0, 1)).toEqual([...LAND_RGB]);
	expect(pixel(png.raw, width, 1, 1)).toEqual([...WATER_RGB]);
	expect(pixel(png.raw, width, 2, 1)).toEqual([0x31, 0xc9, 0x6a]);
});

test("round cursor round-trips and rejects torn or invalid files", async () => {
	const dir = await mkdtemp(join(tmpdir(), "pixel-history-cursor-"));
	try {
		await writeRoundCursor(dir, { number: 4, startedAt: 10, endsAt: 20 });
		expect(await readRoundCursor(dir)).toEqual({
			number: 4,
			startedAt: 10,
			endsAt: 20,
		});
		await writeFile(join(dir, "round.json"), "{torn");
		expect(await readRoundCursor(dir)).toBeUndefined();
		await writeFile(
			join(dir, "round.json"),
			JSON.stringify({ number: "x", startedAt: 1, endsAt: 2 }),
		);
		expect(await readRoundCursor(dir)).toBeUndefined();
	} finally {
		await rm(dir, { recursive: true, force: true });
	}
});

test("archive keeps the newest rounds and rebuilds the index", async () => {
	const dir = await mkdtemp(join(tmpdir(), "pixel-history-archive-"));
	try {
		const owners = new Uint16Array([1]);
		const land = new Uint8Array([1]);
		for (let number = 1; number <= HISTORY_LIMIT + 5; number++) {
			const result: RoundResult = {
				number,
				startedAt: number * DAY,
				endedAt: number * DAY + 60_000,
				humans: number % 3,
				bots: 10,
				winner: {
					name: `Country ${number}`,
					color: "#ef4444",
					count: number,
					isBot: false,
				},
				countries: [
					{
						name: `Country ${number}`,
						color: "#ef4444",
						count: number,
						isBot: false,
					},
				],
			};
			await archiveRound(
				dir,
				result,
				owners,
				land,
				new Map([[1, "#ef4444"]]),
				1,
				1,
			);
		}
		expect(await maxHistoryNumber(dir)).toBe(HISTORY_LIMIT + 5);
		const files = await readdir(dir);
		expect(files.filter((name) => /^\d+\.json$/.test(name))).toHaveLength(
			HISTORY_LIMIT,
		);
		expect(files).not.toContain("5.json");
		expect(files).toContain(`${HISTORY_LIMIT + 5}.json`);
		expect(files).toContain(`${HISTORY_LIMIT + 5}.png`);
		const index = JSON.parse(await readFile(join(dir, "index.json"), "utf8"));
		expect(index).toHaveLength(HISTORY_LIMIT);
		expect(index[0].number).toBe(HISTORY_LIMIT + 5);
		expect(index[0].winner.name).toBe(`Country ${HISTORY_LIMIT + 5}`);
		expect(index.at(-1).number).toBe(6);
	} finally {
		await rm(dir, { recursive: true, force: true });
	}
});
