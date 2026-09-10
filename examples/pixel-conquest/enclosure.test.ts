import { expect, spyOn, test } from "bun:test";
import {
	hasStraightExit,
	LOCAL_SEARCH_BUDGET,
	localEnclosures,
	mayEnclose,
} from "./enclosure";
import { HoleFiller } from "./filler";
import { chunkIndex, type Direction, HEIGHT, WIDTH } from "./shared";
import { World } from "./world";

type Pixel = [number, number, number];

// Independent four-neighbor boundary flood; deliberately no scanline logic.
// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: keep the independent reference flood explicit for comparison with the scanline implementation.
function referenceFill(owners: Uint16Array, width: number, code: number) {
	const labels = Uint8Array.from(owners, (owner) => (owner === code ? 2 : 0));
	const queue: number[] = [];
	const visit = (cell: number) => {
		if (labels[cell] !== 0) return;
		labels[cell] = 1;
		queue.push(cell);
	};
	for (let cell = 0; cell < labels.length; cell++)
		if (
			cell < width ||
			cell >= labels.length - width ||
			cell % width === 0 ||
			cell % width === width - 1
		)
			visit(cell);
	for (let head = 0; head < queue.length; head++) {
		const cell = queue[head];
		if (cell >= width) visit(cell - width);
		if (cell + width < labels.length) visit(cell + width);
		if (cell % width > 0) visit(cell - 1);
		if (cell % width < width - 1) visit(cell + 1);
	}
	return labels;
}

test("bounded local searches match a complete flood for every 4x4 mask", () => {
	const owners = new Uint16Array(16);
	const starts = new Set(owners.keys());
	const bounds = { left: 0, right: 3, top: 0, bottom: 3 };
	for (let mask = 0; mask < 65536; mask++) {
		for (let i = 0; i < owners.length; i++) owners[i] = (mask >> i) & 1;
		const expected = [...referenceFill(owners, 4, 1).entries()]
			.filter(([, label]) => label === 0)
			.map(([cell]) => cell);
		expect(localEnclosures(owners, 1, starts, bounds, 4)).toEqual(expected);
	}
});

test("a straight exit resolves a broad open component without exhausting the flood budget", () => {
	const width = 80;
	const owners = new Uint16Array(width * width);
	owners[0] = owners[owners.length - 1] = 1;
	const initial = owners.slice();
	expect(
		localEnclosures(
			owners,
			1,
			new Set([40 * width + 40]),
			{ left: 0, right: width - 1, top: 0, bottom: width - 1 },
			width,
		),
	).toEqual([]);
	expect(owners).toEqual(initial);
});

test("the local budget is shared across components and exhaustion leaves ownership untouched", () => {
	const width = 80,
		height = 30;
	const owners = new Uint16Array(width * height).fill(1);
	for (const left of [2, 40])
		for (let y = 2; y < 27; y++)
			for (let x = left; x < left + 25; x++) owners[y * width + x] = 0;
	const initial = owners.slice();
	let reads = 0;
	const counted = new Proxy(owners, {
		get(target, key) {
			if (typeof key === "string" && /^\d+$/.test(key)) reads++;
			return Reflect.get(target, key, target);
		},
	});
	expect(
		localEnclosures(
			counted,
			1,
			new Set([2 * width + 2, 2 * width + 40]),
			{ left: 0, right: width - 1, top: 0, bottom: height - 1 },
			width,
		),
	).toBeUndefined();
	expect(reads).toBeLessThanOrEqual(LOCAL_SEARCH_BUDGET * 5);
	expect(owners).toEqual(initial);
});

