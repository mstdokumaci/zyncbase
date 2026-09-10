import { type BotPlan, planBot } from "./bots";
import {
	hasStraightExit,
	LOCAL_SEARCH_BUDGET,
	localEnclosures,
	mayEnclose,
} from "./enclosure";
import { type Bounds, HoleFiller } from "./filler";
import {
	CHUNK,
	type ChunkRow,
	COLUMNS,
	COUNTRY_COLORS,
	type Country,
	chunkIndex,
	countryName,
	type Direction,
	type Dot,
	encoder,
	HEIGHT,
	INPUT_LEASE_MS,
	MAX_COUNTRIES,
	MAX_PLAYERS,
	playerName,
	RULES,
	readOwners,
	rowId,
	WIDTH,
} from "./shared";

type Player = Dot & {
	direction: Direction;
	credit: number;
	heardAt: number;
	plan?: BotPlan;
	thinkAt?: number;
};
const steps = {
	idle: [0, 0],
	up: [0, -1],
	down: [0, 1],
	left: [-1, 0],
	right: [1, 0],
};
const botCountries = [
	"Bot · Amber",
	"Bot · Coral",
	"Bot · Fern",
	"Bot · Indigo",
	"Bot · Pearl",
];

export class World {
	readonly owners = new Uint16Array(WIDTH * HEIGHT);
	readonly players = new Map<string, Player>();
	readonly countries = new Map<number, Country>();
	readonly dirtyChunks = new Set<number>();
	readonly dirtyCountries = new Set<number>();
	readonly dirtyRemovedCountries = new Set<number>();
	inputMessages = 0;
	ticks = 0;
	private nextCode = 1;
	private botsEnabled = false;
	private readonly filler = new HoleFiller(WIDTH, HEIGHT);
	private readonly bounds = new Map<number, Bounds>();
	private readonly changedCountries = new Set<number>();
	private readonly enclosureCountries = new Map<number, Set<number> | null>();

	constructor(readonly land: Uint8Array) {}

	get humanCount() {
		return [...this.players.values()].filter((player) => !player.bot).length;
	}

	/** Next unallocated country code; persisted so retired codes never repeat. */
	get allocatorMark() {
		return this.nextCode;
	}

	startBots(now: number) {
		this.botsEnabled = true;
		this.populateBots(now);
	}

	private populateBots(now: number) {
		const target = Math.max(0, 10 - Math.floor(this.humanCount / 2));
		for (let i = 0; i < 10; i++) {
			const id = `bot:${i}`;
			if (i >= target) this.remove(id);
			else if (!this.players.has(id)) {
				const country = this.country(botCountries[Math.floor(i / 2)]);
				if (country) this.add(id, country, now, true);
			}
		}
	}

	private steerBot(player: Player) {
		if (!player.plan?.cells.length && this.ticks >= (player.thinkAt ?? 0)) {
			player.plan = planBot(this, player);
			player.thinkAt = this.ticks + 20;
		}
		const next = player.plan?.cells[0];
		if (next === undefined) {
			player.direction = "idle";
			return;
		}
		const dx = (next % WIDTH) - player.x;
		const dy = Math.floor(next / WIDTH) - player.y;
		player.direction = dx
			? dx > 0
				? "right"
				: "left"
			: dy > 0
				? "down"
				: "up";
	}

	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: one pass restores the bitmap and recomputes its counts together.
	restore(countries: Country[], chunks: ChunkRow[], persistedNextCode = 0) {
		for (const country of countries) {
			const { id, code, name, color } = country;
			this.countries.set(code, {
				id,
				code,
				name,
				color,
				count: 0,
			});
			this.dirtyCountries.add(country.code);
		}
		// The allocator mark lives outside the country rows so retired codes
		// stay retired: restore it before pruning, never recompute it from
		// the survivors alone.
		this.nextCode = Math.max(
			persistedNextCode,
			Math.max(0, ...this.countries.keys()) + 1,
		);
		for (const chunk of chunks) {
			const owners = readOwners(chunk.owners);
			const x = (chunk.index % COLUMNS) * CHUNK;
			const y = Math.floor(chunk.index / COLUMNS) * CHUNK;
			for (let i = 0; i < owners.length; i++) {
				const px = x + (i % CHUNK);
				const py = y + Math.floor(i / CHUNK);
				if (px >= WIDTH || py >= HEIGHT) continue;
				this.owners[py * WIDTH + px] = owners[i];
				if (owners[i]) {
					const country = this.countries.get(owners[i]);
					if (!country)
						throw new Error("Saved territory has an unknown country");
					country.count++;
					this.extendBounds(country.code, py * WIDTH + px);
					this.changedCountries.add(country.code);
					this.enclosureCountries.set(country.code, null);
				}
			}
			// Reconcile dots before admitting players after a restart.
			if (chunk.occupied) this.dirtyChunks.add(chunk.index);
		}
		// No players exist yet after a restart, so zero-land countries are
		// abandoned by definition: drop them and free their names for reuse.
		for (const [code, country] of this.countries) {
			if (country.count === 0) {
				this.countries.delete(code);
				this.dirtyCountries.delete(code);
				this.dirtyRemovedCountries.add(code);
			}
		}
		this.fillEnclosures();
	}

