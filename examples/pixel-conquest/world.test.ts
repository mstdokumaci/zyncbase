import { expect, test } from "bun:test";
import {
	CHUNK,
	chunkIndex,
	HEIGHT,
	INPUT_LEASE_MS,
	MAX_COUNTRIES,
	MAX_PLAYERS,
	RULES,
	readDots,
	readOwners,
	terrain,
	WIDTH,
} from "./shared";
import { World } from "./world";

test("movement pays destination cost, preserves cooldowns, and survives chunk/restart boundaries", () => {
	const land = new Uint8Array(WIDTH * HEIGHT).fill(1);
	const world = new World(land);
	let now = 0,
		seq = 0;
	const input = (id: string, direction: string, country = id) =>
		world.input(id, { direction, country, seq: ++seq, sentAt: now }, now);
	const ticks = (count: number) => {
		for (let i = 0; i < count; i++) world.tick(++now);
	};
	input("alice", "idle", "North");
	input("bob", "idle", "South");
	input("friend", "idle", " north ");
	const alice = world.players.get("alice");
	const bob = world.players.get("bob");
	if (!alice || !bob) throw new Error("Missing players");
	expect(world.players.get("friend")?.code).toBe(alice.code);
	expect([alice.x, alice.y]).not.toEqual([bob.x, bob.y]);
	alice.x = CHUNK - 1;
	alice.y = 10;
	world.dirtyChunks.clear();
	input("alice", "right");
	ticks(1);
	expect(alice.x).toBe(31);
	input("alice", "idle");
	ticks(10);
	expect(alice.x).toBe(31);
	input("alice", "right");
	ticks(1);
	expect(alice.x).toBe(32);
	expect(world.dirtyChunks.has(chunkIndex(31, 10))).toBe(true);
	expect(world.dirtyChunks.has(chunkIndex(32, 10))).toBe(true);
	expect(world.owners[10 * WIDTH + 32]).toBe(alice.code);

	world.owners[10 * WIDTH + 31] = alice.code;
	const north = world.countries.get(alice.code),
		south = world.countries.get(bob.code);
	if (!north || !south) throw new Error("Missing countries");
	north.count++;
	input("alice", "left");
	ticks(RULES.own);
	expect(alice.x).toBe(31);
	input("alice", "right");
	ticks(RULES.own);
	expect(alice.x).toBe(32);
	world.owners[10 * WIDTH + 33] = bob.code;
	south.count++;
	ticks(RULES.enemy - 1);
	expect(alice.x).toBe(32);
	ticks(1);
	expect(alice.x).toBe(33);
	expect(south.count).toBe(0);

	land[10 * WIDTH + 34] = 0;
	ticks(RULES.neutral + RULES.crossing - 1);
	expect(alice.x).toBe(33);
	ticks(1);
	expect(alice.x).toBe(34);
	expect(world.owners[10 * WIDTH + 34]).toBe(0);
	ticks(RULES.neutral + RULES.crossing);
	expect(alice.x).toBe(35);
	const saved = [...world.dirtyChunks].map((index) => world.chunk(index));
	const restored = new World(land);
	restored.restore([...world.countries.values()], saved);
	expect(restored.players.size).toBe(0);
	expect(restored.owners[10 * WIDTH + 35]).toBe(alice.code);
	expect(restored.countries.get(alice.code)?.count).toBe(north.count);
	for (const index of restored.dirtyChunks)
		expect(readDots(restored.chunk(index).dots)).toEqual([]);
	expect(readOwners(world.chunk(chunkIndex(32, 10)).owners)[10 * CHUNK]).toBe(
		alice.code,
	);
	world.remove("alice");
	expect(world.owners[10 * WIDTH + 35]).toBe(alice.code);
	expect(
		readDots(world.chunk(chunkIndex(35, 10)).dots).some(
			(dot) => dot.id === "alice",
		),
	).toBe(false);
});