test.each([
	3,
	4,
	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: exhaust masks and possible paints after independently filling old holes.
])("gain gate never skips a new enclosure on filled masks of size %i", (size) => {
	const owners = new Uint16Array(size * size);
	for (let mask = 0; mask < 2 ** owners.length; mask++) {
		for (let i = 0; i < owners.length; i++) owners[i] = (mask >> i) & 1;
		const before = referenceFill(owners, size, 1);
		for (let i = 0; i < owners.length; i++) if (before[i] === 0) owners[i] = 1;
		for (const cell of size === 3 ? owners.keys() : [size + 1]) {
			if (owners[cell]) continue;
			owners[cell] = 1;
			if (!mayEnclose(owners, 1, cell, size))
				expect(referenceFill(owners, size, 1).includes(0)).toBe(false);
			owners[cell] = 0;
		}
	}
});

test("straight exits never classify an enclosed pixel as exterior", () => {
	const owners = new Uint16Array(16);
	for (let mask = 0; mask < 65536; mask++) {
		for (let i = 0; i < owners.length; i++) owners[i] = (mask >> i) & 1;
		const labels = referenceFill(owners, 4, 1);
		for (let cell = 0; cell < owners.length; cell++)
			if (
				hasStraightExit(owners, 1, cell, 4, {
					left: 0,
					right: 3,
					top: 0,
					bottom: 3,
				})
			)
				expect(labels[cell]).toBe(1);
	}
});

test.each([
	[1, 8],
	[8, 1],
	[3, 3],
	[4, 4],
])("scanline fill matches an independent flood for every %ix%i bitmap", (width, height) => {
	const owners = new Uint16Array(width * height);
	const filler = new HoleFiller(width, height);
	const bounds = { left: 0, right: width - 1, top: 0, bottom: height - 1 };
	for (let mask = 0; mask < 2 ** owners.length; mask++) {
		for (let i = 0; i < owners.length; i++)
			owners[i] = (mask >> i) & 1 ? 65535 : i % 2 ? 2 : 0;
		expect(filler.fill(owners, 65535, bounds)).toEqual(
			referenceFill(owners, width, 65535),
		);
	}
});

test("scanline scratch buffers grow and can be reused across countries and shapes", () => {
	const width = 4097,
		height = 7;
	const owners = new Uint16Array(width * height);
	const filler = new HoleFiller(width, height);
	const bounds = { left: 0, right: width - 1, top: 0, bottom: height - 1 };
	let random = 42;
	for (let shape = 0; shape < 20; shape++) {
		for (let i = 0; i < owners.length; i++) {
			random = (Math.imul(random, 1664525) + 1013904223) >>> 0;
			owners[i] = shape === 0 ? (i % width) % 2 : (random >>> 16) % 3;
		}
		for (const code of [1, 2])
			expect(filler.fill(owners, code, bounds)).toEqual(
				referenceFill(owners, width, code),
			);
	}
});

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: exhaust translated masks and compare every captured cell with the independent full-world reference.
test("clipping preserves full-world results at edges and after bounds shrink or move", () => {
	const width = 8,
		height = 8;
	const owners = new Uint16Array(width * height);
	const filler = new HoleFiller(width, height);
	for (const [left, top] of [
		[0, 0],
		[2, 2],
		[5, 5],
		[0, 5],
		[5, 0],
	]) {
		const bounds = { left, top, right: left + 2, bottom: top + 2 };
		for (let mask = 0; mask < 512; mask++) {
			owners.fill(2);
			for (let bit = 0; bit < 9; bit++)
				owners[(top + Math.floor(bit / 3)) * width + left + (bit % 3)] =
					(mask >> bit) & 1 ? 1 : 2;
			const labels = filler.fill(owners, 1, bounds);
			const holes: number[] = [];
			for (let y = top; y <= bounds.bottom; y++)
				for (let x = left; x <= bounds.right; x++)
					if (labels[y * width + x] === 0) holes.push(y * width + x);
			expect(holes).toEqual(
				[...referenceFill(owners, width, 1).entries()]
					.filter(([, label]) => label === 0)
					.map(([cell]) => cell),
			);
		}
	}
});