	country(value: unknown) {
		const name = countryName(value);
		const existing = [...this.countries.values()].find(
			(c) => c.name.toLowerCase() === name.toLowerCase(),
		);
		if (existing) return existing;
		// Newcomers join existing countries once the world is full of them.
		if (this.countries.size >= MAX_COUNTRIES) return undefined;
		// Codes never repeat, so a removed row and a later row never collide
		// inside one publication batch.
		const code = this.nextCode++;
		if (code > 65535)
			throw new Error("Country storage is full; reset the world");
		const used = new Set([...this.countries.values()].map((c) => c.color));
		const color = COUNTRY_COLORS.find((color) => !used.has(color));
		if (!color) throw new Error("No country colors available");
		const country = {
			id: rowId(code),
			code,
			name,
			color,
			count: 0,
		};
		this.countries.set(code, country);
		this.dirtyCountries.add(code);
		return country;
	}

	// A country with no land and no live holders is gone: its slot and name
	// become available for newcomers. Zero-land countries with live players
	// stay, so roaming dots keep their identity.
	maybeDeleteCountry(code: number) {
		const country = this.countries.get(code);
		if (!country || country.count !== 0) return;
		for (const player of this.players.values())
			if (player.code === code) return;
		this.countries.delete(code);
		this.bounds.delete(code);
		this.enclosureCountries.delete(code);
		this.changedCountries.delete(code);
		this.dirtyCountries.delete(code);
		this.dirtyRemovedCountries.add(code);
	}

	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: the ring search first preserves spacing, then admits players on cramped land.
	private spawn(code: number, bot: boolean, team: number) {
		const center = [...this.players.values()].find((player) => !player.bot) ?? {
			x: 933,
			y: 276,
		};
		const angle = (team * Math.PI * 2) / botCountries.length - Math.PI / 2;
		const anchor = bot
			? {
					x: center.x + Math.round(Math.cos(angle) * 48),
					y: center.y + Math.round(Math.sin(angle) * 48),
				}
			: center;
		const occupied = new Set(
			[...this.players.values()].map((p) => p.y * WIDTH + p.x),
		);
		const clearances = [...this.players.values()].map((other) => ({
			x: other.x,
			y: other.y,
			radius: bot || other.bot ? (code === other.code ? 12 : 28) : 1,
		}));
		if (bot) clearances.push({ x: center.x, y: center.y, radius: 28 });
		// Prefer breathing room, but tiny islands must still admit players on free land.
		for (const spaced of [true, false]) {
			for (
				let radius = 0;
				radius < (spaced ? 128 : Math.max(WIDTH, HEIGHT));
				radius++
			) {
				for (let d = -radius; d <= radius; d++) {
					const candidates = [
						{ x: anchor.x + d, y: anchor.y - radius },
						{ x: anchor.x + d, y: anchor.y + radius },
						{ x: anchor.x - radius, y: anchor.y + d },
						{ x: anchor.x + radius, y: anchor.y + d },
					];
					const position = candidates.find(
						({ x, y }) =>
							x >= 0 &&
							x < WIDTH &&
							y >= 0 &&
							y < HEIGHT &&
							this.land[y * WIDTH + x] &&
							!occupied.has(y * WIDTH + x) &&
							(!spaced ||
								clearances.every(
									(other) =>
										Math.hypot(x - other.x, y - other.y) >= other.radius,
								)),
					);
					if (position) return position;
				}
			}
		}
		throw new Error("No available land");
	}

