import { expect, test } from "bun:test";
import { buildPublishOperations, drainPublishState } from "./publish";
import {
	CHUNK,
	COUNTRY_COLORS,
	chunkIndex,
	HEIGHT,
	INPUT_LEASE_MS,
	MAX_COUNTRIES,
	MAX_PLAYERS,
	PLAYER_GRACE_MS,
	playerName,
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
		world.input(
			id,
			{
				name: id,
				direction,
				countryCode:
					world.players.get(id)?.country_id ?? world.country(country)?.code,
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
		alice.country_id,
	);
	world.remove("alice", now);
	expect(world.owners[10 * WIDTH + 35]).toBe(alice.country_id);
	expect(
		readDots(world.chunk(chunkIndex(35, 10)).dots).some(
			(dot) => dot.player_id === "alice",
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
				(player) => player.country_id === country.code,
			),
		).toHaveLength(2);
	const bot = world.players.get("bot-0");
	const retiring = world.players.get("bot-9");
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
			{
				name: `Human ${i}`,
				countryCode: world.country("Humans")?.code,
				direction: "idle",
				seq: 1,
			},
			now,
		);
	join(0);
	world.tick(now);
	expect(world.players.size).toBe(11);
	expect([bot.x, bot.y]).toEqual([100, 100]);
	world.tick(now + 1);
	expect(Math.abs(bot.x - 100) + Math.abs(bot.y - 100)).toBe(1);
	expect(world.owners[bot.y * WIDTH + bot.x]).toBe(bot.country_id);

	world.owners[0] = retiring.country_id;
	join(1);
	world.tick(now + 2);
	expect(world.humanCount).toBe(2);
	expect(world.players.has("bot-9")).toBe(false);
	expect(world.players.size).toBe(11);
	expect(world.owners[0]).toBe(retiring.country_id);
	world.remove("human:1", now + 2);
	world.tick(now + 3);
	expect(world.players.get("bot-9")?.country_id).toBe(retiring.country_id);
	expect(world.countries.size).toBe(6);
	for (let i = 1; i < MAX_PLAYERS + 1; i++) join(i);
	world.tick(now + 4);
	expect(world.humanCount).toBe(MAX_PLAYERS);
	expect([...world.players.values()].some((player) => player.is_bot)).toBe(
		false,
	);
	world.tick(now + INPUT_LEASE_MS * 6);
	expect(world.humanCount).toBe(0);
	expect(world.players.size).toBe(10);
	expect(
		readDots(world.chunk(chunkIndex(933, 276)).dots).every(
			(dot) => world.players.get(dot.player_id)?.is_bot,
		),
	).toBe(true);
});

test("input validation, borders, and expired input stop movement; map mask is deterministic", () => {
	const land = terrain();
	expect(land.reduce((sum, cell) => sum + cell, 0)).toBe(661568);
	const world = new World(land);
	const data = {
		name: "Player",
		direction: "right",
		countryCode: world.country("Test")?.code,
		seq: 1,
	};
	world.input("invalid", { ...data, direction: "__proto__" }, 0);
	world.input("invalid", { ...data, countryCode: 999 }, 0);
	expect(() => world.country("\u0000")).toThrow();
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
				countryCode: world.country(country)?.code,
				seq: 1,
			},
			now,
		);
	for (let i = 0; i < MAX_COUNTRIES; i++) enter(`founder:${i}`, `Nation ${i}`);
	expect(world.countries.size).toBe(MAX_COUNTRIES);
	enter("late", "Newcomer");
	expect(world.players.has("late")).toBe(false);
	expect(world.countries.size).toBe(MAX_COUNTRIES);
	const countryCode = world.players.get("founder:0")?.country_id;
	world.input(
		"ally",
		{ name: "Ally", countryCode, direction: "idle", seq: 1 },
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
	for (const countryCode of [freed, "1", null, 1.5]) {
		world.input(
			"stale",
			{
				name: "Stale",
				countryCode,
				country: "Nation 0",
				direction: "idle",
				seq: 1,
			},
			now,
		);
		expect(world.players.has("stale")).toBe(false);
	}
	// The freed name founds a fresh country with a never-reused code.
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
				countryCode: world.country(String(i))?.code,
				direction: "idle",
				seq: 1,
			},
			0,
		);
		// Give every surviving country one cell so restart keeps it.
		const country = world.countries.get(i + 1);
		if (!country) throw new Error("Country missing");
		country.count = 1;
		world.owners[i] = country.code;
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
			countryCode: world.country("Replacement")?.code,
			direction: "idle",
			seq: 1,
		},
		0,
	);
	const replacement = world.countries.get(MAX_COUNTRIES + 1);
	if (!replacement) throw new Error("Replacement missing");
	expect(replacement.color).toBe(retired.color);
	replacement.count = 1;
	world.owners[17] = replacement.code;
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
			countryCode: replacement.code,
			direction: "idle",
			seq: 1,
		},
		0,
	);
	expect(restored.players.get("teammate")?.country_id).toBe(replacement.code);
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
			countryCode: world.country("Alpha")?.code,
			seq: 1,
		},
		now,
	);
	world.input(
		"b",
		{
			name: "Bob",
			direction: "idle",
			countryCode: world.country("Beta")?.code,
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
			countryCode: b.country_id,
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
			countryCode: src.country("Keep")?.code,
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
		id: "999",
		code: 999,
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
			countryCode: dst.country("Fresh")?.code,
			seq: 1,
		},
		now,
	);
	// The pruned Ghost row still counts toward the mark (safe direction:
	// skipping codes is harmless, reusing them is not).
	expect(dst.players.get("n")?.country_id).toBe(1000);
	// Deletion publishes as a remove, and the persisted mark keeps the
	// retired code retired across the restart: no reuse.
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
			countryCode: dst2.country("More")?.code,
			seq: 1,
		},
		now,
	);
	expect(dst2.players.get("m")?.country_id).toBe(mark);
});

