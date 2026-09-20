import { expect, test } from "bun:test";
import { planBot } from "./bots";
import { buildPublishOperations, drainPublishState } from "./publish";
import {
	CHUNK,
	COUNTRY_COLORS,
	chunkIndex,
	HEIGHT,
	INPUT_LEASE_MS,
	MAX_COUNTRIES,
	PLAYER_GRACE_MS,
	playerName,
	RULES,
	readDots,
	readOwners,
	terrain,
	WIDTH,
} from "./shared";
import { World } from "./world";

/** Bots spawn with a point's first human, so tests admit one first. */
function joinHuman(world: World, id: string) {
	world.input(
		id,
		{
			name: id,
			country_id: world.country("Humans")?.country_id,
			direction: "idle",
			seq: 1,
		},
		0,
	);
	return world.players.get(id);
}

test("movement pays destination cost, preserves cooldowns, and survives chunk/restart boundaries", () => {
	const land = new Uint8Array(WIDTH * HEIGHT).fill(1);
	const world = new World(land);
	let now = 0,
		seq = 0;
	const input = (id: string, direction: string, country = id) =>
		world.input(
			id,
			{
				name: id,
				direction,
				country_id:
					world.players.get(id)?.country_id ??
					world.country(country)?.country_id,
				seq: ++seq,
			},
			now,
		);
	const ticks = (count: number) => {
		for (let i = 0; i < count; i++) world.tick(++now);
	};
	input("alice", "idle", "North");
	input("bob", "idle", "South");
	input("friend", "idle", " north ");
	const alice = world.players.get("alice");
	const bob = world.players.get("bob");
	if (!alice || !bob) throw new Error("Missing players");
	expect(world.players.get("friend")?.country_id).toBe(alice.country_id);
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
	expect(world.owners[10 * WIDTH + 32]).toBe(alice.country_id);

	world.owners[10 * WIDTH + 31] = alice.country_id;
	const north = world.countries.get(alice.country_id),
		south = world.countries.get(bob.country_id);
	if (!north || !south) throw new Error("Missing countries");
	north.count++;
	input("alice", "left");
	ticks(RULES.own);
	expect(alice.x).toBe(31);
	input("alice", "right");
	ticks(RULES.own);
	expect(alice.x).toBe(32);
	world.owners[10 * WIDTH + 33] = bob.country_id;
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
	expect(restored.owners[10 * WIDTH + 35]).toBe(alice.country_id);
	expect(restored.countries.get(alice.country_id)?.count).toBe(north.count);
	for (const index of restored.dirtyChunks)
		expect(readDots(restored.chunk(index).dots)).toEqual([]);
	expect(readOwners(world.chunk(chunkIndex(32, 10)).owners)[10 * CHUNK]).toBe(
		COUNTRY_COLORS.indexOf(north.color) + 1,
	);
	world.remove("alice", now);
	expect(world.owners[10 * WIDTH + 35]).toBe(alice.country_id);
	expect(
		readDots(world.chunk(chunkIndex(35, 10)).dots).some(
			(dot) => dot.player_id === "alice",
		),
	).toBe(false);
});

test("owner bitmaps pass byte-per-cell and reject any other size", () => {
	const bytes = new Uint8Array(CHUNK * CHUNK);
	for (let i = 0; i < bytes.length; i++) bytes[i] = i % (MAX_COUNTRIES + 1);
	expect(readOwners(bytes)).toBe(bytes);
	expect(() => readOwners(new Uint8Array(CHUNK * CHUNK * 2))).toThrow(
		"Invalid chunk size",
	);
});