	private add(id: string, country: Country, now: number, bot = false) {
		const position = this.spawn(
			country.code,
			bot,
			botCountries.indexOf(country.name),
		);
		const player: Player = {
			id,
			...position,
			code: country.code,
			seq: -1,
			sentAt: 0,
			direction: "idle",
			credit: 0,
			heardAt: now,
			bot,
		};
		this.players.set(id, player);
		this.dirtyChunks.add(chunkIndex(player.x, player.y));
		return player;
	}

	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: keep untrusted input validation adjacent to player admission.
	input(id: string, data: Record<string, unknown>, now: number) {
		const direction = data.direction;
		if (typeof direction !== "string" || !Object.hasOwn(steps, direction))
			return;
		if (!Number.isSafeInteger(data.seq) || Number(data.seq) < 0) return;
		if (typeof data.sentAt !== "number" || !Number.isFinite(data.sentAt))
			return;
		let player = this.players.get(id);
		if (!player) {
			if (this.humanCount >= MAX_PLAYERS) return;
			if (!Number.isSafeInteger(data.countryCode)) return;
			const country = this.countries.get(Number(data.countryCode));
			if (!country) return;
			let nickname: string;
			try {
				nickname = playerName(data.name);
			} catch {
				return;
			}
			player = this.add(id, country, now);
			player.name = nickname;
		}
		this.inputMessages++;
		player.heardAt = now;
		if (Number(data.seq) < player.seq) return;
		if (player.seq !== data.seq)
			this.dirtyChunks.add(chunkIndex(player.x, player.y));
		player.seq = Number(data.seq);
		player.sentAt = data.sentAt;
		player.direction = direction as Direction;
	}

	remove(id: string) {
		const player = this.players.get(id);
		if (!player) return;
		this.dirtyChunks.add(chunkIndex(player.x, player.y));
		this.players.delete(id);
		this.maybeDeleteCountry(player.code);
	}

	tick(now: number) {
		this.ticks++;
		for (const player of this.players.values()) {
			if (player.bot) continue;
			if (now - player.heardAt > INPUT_LEASE_MS * 5) {
				this.remove(player.id);
				continue;
			}
			if (now - player.heardAt > INPUT_LEASE_MS) player.direction = "idle";
			this.move(player);
		}
		this.tickBots(now);
		this.fillEnclosures();
	}

	private tickBots(now: number) {
		if (!this.botsEnabled) return;
		this.populateBots(now);
		// Empty worlds wait for people, so territory is not consumed between sessions.
		if (!this.humanCount) return;
		for (const player of this.players.values()) {
			if (!player.bot) continue;
			if (!player.credit) this.steerBot(player);
			this.move(player);
			if (player.plan?.cells[0] === player.y * WIDTH + player.x)
				player.plan.cells.shift();
		}
	}

	stepCost(code: number, from: number, to: number, owner = this.owners[to]) {
		let cost = RULES.neutral;
		if (this.land[to] && owner) cost = owner === code ? RULES.own : RULES.enemy;
		if (this.land[from] !== this.land[to]) cost += RULES.crossing;
		return cost;
	}

	private move(player: Player) {
		if (player.direction === "idle") return;
		const [dx, dy] = steps[player.direction];
		const x = player.x + dx,
			y = player.y + dy;
		if (x < 0 || x >= WIDTH || y < 0 || y >= HEIGHT) {
			player.credit = 0;
			return;
		}
		const from = player.y * WIDTH + player.x,
			to = y * WIDTH + x;
		const owner = this.owners[to];
		const cost = this.stepCost(player.code, from, to);
		if (++player.credit < cost) return;
		player.credit = 0;
		this.dirtyChunks.add(chunkIndex(player.x, player.y));
		player.x = x;
		player.y = y;
		this.dirtyChunks.add(chunkIndex(x, y));
		if (!this.land[to] || owner === player.code) return;
		this.claim(to, player.code);
	}

	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: each affected country fills and updates ownership at most once.
	private fillEnclosures() {
		if (!this.enclosureCountries.size) {
			this.changedCountries.clear();
			return;
		}
		// Keep entries until the pass ends: captures can append affected countries,
		// but each country runs at most once, in first-change order.
		for (const code of this.changedCountries) {
			if (
				!this.enclosureCountries.has(code) ||
				!this.countries.get(code)?.count
			)
				continue;
			const box = this.bounds.get(code);
			if (!box) continue;
			const starts = this.enclosureCountries.get(code);
			// A processed country needs no more candidates from its own captures.
			this.enclosureCountries.set(code, null);
			const local = starts
				? localEnclosures(this.owners, code, starts, box, WIDTH)
				: undefined;
			if (local) {
				for (const cell of local) this.claim(cell, code, true);
				continue;
			}
			// Filling only grows a country inside its original bounds. Other
			// countries only shrink, so these bounds stay safe throughout the pass.
			const labels = this.filler.fill(this.owners, code, box);
			for (let y = box.top; y <= box.bottom; y++) {
				const end = y * WIDTH + box.right;
				for (let cell = y * WIDTH + box.left; cell <= end; cell++)
					if (labels[cell] === 0 && this.land[cell])
						this.claim(cell, code, true);
			}
		}
		this.changedCountries.clear();
		this.enclosureCountries.clear();
	}