test("bots share five countries, obey movement costs, and yield to humans without clearing land", () => {
	const world = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	world.startBots(0);
	expect(world.players.size).toBe(10);
	expect(world.countries.size).toBe(5);
	for (const country of world.countries.values())
		expect(
			[...world.players.values()].filter(
				(player) => player.code === country.code,
			),
		).toHaveLength(2);
	const bot = world.players.get("bot:0");
	const retiring = world.players.get("bot:9");
	if (!bot || !retiring) throw new Error("Missing bots");
	bot.x = 100;
	bot.y = 100;
	world.tick(INPUT_LEASE_MS * 10);
	expect([bot.x, bot.y]).toEqual([100, 100]);
	expect(world.players.size).toBe(10);
	const now = INPUT_LEASE_MS * 10 + 1;
	const join = (i: number) =>
		world.input(
			`human:${i}`,
			{ country: "Humans", direction: "idle", seq: 1, sentAt: now },
			now,
		);
	join(0);
	world.tick(now);
	expect(world.players.size).toBe(11);
	expect([bot.x, bot.y]).toEqual([100, 100]);
	world.tick(now + 1);
	expect(Math.abs(bot.x - 100) + Math.abs(bot.y - 100)).toBe(1);
	expect(world.owners[bot.y * WIDTH + bot.x]).toBe(bot.code);

	world.owners[0] = retiring.code;
	join(1);
	world.tick(now + 2);
	expect(world.humanCount).toBe(2);
	expect(world.players.has("bot:9")).toBe(false);
	expect(world.players.size).toBe(11);
	expect(world.owners[0]).toBe(retiring.code);
	world.remove("human:1");
	world.tick(now + 3);
	expect(world.players.get("bot:9")?.code).toBe(retiring.code);
	expect(world.countries.size).toBe(6);
	for (let i = 1; i < MAX_PLAYERS + 1; i++) join(i);
	world.tick(now + 4);
	expect(world.humanCount).toBe(MAX_PLAYERS);
	expect([...world.players.values()].some((player) => player.bot)).toBe(false);
	world.tick(now + INPUT_LEASE_MS * 6);
	expect(world.humanCount).toBe(0);
	expect(world.players.size).toBe(10);
	expect(
		readDots(world.chunk(chunkIndex(933, 276)).dots).every((dot) => dot.bot),
	).toBe(true);
});

test("input validation, borders, and expired input stop movement; map mask is deterministic", () => {
	const land = terrain();
	expect(land.reduce((sum, cell) => sum + cell, 0)).toBe(661568);
	const world = new World(land);
	const data = { direction: "right", country: "Test", seq: 1, sentAt: 0 };
	world.input("invalid", { ...data, direction: "__proto__" }, 0);
	world.input("invalid", { ...data, country: "\u0000" }, 0);
	expect(world.players.size).toBe(0);
	world.input("valid", data, 0);
	const player = world.players.get("valid");
	if (!player) throw new Error("Player missing");
	const start = [player.x, player.y];
	world.tick(INPUT_LEASE_MS + 1);
	expect([player.x, player.y]).toEqual(start);
	world.input("valid", { ...data, seq: 2 }, INPUT_LEASE_MS + 2);
	player.x = WIDTH - 1;
	world.tick(INPUT_LEASE_MS + 3);
	expect(player.x).toBe(WIDTH - 1);
	world.tick(INPUT_LEASE_MS * 7);
	expect(world.players.size).toBe(0);
});