test("bots join a point's first human, thin out as it crowds, and return when it empties", () => {
	const world = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	world.startBots(0);
	expect(world.players.size).toBe(0);
	expect(world.countries.size).toBe(0);
	let now = INPUT_LEASE_MS * 10;
	const join = (id: string) =>
		world.input(
			id,
			{
				name: id,
				country_id: world.country("Humans")?.country_id,
				direction: "idle",
				seq: 1,
			},
			now,
		);
	const bots = () =>
		[...world.players.values()].filter((player) => player.is_bot);
	// The first human at the point brings both of its bots, sharing one bot
	// country that is not the human's.
	join("one");
	world.tick(now);
	const first = world.players.get("one");
	expect(bots()).toHaveLength(2);
	expect(world.countries.size).toBe(2);
	expect(bots()[0]?.country_id).toBe(bots()[1]?.country_id);
	expect(bots()[0]?.country_id).not.toBe(first?.country_id);
	// The pair joins like same-country reinforcements: the first bot settles
	// at the nearest legal cross-country distance, the second beside it.
	const [left, right] = bots();
	if (!first || !left || !right) throw new Error("Missing bots");
	expect(
		Math.max(
			Math.hypot(left.x - first.x, left.y - first.y),
			Math.hypot(right.x - first.x, right.y - first.y),
		),
	).toBeLessThan(64);
	expect(Math.hypot(left.x - right.x, left.y - right.y)).toBeLessThan(48);
	// Bots move and claim land once a human is around.
	const bot = world.players.get("bot-0");
	if (!bot) throw new Error("Missing bot");
	bot.x = 100;
	bot.y = 100;
	world.tick(++now);
	expect(Math.abs(bot.x - 100) + Math.abs(bot.y - 100)).toBe(1);
	expect(world.owners[bot.y * WIDTH + bot.x]).toBe(bot.country_id);
	// Teammates inherit the point: two or three humans leave one bot, a
	// fourth retires it without clearing its land.
	join("two");
	world.tick(++now);
	expect(bots()).toHaveLength(1);
	join("three");
	world.tick(++now);
	expect(bots()).toHaveLength(1);
	join("four");
	world.tick(++now);
	expect(bots()).toHaveLength(0);
	const botCountry = world.countries.get(bot.country_id);
	if (!botCountry) throw new Error("Missing bot country");
	expect(botCountry.count).toBeGreaterThan(0);
	expect(world.owners[bot.y * WIDTH + bot.x]).toBe(bot.country_id);
	// Leaving crowds bots return, and an empty point holds none.
	world.remove("four", now);
	world.tick(++now);
	expect(bots()).toHaveLength(1);
	// With no live teammate, the shared chain drops the returning bot on its
	// country's own land instead of back at the spawn point.
	const returned = bots()[0];
	if (!returned) throw new Error("Missing returned bot");
	expect(world.owners[returned.y * WIDTH + returned.x]).toBe(bot.country_id);
	expect(Math.hypot(returned.x - bot.x, returned.y - bot.y)).toBeLessThan(64);
	world.remove("three", now);
	world.tick(++now);
	expect(bots()).toHaveLength(1);
	world.remove("two", now);
	world.tick(++now);
	expect(bots()).toHaveLength(2);
	world.remove("one", now);
	world.tick(++now);
	expect(bots()).toHaveLength(0);
});

test("spawn points unlock in waves as earlier points fill", () => {
	const world = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	world.startBots(0);
	const join = (id: string) => {
		world.input(
			id,
			{
				name: id,
				country_id: world.country(id)?.country_id,
				direction: "idle",
				seq: 1,
			},
			0,
		);
		return world.players.get(id);
	};
	// The first three founders claim one early point each.
	expect([0, 1, 2].map((i) => join(`f:${i}`)?.point)).toEqual([0, 1, 2]);
	// A fourth point appears only after the first three are in use.
	expect(join("f:3")?.point).toBe(3);
	for (let i = 4; i < 24; i++) join(`f:${i}`);
	// All six wave-2 points hold four humans, so the next founder reaches the
	// third wave: Yulara in Australia.
	expect(join("f:24")?.point).toBe(6);
});

test("a bot boxed in by its own territory roams out instead of idling", () => {
	const world = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	world.startBots(0);
	joinHuman(world, "human:0");
	world.tick(0);
	const bot = world.players.get("bot-0");
	if (!bot) throw new Error("Missing bot");
	const start = { x: bot.x, y: bot.y };
	// Wider than planBot's ±4 patch window at the largest square size, so
	// every candidate patch is already this country's land.
	for (let y = bot.y - 80; y <= bot.y + 80; y++)
		for (let x = bot.x - 80; x <= bot.x + 80; x++)
			world.owners[y * WIDTH + x] = bot.country_id;
	expect(planBot(world, bot)).toBeUndefined();
	for (
		let tick = 0;
		tick < 40 && bot.x === start.x && bot.y === start.y;
		tick++
	)
		world.tick(tick + 1);
	expect([bot.x, bot.y]).not.toEqual([start.x, start.y]);
});