	private queueEnclosure(code: number, cell: number) {
		let starts = this.enclosureCountries.get(code);
		if (starts === null) return;
		if (!starts) {
			starts = new Set();
			this.enclosureCountries.set(code, starts);
		}
		if (starts.size === LOCAL_SEARCH_BUDGET)
			this.enclosureCountries.set(code, null);
		else starts.add(cell);
	}

	private extendBounds(code: number, cell: number) {
		// bounds only grow; recompute after losses if loose bounds become costly.
		const x = cell % WIDTH,
			y = Math.floor(cell / WIDTH);
		const box = this.bounds.get(code);
		if (!box) this.bounds.set(code, { left: x, right: x, top: y, bottom: y });
		else {
			box.left = Math.min(box.left, x);
			box.right = Math.max(box.right, x);
			box.top = Math.min(box.top, y);
			box.bottom = Math.max(box.bottom, y);
		}
	}

	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: update both owners and collect bounded enclosure candidates at their shared mutation point.
	private claim(cell: number, code: number, fromFill = false) {
		const owner = this.owners[cell];
		if (!this.land[cell] || owner === code) return;
		this.owners[cell] = code;
		this.extendBounds(code, cell);
		this.changedCountries.add(code);
		const starts = this.enclosureCountries.get(code);
		if (
			starts !== null &&
			// A later claim can consume a queued start while its hole still exists.
			(starts?.has(cell) || mayEnclose(this.owners, code, cell, WIDTH))
		) {
			const x = cell % WIDTH;
			if (cell >= WIDTH) this.queueEnclosure(code, cell - WIDTH);
			if (x < WIDTH - 1) this.queueEnclosure(code, cell + 1);
			if (cell < this.owners.length - WIDTH)
				this.queueEnclosure(code, cell + WIDTH);
			if (x > 0) this.queueEnclosure(code, cell - 1);
		}
		this.dirtyChunks.add(chunkIndex(cell % WIDTH, Math.floor(cell / WIDTH)));
		const country = this.countries.get(code);
		if (country) country.count++;
		this.dirtyCountries.add(code);
		if (!owner) return;
		const previous = this.countries.get(owner);
		if (previous) previous.count--;
		this.dirtyCountries.add(owner);
		this.changedCountries.add(owner);
		if (previous?.count === 0) this.maybeDeleteCountry(owner);
		if (!previous?.count) return;
		const box = this.bounds.get(owner);
		// A loss needs reclaim unless we can prove this pixel still reaches
		// the exterior. Keep any scan already required by an earlier change.
		if (
			this.enclosureCountries.get(owner) !== null &&
			// Bulk captures enqueue in constant time per pixel; their bounded
			// local check or one full scan decides reclaim later in this pass.
			(fromFill ||
				!box ||
				!hasStraightExit(this.owners, owner, cell, WIDTH, box))
		)
			this.queueEnclosure(owner, cell);
	}

	chunk(index: number): ChunkRow {
		const x = (index % COLUMNS) * CHUNK,
			y = Math.floor(index / COLUMNS) * CHUNK;
		const owners = new Uint8Array(CHUNK * CHUNK * 2);
		const view = new DataView(owners.buffer);
		for (let dy = 0; dy < CHUNK; dy++) {
			for (let dx = 0; dx < CHUNK; dx++) {
				const code =
					x + dx < WIDTH && y + dy < HEIGHT
						? this.owners[(y + dy) * WIDTH + x + dx]
						: 0;
				view.setUint16((dy * CHUNK + dx) * 2, code, true);
			}
		}
		const dots: Dot[] = [...this.players.values()]
			.filter((p) => chunkIndex(p.x, p.y) === index)
			.map(({ id, name, code, x, y, seq, sentAt, bot }) => ({
				id,
				name,
				code,
				x,
				y,
				seq,
				sentAt,
				bot,
			}));
		return {
			id: rowId(index),
			index,
			owners,
			dots: encoder.encode(JSON.stringify(dots)),
			occupied: dots.length > 0,
		};
	}
}
