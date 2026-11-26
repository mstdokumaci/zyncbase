import * as fs from "node:fs";
import * as path from "node:path";
import { decode } from "@msgpack/msgpack";

type Captured = { dir: "c2s" | "s2c"; bytes: string };

const root = path.resolve(import.meta.dir, "../..");
const rawDir = path.join(root, "benchmark/corpus/raw");
const outPath = path.join(root, "benchmark/corpus/combo.json");

function get(value: unknown, key: string): unknown {
	if (value instanceof Map) return value.get(key);
	if (value && typeof value === "object") {
		return (value as Record<string, unknown>)[key];
	}
	return undefined;
}

function typeOf(value: unknown): number | undefined {
	const type = get(value, "type");
	return typeof type === "number" ? type : undefined;
}

function sparseMap(value: unknown): Map<number, unknown> {
	const map = new Map<number, unknown>();
	if (!Array.isArray(value)) return map;
	for (let i = 0; i + 1 < value.length; i += 2) {
		const key = value[i];
		if (typeof key === "number") map.set(key, value[i + 1]);
	}
	return map;
}

function readCaptured(): Captured[][] {
	const files: Captured[][] = [];
	for (const name of fs.readdirSync(rawDir)) {
		if (!name.endsWith(".ndjson")) continue;
		const frames: Captured[] = [];
		for (const line of fs
			.readFileSync(path.join(rawDir, name), "utf8")
			.split("\n")) {
			if (line.length > 0) frames.push(JSON.parse(line) as Captured);
		}
		files.push(frames);
	}
	return files;
}

const files = readCaptured();
let schemaSync: string | null = null;
let storeNamespace: string | null = null;
let presenceSubscribe: string | null = null;
let presenceSubscribeShared: string | null = null;
const storeSubscribes: Record<string, Record<"A" | "B", string>> = {
	items: { A: "", B: "" },
	events: { A: "", B: "" },
};
const presenceNamespaces: Record<string, string> = {};
const storeCreates: Record<string, string> = {};
const storeUpdates: Record<string, string> = {};
const presenceUser: Record<string, string[]> = {};
const presenceShared: Record<string, string[]> = {};

for (const frames of files) {
	const userFrames: Captured[] = [];

	for (const frame of frames) {
		if (frame.dir === "s2c") {
			schemaSync ??= frame.bytes;
			continue;
		}
		const bytes = new Uint8Array(Buffer.from(frame.bytes, "base64"));
		let message: unknown;
		try {
			message = decode(bytes);
		} catch {
			continue;
		}
		switch (typeOf(message)) {
			case 0x10:
				storeNamespace ??= frame.bytes;
				break;
			case 0x15: {
				const table = get(message, "table_index");
				const filterB = get(message, "orConditions");
				const name = table === 1 ? "items" : table === 2 ? "events" : undefined;
				if (!name) break;
				const filter = Array.isArray(filterB) && filterB.length > 0 ? "B" : "A";
				storeSubscribes[name][filter] = frame.bytes;
				break;
			}
			case 0x20: {
				const namespace = get(message, "namespace");
				if (typeof namespace !== "string") break;
				const match = /presence-combo-room-([01])$/.exec(namespace);
				if (match) presenceNamespaces[match[1]] = frame.bytes;
				break;
			}
			case 0x23:
				presenceSubscribe ??= frame.bytes;
				break;
			case 0x25:
				presenceSubscribeShared ??= frame.bytes;
				break;
			case 0x11: {
				const pathValue = get(message, "path");
				const value = get(message, "value");
				if (!Array.isArray(pathValue) || !Array.isArray(value)) break;
				const fields = sparseMap(value);
				const text = [...fields.values()].find(
					(item): item is string => typeof item === "string",
				);
				if (!text) break;
				const updated = text.startsWith("updated-");
				const idMatch = /^(?:updated-)?(?:item|event)-(\d+)$/.exec(text);
				if (!idMatch) break;
				const n = Number(idMatch[1]);
				const processIndex = Math.floor(n / 100);
				const index = n % 100;
				if (processIndex < 0 || processIndex >= 4 || index >= 100) break;
				const key = `${processIndex}:${index}`;
				if (updated) storeUpdates[key] = frame.bytes;
				else storeCreates[key] = frame.bytes;
				break;
			}
			case 0x21:
				userFrames.push(frame);
				break;
			case 0x22: {
				const data = get(message, "data");
				const fields = sparseMap(data);
				const slide = fields.get(0);
				if (typeof slide !== "number") break;
				const room = Math.floor(slide / 100);
				const tick = slide % 100;
				if (room !== 0 && room !== 1) break;
				let list = presenceShared[String(room)];
				if (!list) {
					list = [];
					presenceShared[String(room)] = list;
				}
				list[tick] = frame.bytes;
				break;
			}
		}
	}

	if (userFrames.length !== 300) {
		throw new Error(
			`combo corpus: expected 300 presence-user frames per process, got ${userFrames.length}`,
		);
	}
	for (let i = 0; i < 100; i++) {
		const first = decode(
			new Uint8Array(Buffer.from(userFrames[i].bytes, "base64")),
		);
		const fields = sparseMap(get(first, "data"));
		const id = fields.get(0);
		const tick = fields.get(1);
		if (typeof id !== "number" || tick !== 0) {
			throw new Error(`combo corpus: presence user frame ${i} has no id/tick0`);
		}
		let ticks = presenceUser[String(id)];
		if (!ticks) {
			ticks = [];
			presenceUser[String(id)] = ticks;
		}
		ticks[0] = userFrames[i].bytes;
		ticks[1] = userFrames[100 + i].bytes;
		ticks[2] = userFrames[200 + i].bytes;
	}
}