function scenario(pixels: Pixel[], water: [number, number][] = []) {
	const land = new Uint8Array(WIDTH * HEIGHT).fill(1);
	for (const [x, y] of water) land[y * WIDTH + x] = 0;
	const seed = new World(land);
	for (const code of [1, 2])
		seed.countries.set(code, {
			id: String(code),
			code,
			name: String(code),
			color: "old",
			count: 0,
		});
	const chunks = new Set<number>();
	for (const [x, y, code] of pixels) {
		seed.owners[y * WIDTH + x] = code;
		chunks.add(chunkIndex(x, y));
	}
	const world = new World(land);
	const owned = new Set<number>(pixels.map((pixel) => pixel[2]));
	world.restore(
		[...seed.countries.values()].filter((country) => owned.has(country.code)),
		[...chunks].map((index) => seed.chunk(index)),
	);
	// Production restore prunes landless countries as abandoned, so
	// re-register test identities that own no pixels yet as setup-only state.
	for (const code of [1, 2])
		if (!world.countries.has(code))
			world.countries.set(code, {
				id: String(code),
				code,
				name: String(code),
				color: "old",
				count: 0,
			});
	world.dirtyChunks.clear();
	let now = 0,
		seq = 0;
	const input = (id: string, country: number, direction: Direction) =>
		world.input(
			id,
			{
				name: id,
				countryCode: country,
				direction,
				seq: ++seq,
			},
			now,
		);
	const actor = (id: string, code: number, x: number, y: number) => {
		input(id, code, "idle");
		const player = world.players.get(id);
		if (!player) throw new Error("Missing player");
		player.x = x;
		player.y = y;
		return player;
	};
	const move = (id: string, direction: Direction) => {
		const player = world.players.get(id);
		if (!player) throw new Error("Missing player");
		const offset = { up: -WIDTH, down: WIDTH, left: -1, right: 1, idle: 0 }[
			direction
		];
		const from = player.y * WIDTH + player.x;
		const cost = world.stepCost(player.country_id, from, from + offset);
		input(id, player.country_id, direction);
		for (let i = 0; i < cost; i++) world.tick(++now);
		input(id, player.code, "idle");
	};
	return {
		world,
		chunks,
		actor,
		move,
		owner: (x: number, y: number) => world.owners[y * WIDTH + x],
	};
}

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: the fixture, capture checks, and restart comparison describe one complete enclosure.
test("closing ordinary territory captures enclosed land, updates all chunks and scores, and survives restart", () => {
	const pixels: Pixel[] = [
		[32, 32, 2],
		[40, 40, 2],
	];
	for (let y = 30; y <= 36; y++)
		for (let x = 30; x <= 36; x++) {
			if (
				(x === 30 || x === 36 || y === 30 || y === 36) &&
				!(x === 33 && y === 36)
			)
				pixels.push([x, y, 1]);
		}
	const { world, chunks, actor, move, owner } = scenario(pixels, [[34, 34]]);
	expect(owner(32, 32)).toBe(2);
	actor("attacker", 1, 32, 36);
	const fill = spyOn(HoleFiller.prototype, "fill");
	try {
		move("attacker", "right");
		// This small closure resolves locally; country 2's outpost has an exterior route.
		expect(fill).not.toHaveBeenCalled();
	} finally {
		fill.mockRestore();
	}
	expect(owner(32, 32)).toBe(1);
	expect(owner(34, 34)).toBe(0);
	expect(owner(40, 40)).toBe(2);
	expect(world.countries.get(1)?.count).toBe(48);
	expect(world.countries.get(2)?.count).toBe(1);
	for (const [x, y] of [
		[31, 31],
		[32, 31],
		[31, 32],
		[32, 32],
	])
		expect(world.dirtyChunks.has(chunkIndex(x, y))).toBe(true);
	const restored = new World(world.land);
	restored.restore(
		[...world.countries.values()],
		[...chunks].map((index) => world.chunk(index)),
	);
	expect(restored.owners).toEqual(world.owners);
	expect([...restored.countries.values()]).toEqual([
		...world.countries.values(),
	]);
});