test("a bot captured in enemy land flees instead of painting there", () => {
	const world = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	world.startBots(0);
	joinHuman(world, "human:0");
	world.tick(0);
	const bot = world.players.get("bot-0");
	const enemy = world.country("Enemy");
	if (!bot || !enemy) throw new Error("Missing bot or enemy");
	const start = { x: bot.x, y: bot.y };
	for (let y = bot.y - 20; y <= bot.y + 20; y++)
		for (let x = bot.x - 20; x <= bot.x + 20; x++)
			world.owners[y * WIDTH + x] = enemy.country_id;
	// The normal planner still sees gain here; only the flee check gets out.
	expect(planBot(world, bot)).toBeDefined();
	const escaped = () =>
		Math.abs(bot.x - start.x) > 20 || Math.abs(bot.y - start.y) > 20;
	for (let tick = 0; tick < 200 && !escaped(); tick++) world.tick(tick + 1);
	expect(escaped()).toBe(true);
});

test("a planned step across the seam steers the short way", () => {
	const world = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	world.startBots(0);
	joinHuman(world, "human:0");
	world.tick(0);
	const bot = world.players.get("bot-0");
	if (!bot) throw new Error("Missing bot");
	const row = 100;
	// Own the destination so one tick pays the own-territory move cost, and use
	// a plan without `roam` so the steering check sees it before think() does.
	const cross = (from: number, to: number, now: number) => {
		world.owners[row * WIDTH + to] = bot.country_id;
		bot.x = from;
		bot.y = row;
		bot.credit = 0;
		bot.plan = { patch: -1, cells: [row * WIDTH + to] };
		world.tick(now);
		expect([bot.x, bot.y]).toEqual([to, row]);
	};
	cross(0, WIDTH - 1, 1);
	cross(WIDTH - 1, 0, 2);
});

test("input validation, borders, and expired input stop movement; map mask is deterministic", () => {
	const land = terrain();
	expect(land.reduce((sum, cell) => sum + cell, 0)).toBe(661453);
	// The seam columns are water, so no owned wall can wrap and the planar
	// enclosure logic stays valid.
	for (let y = 0; y < HEIGHT; y++)
		expect(land[y * WIDTH] + land[y * WIDTH + WIDTH - 1]).toBeLessThan(2);
	const world = new World(land);
	const data = {
		name: "Player",
		direction: "right",
		country_id: world.country("Test")?.country_id,
		seq: 1,
	};
	world.input("invalid", { ...data, direction: "__proto__" }, 0);
	world.input("invalid", { ...data, country_id: 999 }, 0);
	expect(() => world.country("\u0000")).toThrow();
	expect(world.players.size).toBe(0);
	world.input("valid", data, 0);
	const player = world.players.get("valid");
	if (!player) throw new Error("Player missing");
	const start = [player.x, player.y];
	world.tick(INPUT_LEASE_MS + 1);
	expect([player.x, player.y]).toEqual(start);
	world.input("valid", { ...data, seq: 2 }, INPUT_LEASE_MS + 2);
	// Horizontal movement wraps across the water seam: 1999 -> 0 costs a
	// neutral crossing. One tick banks credit, the next moves.
	player.x = WIDTH - 1;
	player.y = 0;
	world.tick(INPUT_LEASE_MS + 3);
	expect(player.x).toBe(WIDTH - 1);
	world.tick(INPUT_LEASE_MS + 4);
	expect(player.x).toBe(0);
	// Vertical edges still block movement.
	player.y = HEIGHT - 1;
	world.input(
		"valid",
		{ ...data, direction: "down", seq: 3 },
		INPUT_LEASE_MS + 5,
	);
	world.tick(INPUT_LEASE_MS + 6);
	expect(player.y).toBe(HEIGHT - 1);
	world.tick(INPUT_LEASE_MS * 7);
	expect(world.players.size).toBe(0);
});