test("human names are required, limited to 16 characters, and published separately from countries", () => {
	const world = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	const data = {
		countryCode: world.country("North")?.code,
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
		expect(world.userRow(player.id)?.name).toBe(
			player.id === "alice" ? "Alice Smith" : "Bob",
		);
	}
	expect(world.dirtyUsers.has("alice")).toBe(true);
	expect(world.dirtyUsers.has("bob")).toBe(true);
	// A name belongs to this admission; later movement cannot rename its dot.
	world.input("alice", { ...data, name: "Changed", seq: 2 }, 1);
	expect(alice.name).toBe("Alice Smith");
	expect(world.userRow("alice")?.name).toBe("Alice Smith");
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
	world.input("alice", { ...data, countryCode: occupied.code }, 0);
	world.maybeDeleteCountry(abandoned.code);
	world.maybeDeleteCountry(occupied.code);
	expect(world.countries.has(abandoned.code)).toBe(false);
	expect(world.countries.has(occupied.code)).toBe(true);
	expect(world.country("Next")?.code).toBeGreaterThan(occupied.code);
});

test("leave keeps a 10s tombstone row so same-id reconnects resume in place", () => {
	const world = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	const data = {
		name: "Alice",
		countryCode: world.country("North")?.code,
		direction: "idle",
		seq: 1,
	};
	world.input("alice", data, 0);
	const player = world.players.get("alice");
	if (!player) throw new Error("Player missing");
	const [x, y] = [player.x, player.y];
	// Roster row tracks the spawn cell for O(1) locate.
	expect(world.userRow("alice")).toMatchObject({
		name: "Alice",
		country_id: player.country_id,
		is_bot: false,
		lastX: x,
		lastY: y,
	});
	world.remove("alice", 0);
	// Dots vanish immediately but the row lingers with its final position.
	expect(world.players.has("alice")).toBe(false);
	expect(
		readDots(world.chunk(chunkIndex(x, y)).dots).some(
			(dot) => dot.player_id === "alice",
		),
	).toBe(false);
	expect(world.userRow("alice")).toMatchObject({ lastX: x, lastY: y });
	expect(world.dirtyUsers.has("alice")).toBe(true);
	expect(world.dirtyRemovedUsers.has("alice")).toBe(false);
	// Tombstones never pin countries or consume the human cap.
	expect(world.humanCount).toBe(0);
	// Leaving deleted landless North; the lobby re-issues it on rejoin while
	// the tombstone still restores the exact cell.
	const revived = world.country("North")?.code;
	world.input("alice", { ...data, countryCode: revived, seq: 2 }, 1);
	const returned = world.players.get("alice");
	expect([returned?.x, returned?.y]).toEqual([x, y]);
	expect(world.dirtyRemovedUsers.has("alice")).toBe(false);
	// After the window the row is queued for removal.
	world.remove("alice", 1);
	world.tick(1 + PLAYER_GRACE_MS);
	expect(world.userRow("alice")).toBeUndefined();
	expect(world.dirtyRemovedUsers.has("alice")).toBe(true);
	const drained = drainPublishState(world);
	const ops = buildPublishOperations(world, drained);
	expect(ops).toContainEqual({ op: "remove", path: ["users", "alice"] });
});