test("closing a loop at the world edge resolves locally without wrapping rows", () => {
	const pixels: Pixel[] = [];
	for (let y = 30; y <= 32; y++)
		for (let x = WIDTH - 3; x < WIDTH; x++)
			if (x === WIDTH - 3 || y === 30 || y === 32) pixels.push([x, y, 1]);
	const { world, actor, move, owner } = scenario(pixels);
	actor("closer", 1, WIDTH - 1, 30);
	const fill = spyOn(HoleFiller.prototype, "fill");
	try {
		move("closer", "down");
		expect(fill).not.toHaveBeenCalled();
		expect(owner(WIDTH - 2, 31)).toBe(1);
		expect(owner(0, 32)).toBe(0);
		expect(world.countries.get(1)?.count).toBe(9);
	} finally {
		fill.mockRestore();
	}
});

test("a defensive enclosure reclaims a severed extension and new paint until reconnection or escape", () => {
	const pixels: Pixel[] = [];
	for (let y = 30; y <= 40; y++)
		for (let x = 30; x <= 40; x++) pixels.push([x, y, 1]);
	for (let x = 28; x <= 37; x++) pixels.push([x, 35, 2]);
	const { actor, move, owner } = scenario(pixels);
	const attacker = actor("attacker", 2, 37, 35);
	actor("defender", 1, 33, 34);
	expect(owner(37, 35)).toBe(2);
	move("defender", "down");
	expect(owner(32, 35)).toBe(2);
	expect(owner(33, 35)).toBe(1);
	expect(owner(37, 35)).toBe(1);
	move("attacker", "right");
	expect(attacker.x).toBe(38);
	expect(owner(38, 35)).toBe(1);
	for (let i = 0; i < 4; i++) move("attacker", "left");
	expect(owner(34, 35)).toBe(1);
	move("attacker", "left");
	expect(owner(33, 35)).toBe(2);
	move("attacker", "right");
	expect(owner(34, 35)).toBe(2);
	const escape_line = actor("escape", 2, 38, 35);
	for (let i = 0; i < 5; i++) move("escape", "up");
	expect(escape_line.y).toBe(30);
	expect(owner(38, 31)).toBe(1);
	expect(owner(38, 30)).toBe(2);
});

test("water gaps keep an area open and do not become a painted boundary", () => {
	const pixels: Pixel[] = [[33, 33, 2]];
	for (let y = 30; y <= 36; y++)
		for (let x = 30; x <= 36; x++) {
			if (
				(x === 30 || x === 36 || y === 30 || y === 36) &&
				!(x === 33 && y === 36)
			)
				pixels.push([x, y, 1]);
		}
	const { actor, move, owner } = scenario(pixels, [[33, 36]]);
	actor("walker", 1, 32, 36);
	move("walker", "right");
	expect(owner(33, 36)).toBe(0);
	expect(owner(33, 33)).toBe(2);
});

test("ordinary gains and exposed losses skip scans, independently of publication", () => {
	const { world, actor } = scenario([
		[31, 30, 2],
		[200, 200, 2],
	]);
	for (let i = 0; i < 10; i++) {
		const player = actor(String(i), 1, 30, 30 + i * 2);
		player.direction = "right";
		const from = player.y * WIDTH + player.x;
		player.credit = world.stepCost(1, from, from + 1) - 1;
	}
	const fill = spyOn(HoleFiller.prototype, "fill");
	try {
		world.tick(0);
		expect(fill).not.toHaveBeenCalled();
		expect(world.countries.get(1)?.count).toBe(10);
		expect(world.countries.get(2)?.count).toBe(1);
		for (const player of world.players.values()) player.direction = "idle";
		expect(world.dirtyCountries.size).toBeGreaterThan(0);
		world.tick(1);
		expect(fill).not.toHaveBeenCalled();
	} finally {
		fill.mockRestore();
	}
});