test("country creation stops at 64 live countries and freed names are reusable", () => {
	expect(COUNTRY_COLORS).toHaveLength(MAX_COUNTRIES);
	expect(new Set(COUNTRY_COLORS).size).toBe(MAX_COUNTRIES);
	expect(COUNTRY_COLORS.every((color) => /^#[0-9a-f]{6}$/.test(color))).toBe(
		true,
	);
	const land = new Uint8Array(WIDTH * HEIGHT).fill(1);
	const world = new World(land);
	const now = 0;
	const enter = (id: string, country: string) =>
		world.input(
			id,
			{
				name: id,
				direction: "idle",
				country_id: world.country(country)?.country_id,
				seq: 1,
			},
			now,
		);
	for (let i = 0; i < MAX_COUNTRIES; i++) enter(`founder:${i}`, `Nation ${i}`);
	expect(world.countries.size).toBe(MAX_COUNTRIES);
	enter("late", "Newcomer");
	expect(world.players.has("late")).toBe(false);
	expect(world.countries.size).toBe(MAX_COUNTRIES);
	const countryId = world.players.get("founder:0")?.country_id;
	world.input(
		"ally",
		{ name: "Ally", country_id: countryId, direction: "idle", seq: 1 },
		now,
	);
	expect(world.players.has("ally")).toBe(true);
	expect(world.countries.size).toBe(MAX_COUNTRIES);
	// Nation 0 still has a live holder, so removing one of two holders keeps it.
	world.remove("founder:0", now);
	expect(world.countries.size).toBe(MAX_COUNTRIES);
	// The last holder leaves a zero-land country: the slot is reclaimed.
	const holder = world.players.get("ally");
	if (!holder) throw new Error("Holder missing");
	const freed = holder.country_id;
	world.remove("ally", now);
	expect(world.countries.has(freed)).toBe(false);
	expect(world.countries.size).toBe(MAX_COUNTRIES - 1);
	expect(world.dirtyRemovedCountries).toEqual(new Set([freed]));
	// A stale or malformed selection must never create a country by its old name.
	for (const countryId of [freed, "1", null, 1.5]) {
		world.input(
			"stale",
			{
				name: "Stale",
				country_id: countryId,
				country: "Nation 0",
				direction: "idle",
				seq: 1,
			},
			now,
		);
		expect(world.players.has("stale")).toBe(false);
	}
	// The freed name founds a fresh country with a never-reused id.
	enter("reborn", "Nation 0");
	const reborn = world.players.get("reborn");
	if (!reborn) throw new Error("Rejoin missing");
	expect(reborn.country_id).not.toBe(freed);
	expect(world.countries.size).toBe(MAX_COUNTRIES);
	enter("too-late", "Another");
	expect(world.players.has("too-late")).toBe(false);
});

test("64 live countries keep distinct colors through slot reuse and restart", () => {
	const land = new Uint8Array(WIDTH * HEIGHT).fill(1);
	const world = new World(land);
	for (let i = 0; i < MAX_COUNTRIES; i++) {
		world.input(
			String(i),
			{
				name: String(i),
				country_id: world.country(String(i))?.country_id,
				direction: "idle",
				seq: 1,
			},
			0,
		);
		// Give every surviving country one cell so restart keeps it.
		const country = world.countries.get(i + 1);
		if (!country) throw new Error("Country missing");
		country.count = 1;
		world.owners[i] = country.country_id;
	}
	const retired = world.countries.get(18);
	if (!retired) throw new Error("Country missing");
	retired.count = 0;
	world.owners[17] = 0;
	world.remove("17", 0);
	world.input(
		"replacement",
		{
			name: "New Player",
			country_id: world.country("Replacement")?.country_id,
			direction: "idle",
			seq: 1,
		},
		0,
	);
	const replacement = world.countries.get(MAX_COUNTRIES + 1);
	if (!replacement) throw new Error("Replacement missing");
	expect(replacement.color).toBe(retired.color);
	replacement.count = 1;
	world.owners[17] = replacement.country_id;
	const rows = [...world.countries.values()];
	expect(new Set(rows.map((country) => country.color)).size).toBe(
		MAX_COUNTRIES,
	);
	const restored = new World(land);
	restored.restore(
		rows,
		[world.chunk(0), world.chunk(1)],
		[],
		world.allocatorMark,
	);
	expect([...restored.countries.values()]).toEqual(rows);
	restored.input(
		"teammate",
		{
			name: "Teammate",
			country_id: replacement.country_id,
			direction: "idle",
			seq: 1,
		},
		0,
	);
	expect(restored.players.get("teammate")?.country_id).toBe(
		replacement.country_id,
	);
});

test("capturing the last cell deletes only abandoned countries", () => {
	const land = new Uint8Array(WIDTH * HEIGHT).fill(1);
	const world = new World(land);
	let now = 0;
	world.input(
		"a",
		{
			name: "Alice",
			direction: "idle",
			country_id: world.country("Alpha")?.country_id,
			seq: 1,
		},
		now,
	);
	world.input(
		"b",
		{
			name: "Bob",
			direction: "idle",
			country_id: world.country("Beta")?.country_id,
			seq: 1,
		},
		now,
	);
	const a = world.players.get("a");
	const b = world.players.get("b");
	if (!a || !b) throw new Error("Missing players");
	b.x = 100;
	b.y = 100;
	const cell = 100 * WIDTH + 101;
	world.owners[cell] = a.country_id;
	const alpha = world.countries.get(a.country_id);
	if (!alpha) throw new Error("Alpha missing");
	alpha.count = 1;
	world.input(
		"b",
		{
			name: "Bob",
			direction: "right",
			country_id: b.country_id,
			seq: 2,
		},
		now,
	);
	for (let i = 0; i < RULES.enemy; i++) world.tick(++now);
	expect([b.x, b.y]).toEqual([101, 100]);
	expect(world.countries.get(a.country_id)?.count).toBe(0);
	// a still roams, so landless Alpha survives.
	expect(world.countries.has(a.country_id)).toBe(true);
	expect(world.dirtyRemovedCountries.size).toBe(0);
	world.remove("a", now);
	expect(world.countries.has(a.country_id)).toBe(false);
	expect(world.dirtyRemovedCountries.has(a.country_id)).toBe(true);
});

test("restart prunes abandoned zero-land countries and keeps codes monotonic", () => {
	const land = new Uint8Array(WIDTH * HEIGHT).fill(1);
	const src = new World(land);
	let now = 0;
	src.input(
		"f",
		{
			name: "Founder",
			direction: "right",
			country_id: src.country("Keep")?.country_id,
			seq: 1,
		},
		now,
	);
	for (let i = 0; i < RULES.neutral; i++) src.tick(++now);
	const keep = src.players.get("f");
	if (!keep) throw new Error("Founder missing");
	expect(src.countries.get(keep.country_id)?.count).toBe(1);
	const chunks = [...src.dirtyChunks].map((index) => src.chunk(index));
	const rows = [...src.countries.values()];
	rows.push({
		country_id: 999,
		name: "Ghost",
		color: "#ffffff",
		count: 0,
		is_bot: false,
	});
	const dst = new World(land.slice());
	dst.restore(rows, chunks);
	expect(dst.countries.has(999)).toBe(false);
	expect(dst.dirtyRemovedCountries.has(999)).toBe(true);
	expect(dst.countries.get(keep.country_id)?.count).toBe(1);
	dst.input(
		"n",
		{
			name: "Newcomer",
			direction: "idle",
			country_id: dst.country("Fresh")?.country_id,
			seq: 1,
		},
		now,
	);
	// The pruned Ghost row still counts toward the mark (safe direction:
	// skipping codes is harmless, reusing them is not).
	expect(dst.players.get("n")?.country_id).toBe(1000);
	// Deletion publishes as a remove, and the persisted mark keeps the
	// retired id retired across the restart: no reuse.
	const fresh = dst.players.get("n");
	if (!fresh) throw new Error("Fresh missing");
	const retired = fresh.country_id;
	dst.remove("n", now);
	expect(dst.countries.has(retired)).toBe(false);
	const drained = drainPublishState(dst);
	const ops = buildPublishOperations(dst, drained);
	expect(ops).toContainEqual({
		op: "remove",
		path: ["countries", String(retired)],
	});
	const mark = dst.allocatorMark;
	const dst2 = new World(land.slice());
	dst2.restore([...dst.countries.values()], chunks, [], mark);
	expect(dst2.countries.has(retired)).toBe(false);
	dst2.input(
		"m",
		{
			name: "More",
			direction: "idle",
			country_id: dst2.country("More")?.country_id,
			seq: 1,
		},
		now,
	);
	expect(dst2.players.get("m")?.country_id).toBe(mark);
});

test("human names are required, limited to 16 characters, and published separately from countries", () => {
	const world = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	const data = {
		country_id: world.country("North")?.country_id,
		direction: "idle",
		seq: 1,
	};
	for (const name of [
		undefined,
		null,
		123,
		"",
		"  ",
		"x".repeat(17),
		"A\u0000",
		"A\u200b",
	]) {
		expect(() => playerName(name)).toThrow();
		world.input("invalid", { ...data, name }, 0);
	}
	expect(world.players.size).toBe(0);
	expect(world.countries.size).toBe(1);
	expect(playerName("北".repeat(16))).toBe("北".repeat(16));
	world.input("alice", { ...data, name: "  Ａlice   Smith " }, 0);
	world.input("bob", { ...data, name: "Bob" }, 0);
	const alice = world.players.get("alice");
	const bob = world.players.get("bob");
	if (!alice || !bob) throw new Error("Players missing");
	expect(alice.country_id).toBe(bob.country_id);
	expect(world.countries.get(alice.country_id)?.name).toBe("North");
	// Dots carry positions only; names live in the published roster rows.
	for (const player of [alice, bob]) {
		const dot = readDots(world.chunk(chunkIndex(player.x, player.y)).dots).find(
			(dot) => dot.player_id === player.id,
		);
		expect(dot).toMatchObject({
			player_id: player.id,
			x: player.x,
			y: player.y,
		});
		expect(world.playerRow(player.id)?.name).toBe(
			player.id === "alice" ? "Alice Smith" : "Bob",
		);
	}
	expect(world.dirtyPlayerRows.has("alice")).toBe(true);
	expect(world.dirtyPlayerRows.has("bob")).toBe(true);
	// A name belongs to this admission; later movement cannot rename its dot.
	world.input("alice", { ...data, name: "Changed", seq: 2 }, 1);
	expect(alice.name).toBe("Alice Smith");
	expect(world.playerRow("alice")?.name).toBe("Alice Smith");
	world.startBots(1);
	expect(
		[...world.players.values()]
			.filter((player) => player.is_bot)
			.every((player) => player.name === undefined),
	).toBe(true);
});

test("presence only joins country codes and unused country reservations can be released", () => {
	const world = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	const data = { name: "Alice", direction: "idle", seq: 1 };
	world.input("alice", { ...data, country: "Must not create" }, 0);
	expect(world.players.size).toBe(0);
	expect(world.countries.size).toBe(0);
	const abandoned = world.country("Abandoned");
	const occupied = world.country("Occupied");
	if (!abandoned || !occupied) throw new Error("Countries missing");
	world.input("alice", { ...data, country_id: occupied.country_id }, 0);
	world.maybeDeleteCountry(abandoned.country_id);
	world.maybeDeleteCountry(occupied.country_id);
	expect(world.countries.has(abandoned.country_id)).toBe(false);
	expect(world.countries.has(occupied.country_id)).toBe(true);
	expect(world.country("Next")?.country_id).toBeGreaterThan(
		occupied.country_id,
	);
});

test("leave keeps a 10s tombstone row so same-id reconnects resume in place", () => {
	const world = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	const data = {
		name: "Alice",
		country_id: world.country("North")?.country_id,
		direction: "idle",
		seq: 1,
	};
	world.input("alice", data, 0);
	const player = world.players.get("alice");
	if (!player) throw new Error("Player missing");
	const [x, y] = [player.x, player.y];
	// Roster row tracks the spawn cell for O(1) locate.
	expect(world.playerRow("alice")).toMatchObject({
		name: "Alice",
		country_id: player.country_id,
		is_bot: false,
		last_x: x,
		last_y: y,
	});
	world.remove("alice", 0);
	// Dots vanish immediately but the row lingers with its final position.
	expect(world.players.has("alice")).toBe(false);
	expect(
		readDots(world.chunk(chunkIndex(x, y)).dots).some(
			(dot) => dot.player_id === "alice",
		),
	).toBe(false);
	expect(world.playerRow("alice")).toMatchObject({ last_x: x, last_y: y });
	expect(world.dirtyPlayerRows.has("alice")).toBe(true);
	expect(world.dirtyRemovedPlayerRows.has("alice")).toBe(false);
	// Tombstones never pin countries or consume the human cap.
	expect(world.humanCount).toBe(0);
	// Leaving deleted landless North; the lobby re-issues it on rejoin while
	// the tombstone still restores the exact cell.
	const revived = world.country("North")?.country_id;
	world.input("alice", { ...data, country_id: revived, seq: 2 }, 1);
	const returned = world.players.get("alice");
	expect([returned?.x, returned?.y]).toEqual([x, y]);
	expect(world.dirtyRemovedPlayerRows.has("alice")).toBe(false);
	// After the window the row is queued for removal.
	world.remove("alice", 1);
	world.tick(1 + PLAYER_GRACE_MS);
	expect(world.playerRow("alice")).toBeUndefined();
	expect(world.dirtyRemovedPlayerRows.has("alice")).toBe(true);
	const drained = drainPublishState(world);
	const ops = buildPublishOperations(world, drained);
	expect(ops).toContainEqual({ op: "remove", path: ["users", "alice"] });
});

test("silent-timeout removal still grants the full grace window on reconnect", () => {
	const world = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	const data = {
		name: "Alice",
		country_id: world.country("North")?.country_id,
		direction: "idle",
		seq: 1,
	};
	world.input("alice", data, 0);
	const player = world.players.get("alice");
	if (!player) throw new Error("Player missing");
	const [x, y] = [player.x, player.y];
	// Go silent past the input lease: the tick removes at now, so expiry must
	// run from removal (10001 + grace), not last contact (0 + grace).
	const removedAt = INPUT_LEASE_MS * 5 + 1;
	world.tick(removedAt);
	expect(world.players.has("alice")).toBe(false);
	expect(world.playerRow("alice")).toMatchObject({ last_x: x, last_y: y });
	// A tick past the old heardAt-based expiry must NOT collect the row.
	world.tick(removedAt + 2000);
	expect(world.playerRow("alice")).toMatchObject({ last_x: x, last_y: y });
	expect(world.dirtyRemovedPlayerRows.has("alice")).toBe(false);
	// Reconnect inside the removal-based window but past the old
	// heardAt-based one: the exact cell must resume, not a fresh spawn.
	const rejoinAt = removedAt + PLAYER_GRACE_MS - 5000;
	const revived = world.country("North")?.country_id;
	world.input("alice", { ...data, country_id: revived, seq: 2 }, rejoinAt);
	const returned = world.players.get("alice");
	expect([returned?.x, returned?.y]).toEqual([x, y]);
	expect(returned?.country_id).toBe(revived);
	// And a tombstone left alone still expires on schedule.
	world.remove("alice", rejoinAt);
	world.tick(rejoinAt + PLAYER_GRACE_MS + 1);
	expect(world.playerRow("alice")).toBeUndefined();
	expect(world.dirtyRemovedPlayerRows.has("alice")).toBe(true);
});

test("crossing a chunk boundary refreshes the roster position, plain moves do not", () => {
	const world = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	const data = {
		name: "Walker",
		country_id: world.country("North")?.country_id,
		direction: "right",
		seq: 1,
	};
	world.input("walker", data, 0);
	const player = world.players.get("walker");
	if (!player) throw new Error("Player missing");
	player.x = CHUNK - 1;
	player.y = 10;
	player.last_x = CHUNK - 1;
	player.last_y = 10;
	world.dirtyPlayerRows.clear();
	world.tick(1);
	// Still inside the chunk: no roster write.
	expect(chunkIndex(player.x, player.y)).toBe(chunkIndex(CHUNK - 1, 10));
	expect(world.dirtyPlayerRows.has("walker")).toBe(false);
	player.x = CHUNK - 1;
	world.input("walker", { ...data, seq: 2 }, 2);
	for (let now = 3; now < 3 + RULES.neutral * 2 + 10; now++) {
		world.tick(now);
		if (player.x === CHUNK) break;
	}
	expect(player.x).toBe(CHUNK);
	expect(world.playerRow("walker")).toMatchObject({
		last_x: CHUNK,
		last_y: 10,
	});
	expect(world.dirtyPlayerRows.has("walker")).toBe(true);
});

test("restore clears persisted dots and queues stale roster rows for removal", () => {
	const land = new Uint8Array(WIDTH * HEIGHT).fill(1);
	const src = new World(land);
	src.input(
		"alice",
		{
			name: "Alice",
			direction: "idle",
			country_id: src.country("North")?.country_id,
			seq: 1,
		},
		0,
	);
	const chunks = [...src.dirtyChunks].map((index) => src.chunk(index));
	const dst = new World(land.slice());
	dst.restore([...src.countries.values()], chunks, [
		{ id: "alice" },
		{ id: "bot-0" },
	]);
	// Positions never survive a restart; stale dots republish empty.
	for (const index of dst.dirtyChunks)
		expect(readDots(dst.chunk(index).dots)).toEqual([]);
	expect(dst.dirtyRemovedPlayerRows).toEqual(new Set(["alice", "bot-0"]));
});

test("human spawns spread out instead of stacking on one chunk", () => {
	const world = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	const country = world.country("Spread");
	if (!country) throw new Error("Missing country");
	for (let i = 0; i < 256; i++)
		world.input(
			`human:${i}`,
			{
				name: `Human ${i}`,
				country_id: country.country_id,
				direction: "idle",
				seq: 1,
			},
			0,
		);
	const perChunk = new Map<number, number>();
	for (const player of world.players.values())
		perChunk.set(
			chunkIndex(player.x, player.y),
			(perChunk.get(chunkIndex(player.x, player.y)) ?? 0) + 1,
		);
	// Stacking the crowd on the first player used to put every dot in one or
	// two chunks, which overflowed the dots field once the chunk was full.
	expect(perChunk.size).toBeGreaterThan(64);
	expect(Math.max(...perChunk.values())).toBeLessThan(16);
});

test("human joiners reinforce their territory, teammates, or a region", () => {
	const world = new World(terrain());
	const country = world.country("Team");
	if (!country) throw new Error("Missing country");
	const join = (id: string, now = 0) =>
		world.input(
			id,
			{
				name: id,
				country_id: country.country_id,
				direction: "idle",
				seq: 1,
			},
			now,
		);
	join("founder");
	const founder = world.players.get("founder");
	if (!founder) throw new Error("Missing founder");
	// No territory yet: the next joiner aims at the live teammate.
	join("mate");
	const mate = world.players.get("mate");
	if (!mate) throw new Error("Missing mate");
	expect(Math.hypot(mate.x - founder.x, mate.y - founder.y)).toBeLessThan(64);
	// Give the country a patch of land: joiners must prefer it.
	for (let dy = -16; dy <= 16; dy++)
		for (let dx = -16; dx <= 16; dx++)
			world.owners[(founder.y + dy) * WIDTH + founder.x + dx] =
				country.country_id;
	country.count = 33 * 33;
	(
		world as unknown as {
			bounds: Map<
				number,
				{ left: number; right: number; top: number; bottom: number }
			>;
		}
	).bounds.set(country.country_id, {
		left: founder.x - 16,
		right: founder.x + 16,
		top: founder.y - 16,
		bottom: founder.y + 16,
	});
	join("reinforcement");
	const reinforcement = world.players.get("reinforcement");
	if (!reinforcement) throw new Error("Missing reinforcement");
	expect(world.owners[reinforcement.y * WIDTH + reinforcement.x]).toBe(
		country.country_id,
	);
	// Abandoned territory still pulls its country's next player home.
	world.remove("founder", 0);
	world.remove("mate", 0);
	world.remove("reinforcement", 0);
	join("returning", PLAYER_GRACE_MS * 10);
	const returning = world.players.get("returning");
	if (!returning) throw new Error("Missing returning player");
	expect(world.owners[returning.y * WIDTH + returning.x]).toBe(
		country.country_id,
	);
});

test("humans cannot join bot countries, even with a forged country id", () => {
	const world = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	const bot = world.country("Polandia", true);
	if (!bot) throw new Error("Missing bot country");
	expect(bot.is_bot).toBe(true);
	const human = world.country("North");
	if (!human) throw new Error("Missing human country");
	expect(human.is_bot).toBe(false);
	for (const id of ["forged", "reinforce"])
		world.input(
			id,
			{
				name: id,
				country_id: bot.country_id,
				direction: "idle",
				seq: 1,
			},
			0,
		);
	expect(world.players.size).toBe(0);
	world.input(
		"human",
		{
			name: "Human",
			country_id: human.country_id,
			direction: "idle",
			seq: 1,
		},
		0,
	);
	expect(world.players.get("human")?.country_id).toBe(human.country_id);
});