test("country creation stops at 64 live countries and freed names are reusable", () => {
	const land = new Uint8Array(WIDTH * HEIGHT).fill(1);
	const world = new World(land);
	const now = 0;
	const enter = (id: string, country: string) =>
		world.input(id, { direction: "idle", country, seq: 1, sentAt: now }, now);
	for (let i = 0; i < MAX_COUNTRIES; i++) enter(`founder:${i}`, `Nation ${i}`);
	expect(world.countries.size).toBe(MAX_COUNTRIES);
	enter("late", "Newcomer");
	expect(world.players.has("late")).toBe(false);
	expect(world.countries.size).toBe(MAX_COUNTRIES);
	enter("ally", "Nation 0");
	expect(world.players.has("ally")).toBe(true);
	expect(world.countries.size).toBe(MAX_COUNTRIES);
	// Nation 0 still has a live holder, so removing one of two holders keeps it.
	world.remove("founder:0");
	expect(world.countries.size).toBe(MAX_COUNTRIES);
	// The last holder leaves a zero-land country: the slot is reclaimed.
	const holder = world.players.get("ally");
	if (!holder) throw new Error("Holder missing");
	const freed = holder.code;
	world.remove("ally");
	expect(world.countries.has(freed)).toBe(false);
	expect(world.countries.size).toBe(MAX_COUNTRIES - 1);
	expect(world.dirtyRemovedCountries).toEqual(new Set([freed]));
	// The freed name founds a fresh country with a never-reused code.
	enter("reborn", "Nation 0");
	const reborn = world.players.get("reborn");
	if (!reborn) throw new Error("Rejoin missing");
	expect(reborn.code).not.toBe(freed);
	expect(world.countries.size).toBe(MAX_COUNTRIES);
	enter("too-late", "Another");
	expect(world.players.has("too-late")).toBe(false);
});

test("capturing the last cell deletes only abandoned countries", () => {
	const land = new Uint8Array(WIDTH * HEIGHT).fill(1);
	const world = new World(land);
	let now = 0;
	world.input(
		"a",
		{ direction: "idle", country: "Alpha", seq: 1, sentAt: now },
		now,
	);
	world.input(
		"b",
		{ direction: "idle", country: "Beta", seq: 1, sentAt: now },
		now,
	);
	const a = world.players.get("a");
	const b = world.players.get("b");
	if (!a || !b) throw new Error("Missing players");
	b.x = 100;
	b.y = 100;
	const cell = 100 * WIDTH + 101;
	world.owners[cell] = a.code;
	const alpha = world.countries.get(a.code);
	if (!alpha) throw new Error("Alpha missing");
	alpha.count = 1;
	world.input(
		"b",
		{ direction: "right", country: "Beta", seq: 2, sentAt: now },
		now,
	);
	for (let i = 0; i < RULES.enemy; i++) world.tick(++now);
	expect([b.x, b.y]).toEqual([101, 100]);
	expect(world.countries.get(a.code)?.count).toBe(0);
	// a still roams, so landless Alpha survives.
	expect(world.countries.has(a.code)).toBe(true);
	expect(world.dirtyRemovedCountries.size).toBe(0);
	world.remove("a");
	expect(world.countries.has(a.code)).toBe(false);
	expect(world.dirtyRemovedCountries.has(a.code)).toBe(true);
});

test("restart prunes abandoned zero-land countries and keeps codes monotonic", () => {
	const land = new Uint8Array(WIDTH * HEIGHT).fill(1);
	const src = new World(land);
	let now = 0;
	src.input(
		"f",
		{ direction: "right", country: "Keep", seq: 1, sentAt: now },
		now,
	);
	for (let i = 0; i < RULES.neutral; i++) src.tick(++now);
	const keep = src.players.get("f");
	if (!keep) throw new Error("Founder missing");
	expect(src.countries.get(keep.code)?.count).toBe(1);
	const chunks = [...src.dirtyChunks].map((index) => src.chunk(index));
	const rows = [...src.countries.values()];
	rows.push({
		id: "999",
		code: 999,
		name: "Ghost",
		color: "#ffffff",
		count: 0,
	});
	const dst = new World(land.slice());
	dst.restore(rows, chunks);
	expect(dst.countries.has(999)).toBe(false);
	expect(dst.dirtyRemovedCountries.has(999)).toBe(true);
	expect(dst.countries.get(keep.code)?.count).toBe(1);
	dst.input(
		"n",
		{ direction: "idle", country: "Fresh", seq: 1, sentAt: now },
		now,
	);
	expect(dst.players.get("n")?.code).toBe(keep.code + 1);
});
