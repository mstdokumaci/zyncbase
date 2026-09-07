import { expect, test } from "bun:test";
import {
	CHUNK,
	chunkIndex,
	HEIGHT,
	INPUT_LEASE_MS,
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