function requireFrame(value: string | null | undefined, label: string): string {
	if (!value) throw new Error(`combo corpus: missing ${label}`);
	return value;
}

for (const table of ["items", "events"] as const) {
	for (const filter of ["A", "B"] as const) {
		requireFrame(storeSubscribes[table][filter], `${table} filter ${filter}`);
	}
}
if (!presenceNamespaces["0"] || !presenceNamespaces["1"]) {
	throw new Error("combo corpus: missing presence namespace for a room");
}
const userIds = Object.keys(presenceUser);
if (userIds.length !== 400) {
	throw new Error(
		`combo corpus: expected 400 presence users, got ${userIds.length}`,
	);
}
for (const [id, ticks] of Object.entries(presenceUser)) {
	if (ticks.length !== 3 || ticks.some((frame) => !frame)) {
		throw new Error(`combo corpus: presence user ${id} has incomplete ticks`);
	}
}
for (const room of ["0", "1"]) {
	const ticks = presenceShared[room];
	if (!ticks || ticks.length !== 3 || ticks.some((frame) => !frame)) {
		throw new Error(`combo corpus: shared room ${room} has incomplete ticks`);
	}
}
if (Object.keys(storeCreates).length !== 400) {
	throw new Error(
		`combo corpus: expected 400 store creates, got ${Object.keys(storeCreates).length}`,
	);
}
if (Object.keys(storeUpdates).length !== 400) {
	throw new Error(
		`combo corpus: expected 400 store updates, got ${Object.keys(storeUpdates).length}`,
	);
}

const corpus = {
	schemaSync: requireFrame(schemaSync, "SchemaSync"),
	setup: {
		storeNamespace: requireFrame(storeNamespace, "StoreSetNamespace"),
		storeSubscribes,
		presenceNamespaces,
		presenceSubscribe: requireFrame(presenceSubscribe, "PresenceSubscribe"),
		presenceSubscribeShared: requireFrame(
			presenceSubscribeShared,
			"PresenceSubscribeShared",
		),
	},
	storeCreates,
	storeUpdates,
	presenceUser,
	presenceShared,
};

fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, JSON.stringify(corpus));

console.log(
	`combo corpus: ${Object.keys(storeCreates).length} creates, ` +
		`${Object.keys(storeUpdates).length} updates, ` +
		`${userIds.length} presence users ×3 ticks, shared 2 rooms ×3, ` +
		`filters A/B for items+events -> ${outPath}`,
);