test("enclosures use the completed tick, including a later mover's breach", () => {
	const pixels: Pixel[] = [[33, 33, 2]];
	for (let y = 30; y <= 36; y++)
		for (let x = 30; x <= 36; x++)
			if (
				(x === 30 || x === 36 || y === 30 || y === 36) &&
				!(x === 33 && y === 36)
			)
				pixels.push([x, y, 1]);
	const { world, actor, owner } = scenario(pixels);
	const closer = actor("closer", 1, 32, 36);
	closer.direction = "right";
	closer.credit = 1;
	const breacher = actor("breacher", 2, 29, 33);
	breacher.direction = "right";
	breacher.credit = 3;
	world.tick(0);
	expect(owner(33, 36)).toBe(1);
	expect(owner(30, 33)).toBe(2);
	expect(owner(33, 33)).toBe(2);
	expect(owner(32, 32)).toBe(0);
});

test("later movers preserve enclosure searches when they paint over queued starts", () => {
	const pixels: Pixel[] = [[32, 32, 2]];
	for (let y = 30; y <= 34; y++)
		for (let x = 30; x <= 36; x++)
			if (y !== 32 || x < 32) pixels.push([x, y, 1]);
	const { world, actor, owner } = scenario(pixels);
	// Close the corridor, then consume two successive search starts in one tick.
	for (const x of [36, 35, 34]) {
		const mover = actor(String(x), 1, x, 31);
		mover.direction = "down";
		mover.credit = 1;
	}
	world.tick(0);
	for (const player of world.players.values()) player.direction = "idle";
	expect(owner(32, 32)).toBe(1);
	expect(owner(33, 32)).toBe(1);
	for (let tick = 1; tick <= 100; tick++) world.tick(tick);
	expect(owner(32, 32)).toBe(1);
	expect(owner(33, 32)).toBe(1);
});

test("own-territory and water movement do not schedule enclosure scans", () => {
	const { actor, move } = scenario(
		[
			[30, 30, 1],
			[31, 30, 1],
		],
		[[32, 30]],
	);
	actor("walker", 1, 30, 30);
	const fill = spyOn(HoleFiller.prototype, "fill");
	try {
		move("walker", "right");
		move("walker", "right");
		expect(fill).not.toHaveBeenCalled();
	} finally {
		fill.mockRestore();
	}
});

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: two independent loop fixtures exercise batching in one tick.
test("teammates closing two small loops in one tick resolve both without a scan", () => {
	const pixels: Pixel[] = [];
	for (const left of [30, 40])
		for (let y = 30; y <= 32; y++)
			for (let x = left; x <= left + 2; x++)
				if (
					x === left ||
					x === left + 2 ||
					y === 30 ||
					(y === 32 && x !== left + 1)
				)
					pixels.push([x, y, 1]);
	const { world, actor, owner } = scenario(pixels);
	for (const left of [30, 40]) {
		const player = actor(String(left), 1, left, 32);
		player.direction = "right";
		player.credit = 1;
	}
	const fill = spyOn(HoleFiller.prototype, "fill");
	try {
		world.tick(0);
		expect(fill).not.toHaveBeenCalled();
		expect(owner(31, 31)).toBe(1);
		expect(owner(41, 31)).toBe(1);
		for (const player of world.players.values()) player.direction = "idle";
		world.tick(1);
		expect(fill).not.toHaveBeenCalled();
	} finally {
		fill.mockRestore();
	}
});

// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: both loops exceed the shared local budget and must resolve in one fallback scan.
test("two large closures in one country trigger only one fallback scan", () => {
	const pixels: Pixel[] = [];
	for (const left of [30, 80])
		for (let y = 30; y < 70; y++)
			for (let x = left; x < left + 40; x++)
				if (
					(x === left || x === left + 39 || y === 30 || y === 69) &&
					!(x === left + 20 && y === 69)
				)
					pixels.push([x, y, 1]);
	const { world, actor, owner } = scenario(pixels);
	for (const left of [30, 80]) {
		const player = actor(String(left), 1, left + 19, 69);
		player.direction = "right";
		player.credit = 1;
	}
	const fill = spyOn(HoleFiller.prototype, "fill");
	try {
		world.tick(0);
		expect(fill).toHaveBeenCalledTimes(1);
		expect(owner(50, 50)).toBe(1);
		expect(owner(100, 50)).toBe(1);
		expect(world.countries.get(1)?.count).toBe(3200);
	} finally {
		fill.mockRestore();
	}
});

test("defensive reclaim still runs beside an enclosed water pixel", () => {
	const pixels: Pixel[] = [];
	for (let y = 30; y <= 34; y++)
		for (let x = 30; x <= 34; x++)
			if (x !== 32 || y !== 32) pixels.push([x, y, 1]);
	const { actor, move, owner } = scenario(pixels, [[32, 32]]);
	actor("invader", 2, 31, 32);
	move("invader", "right");
	const fill = spyOn(HoleFiller.prototype, "fill");
	try {
		move("invader", "up");
		expect(fill).not.toHaveBeenCalled();
		expect(owner(32, 31)).toBe(1);
		expect(owner(32, 32)).toBe(0);
	} finally {
		fill.mockRestore();
	}
});

test("gated ticks match unconditional fills and leave no holes after inter-country cascades", () => {
	const { world } = scenario(
		[],
		[
			[32, 32],
			[33, 34],
			[34, 33],
		],
	);
	world.countries.set(3, {
		id: "3",
		code: 3,
		name: "3",
		color: "red",
		count: 0,
	});
	const reference = new World(world.land);
	for (const country of world.countries.values())
		reference.countries.set(country.code, { ...country });
	const referenceClaim = Reflect.get(reference, "claim").bind(reference);
	Reflect.set(reference, "claim", (cell: number, code: number) => {
		const owner = reference.owners[cell];
		const changed = reference.land[cell] && owner !== code;
		referenceClaim(cell, code);
		if (changed) {
			const pending = Reflect.get(reference, "enclosureCountries");
			pending.set(code, null);
			if (owner) pending.set(owner, null);
		}
	});
	let random = 123;
	const next = () => {
		random = (Math.imul(random, 1664525) + 1013904223) >>> 0;
		return random >>> 16;
	};
	for (let tick = 0; tick < 1000; tick++) {
		for (let move = 0; move < 8; move++) {
			const cell = (30 + (next() % 8)) * WIDTH + 30 + (next() % 8);
			const code = 1 + (next() % 3);
			Reflect.get(world, "claim").call(world, cell, code);
			Reflect.get(reference, "claim").call(reference, cell, code);
		}
		world.tick(tick);
		reference.tick(tick);
		for (let y = 30; y < 38; y++)
			expect(world.owners.subarray(y * WIDTH + 30, y * WIDTH + 38)).toEqual(
				reference.owners.subarray(y * WIDTH + 30, y * WIDTH + 38),
			);
		expect([...world.countries.values()]).toEqual([
			...reference.countries.values(),
		]);
		// Include an unowned halo so the independent flood sees the world exterior.
		const cells = Array.from(
			{ length: 100 },
			(_, i) => (29 + Math.floor(i / 10)) * WIDTH + 29 + (i % 10),
		);
		const owners = Uint16Array.from(cells, (cell) => world.owners[cell]);
		for (const code of world.countries.keys()) {
			const labels = referenceFill(owners, 10, code);
			expect(
				cells.filter((cell, i) => world.land[cell] && labels[i] === 0),
			).toEqual([]);
		}
	}
});