test("silent-timeout removal still grants the full grace window on reconnect", () => {
	const world = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	const data = {
		name: "Alice",
		countryCode: world.country("North")?.code,
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
	expect(world.userRow("alice")).toMatchObject({ lastX: x, lastY: y });
	// A tick past the old heardAt-based expiry must NOT collect the row.
	world.tick(removedAt + 2000);
	expect(world.userRow("alice")).toMatchObject({ lastX: x, lastY: y });
	expect(world.dirtyRemovedUsers.has("alice")).toBe(false);
	// Reconnect inside the removal-based window but past the old
	// heardAt-based one: the exact cell must resume, not a fresh spawn.
	const rejoinAt = removedAt + PLAYER_GRACE_MS - 5000;
	const revived = world.country("North")?.code;
	world.input("alice", { ...data, countryCode: revived, seq: 2 }, rejoinAt);
	const returned = world.players.get("alice");
	expect([returned?.x, returned?.y]).toEqual([x, y]);
	expect(returned?.country_id).toBe(revived);
	// And a tombstone left alone still expires on schedule.
	world.remove("alice", rejoinAt);
	world.tick(rejoinAt + PLAYER_GRACE_MS + 1);
	expect(world.userRow("alice")).toBeUndefined();
	expect(world.dirtyRemovedUsers.has("alice")).toBe(true);
});

test("crossing a chunk boundary refreshes the roster position, plain moves do not", () => {
	const world = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	const data = {
		name: "Walker",
		countryCode: world.country("North")?.code,
		direction: "right",
		seq: 1,
	};
	world.input("walker", data, 0);
	const player = world.players.get("walker");
	if (!player) throw new Error("Player missing");
	player.x = CHUNK - 1;
	player.y = 10;
	player.lastX = CHUNK - 1;
	player.lastY = 10;
	world.dirtyUsers.clear();
	world.tick(1);
	// Still inside the chunk: no roster write.
	expect(chunkIndex(player.x, player.y)).toBe(chunkIndex(CHUNK - 1, 10));
	expect(world.dirtyUsers.has("walker")).toBe(false);
	player.x = CHUNK - 1;
	world.input("walker", { ...data, seq: 2 }, 2);
	for (let now = 3; now < 3 + RULES.neutral * 2 + 10; now++) {
		world.tick(now);
		if (player.x === CHUNK) break;
	}
	expect(player.x).toBe(CHUNK);
	expect(world.userRow("walker")).toMatchObject({ lastX: CHUNK, lastY: 10 });
	expect(world.dirtyUsers.has("walker")).toBe(true);
});

test("restore clears persisted dots and queues stale roster rows for removal", () => {
	const land = new Uint8Array(WIDTH * HEIGHT).fill(1);
	const src = new World(land);
	src.input(
		"alice",
		{
			name: "Alice",
			direction: "idle",
			countryCode: src.country("North")?.code,
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
	expect(dst.dirtyRemovedUsers).toEqual(new Set(["alice", "bot-0"]));
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
				countryCode: country.code,
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
				countryCode: country.code,
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
			world.owners[(founder.y + dy) * WIDTH + founder.x + dx] = country.code;
	country.count = 33 * 33;
	(
		world as unknown as {
			bounds: Map<
				number,
				{ left: number; right: number; top: number; bottom: number }
			>;
		}
	).bounds.set(country.code, {
		left: founder.x - 16,
		right: founder.x + 16,
		top: founder.y - 16,
		bottom: founder.y + 16,
	});
	join("reinforcement");
	const reinforcement = world.players.get("reinforcement");
	if (!reinforcement) throw new Error("Missing reinforcement");
	expect(world.owners[reinforcement.y * WIDTH + reinforcement.x]).toBe(
		country.code,
	);
	// Abandoned territory still pulls its country's next player home.
	world.remove("founder", 0);
	world.remove("mate", 0);
	world.remove("reinforcement", 0);
	join("returning", PLAYER_GRACE_MS * 10);
	const returning = world.players.get("returning");
	if (!returning) throw new Error("Missing returning player");
	expect(world.owners[returning.y * WIDTH + returning.x]).toBe(country.code);
});

test("humans cannot join bot countries, even with a forged code", () => {
	const world = new World(new Uint8Array(WIDTH * HEIGHT).fill(1));
	const bot = world.country("Bot · Amber", true);
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
				countryCode: bot.code,
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
			countryCode: human.code,
			direction: "idle",
			seq: 1,
		},
		0,
	);
	expect(world.players.get("human")?.country_id).toBe(human.code);
});
