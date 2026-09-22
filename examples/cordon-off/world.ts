import { BOT_SIDES, type BotPlan, enemyRays, planBot, roamPlan } from "./bots";
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
	COUNTRY_COLOR_INDEX,
	COUNTRY_COLORS,
	type Country,
	chunkIndex,
	countryName,
	type Direction,
	type Dot,
	decoder,
	encoder,
	HEIGHT,
	INPUT_LEASE_MS,
	MAX_COUNTRIES,
	MAX_PLAYERS,
	PLAYER_GRACE_MS,
	type PlayerRow,
	playerName,
	RULES,
	readOwners,
	rowId,
	WIDTH,
	wrapX,
} from "./shared";

type Player = {
	id: string;
	name?: string;
	country_id: number;
	is_bot: boolean;
	last_x: number;
	last_y: number;
	x: number;
	y: number;
	seq: number;
	direction: Direction;
	credit: number;
	heardAt: number;
	// Spawn point whose bots this player's crowd calls in. Every human has
	// one; bots carry none.
	point?: number;
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
// One playful country per spawn point, named after where its bots come from.
// Humans may never create or join these (see reservedBotCountry).
const botCountries = [
	"Polandia",
	"Switzerstan",
	"Ruskovia",
	"Mongolonia",
	"Saudistan",
	"Central Afrikia",
	"Aussieland",
	"Brasilandia",
	"United Stakes",
];
// Spawn points unlock in waves of three: Warsaw/Zurich/Moscow confine early
// players to Europe, Ulaanbaatar/Riyadh/Bangui expand over Eurasia and
// Africa once those are in use, and the last three open once the first six
// are full. Pixel coordinates use the land.json crop: longitude −135…180°,
// latitude −60…85°.
const SPAWN_POINTS = [
	{ x: 990, y: 226 }, // Warsaw
	{ x: 911, y: 259 }, // Zurich
	{ x: 1095, y: 201 }, // Moscow
	{ x: 1535, y: 256 }, // Ulaanbaatar
	{ x: 1153, y: 416 }, // Riyadh
	{ x: 974, y: 555 }, // Bangui
	{ x: 1688, y: 760 }, // Yulara
	{ x: 553, y: 694 }, // Brasília
	{ x: 190, y: 312 }, // Denver
];
const SPAWN_WAVE = 3;
const SPAWN_BUCKET_SHIFT = 4;
const SPAWN_BUCKET_COLUMNS = Math.ceil(WIDTH / (1 << SPAWN_BUCKET_SHIFT));
const SPAWN_BUCKET_ROWS = Math.ceil(HEIGHT / (1 << SPAWN_BUCKET_SHIFT));
const SPAWN_OWNED_CELL_BUDGET = 1 << 16;
const SPAWN_OWN_RADIUS = 32;
const GOLDEN_ANGLE = 2.399963229728653;

/** Bot country names stay reserved even before their country exists. */
export function reservedBotCountry(value: unknown) {
	try {
		const name = countryName(value).toLowerCase();
		return botCountries.some((country) => country.toLowerCase() === name);
	} catch {
		return false;
	}
}
// Chunk owner bytes are byte-per-cell palette codes; readOwners validates them.

export class World {
	readonly owners = new Uint16Array(WIDTH * HEIGHT);
	// Country id -> wire owner code (0 = unowned). Filled eagerly for created
	// and restored countries and lazily for directly injected rows, so only
	// countries with a palette color can paint chunk bytes.
	private readonly ownerCodes = new Uint8Array(65536);
	readonly players = new Map<string, Player>();
	readonly countries = new Map<number, Country>();
	readonly dirtyChunks = new Set<number>();
	readonly dirtyCountries = new Set<number>();
	readonly dirtyRemovedCountries = new Set<number>();
	readonly dirtyPlayerRows = new Set<string>();
	readonly dirtyRemovedPlayerRows = new Set<string>();
	// Departed players kept briefly for same-id grace reconnects: store row
	// (with final position) lingers, live map entry is gone immediately so
	// ghosts never draw, block spawns, or pin countries.
	private readonly graveyard = new Map<
		string,
		{ row: PlayerRow; expires: number; point?: number }
	>();
	inputMessages = 0;
	ticks = 0;
	private nextCountryId = 1;
	private botsEnabled = false;
	// Human spawn cursor: drives round-robin point selection and the golden-
	// angle spiral inside each point.
	private spawnCount = 0;
	// Bot jitter (patch size, roam direction, pauses). Seeded so profile runs
	// stay reproducible and their checksums remain comparable.
	private rng = 0x9e3779b9;
	private readonly filler = new HoleFiller(WIDTH, HEIGHT);
	private readonly bounds = new Map<number, Bounds>();
	private readonly changedCountries = new Set<number>();
	private readonly enclosureCountries = new Map<number, Set<number> | null>();
	// Spawn-point wave latch: 1 = first three points, 2 = six, 3 = all nine.
	private wave = 1;

	constructor(readonly land: Uint8Array) {}

	get humanCount() {
		return [...this.players.values()].filter((player) => !player.is_bot).length;
	}

	/** Cold roster value for publishing (id rides in the path, not the body). */
	playerRow(id: string): Omit<PlayerRow, "id"> | undefined {
		const player = this.players.get(id);
		if (player) {
			const row: Omit<PlayerRow, "id"> = {
				country_id: player.country_id,
				is_bot: player.is_bot,
				last_x: player.last_x,
				last_y: player.last_y,
			};
			if (player.name !== undefined) row.name = player.name;
			return row;
		}
		const grave = this.graveyard.get(id);
		if (!grave) return undefined;
		const { id: _dropped, ...row } = grave.row;
		return row;
	}

	/** Next unallocated country id; persisted so retired ids never repeat. */
	get allocatorMark() {
		return this.nextCountryId;
	}

	startBots(now: number) {
		this.botsEnabled = true;
		this.populateBots(now);
	}

	// Bots are per spawn point: two join the point's first human, one stays
	// while it holds two or three, and a fourth human retires them. A point
	// with no humans has no bots and no bot country until one is needed.
	private populateBots(now: number) {
		const active = this.activePointCount();
		const humans = this.humansPerPoint();
		for (let i = 0; i < SPAWN_POINTS.length * 2; i++) {
			const id = `bot-${i}`;
			const point = i >> 1;
			if (point >= active || (i & 1) >= this.botTarget(humans[point] ?? 0))
				this.remove(id, now);
			else if (!this.players.has(id)) {
				const country = this.country(botCountries[point] as string, true);
				if (country) this.add(id, country, now, true, i);
			}
		}
	}

	/** Two bots for a point's first human, one for two or three, none after. */
	private botTarget(humans: number) {
		if (humans === 0 || humans >= 4) return 0;
		return humans === 1 ? 2 : 1;
	}

	private random() {
		this.rng = (Math.imul(this.rng, 1664525) + 1013904223) >>> 0;
		return this.rng / 0x1_0000_0000;
	}

	/** Usually a beat; occasionally a visible pause, like re-reading the map. */
	private pauseTicks() {
		return this.random() < 0.25
			? 10 + Math.floor(this.random() * 20)
			: Math.floor(this.random() * 4);
	}

	/** Never picks a vertical direction that a pole would empty. */
	private roamDirection(player: Player): Exclude<Direction, "idle"> {
		const directions: Exclude<Direction, "idle">[] = [
			"up",
			"down",
			"left",
			"right",
		];
		const open = directions.filter(
			(direction) =>
				(direction !== "up" || player.y > 0) &&
				(direction !== "down" || player.y < HEIGHT - 1),
		);
		return open[Math.floor(this.random() * open.length)] as Exclude<
			Direction,
			"idle"
		>;
	}

	private pickSide() {
		return BOT_SIDES[Math.floor(this.random() * BOT_SIDES.length)] ?? 9;
	}

	/** A roam ends at its goal: claimable land for seek, safe land for flee. */
	private roamAhead(player: Player) {
		const plan = player.plan;
		const ahead = plan?.cells[0];
		if (!plan?.roam || ahead === undefined || !this.land[ahead]) return;
		const owner = this.owners[ahead];
		const done =
			plan.roam === "seek"
				? owner !== player.country_id
				: owner === 0 || owner === player.country_id;
		if (!done) return;
		player.plan = undefined;
		player.thinkAt = this.ticks;
	}

	/**
	 * Cut off inside enemy land: run for safe ground instead of painting.
	 * A fresh escape picks a random heading; chained segments keep it straight.
	 */
	private escape(player: Player) {
		const plan = player.plan;
		if (plan?.roam === "flee" && plan.cells.length) return;
		if (enemyRays(this, player) < 7) return;
		const direction =
			plan?.roam === "flee" && player.direction !== "idle"
				? player.direction
				: this.roamDirection(player);
		player.plan = roamPlan(player, this.pickSide(), direction, "flee");
		player.thinkAt = this.ticks + 20;
	}

	/** Plan a sweep, or roam when the local window has nothing left to claim. */
	private think(player: Player) {
		if (player.plan?.cells.length || this.ticks < (player.thinkAt ?? 0)) return;
		const side = this.pickSide();
		player.plan =
			planBot(this, player, side) ??
			roamPlan(player, side, this.roamDirection(player));
		player.thinkAt = this.ticks + 20;
	}

	private steerBot(player: Player) {
		this.roamAhead(player);
		this.escape(player);
		this.think(player);
		const next = player.plan?.cells[0];
		if (next === undefined) {
			player.direction = "idle";
			return;
		}
		let dx = (next % WIDTH) - player.x;
		// The world wraps horizontally: a planned step across the seam must
		// steer the short way (0 -> WIDTH-1 is left, not right).
		if (dx > WIDTH / 2) dx -= WIDTH;
		else if (dx < -WIDTH / 2) dx += WIDTH;
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
	restore(
		countries: Country[],
		chunks: ChunkRow[],
		players: { id: string }[] = [],
		persistedNextCountryId = 0,
	) {
		// Palette code -> country id when decoding chunk bytes; country ids
		// start at 1, so 0 unambiguously marks "no country".
		const byCode = new Uint16Array(MAX_COUNTRIES + 1);
		for (const country of countries) {
			const { country_id, name, color, is_bot } = country;
			this.countries.set(country_id, {
				country_id,
				name,
				color,
				count: 0,
				is_bot,
			});
			const code = COUNTRY_COLOR_INDEX.get(color);
			if (code !== undefined) {
				if (byCode[code])
					throw new Error("Saved countries share a palette color");
				byCode[code] = country_id;
				this.ownerCodes[country_id] = code;
			}
			this.dirtyCountries.add(country_id);
		}
		// The allocator mark lives outside the country rows so retired ids
		// stay retired: restore it before pruning, never recompute it from
		// the survivors alone.
		this.nextCountryId = Math.max(
			persistedNextCountryId,
			Math.max(0, ...this.countries.keys()) + 1,
		);
		for (const chunk of chunks) {
			const index = Number(chunk.id);
			// Reject negatives (whose cells dodge the per-cell bounds check
			// below and would corrupt counts/bounds) and out-of-range ids.
			if (
				!Number.isSafeInteger(index) ||
				index < 0 ||
				index >= COLUMNS * Math.ceil(HEIGHT / CHUNK)
			)
				continue;
			const owners = readOwners(chunk.owners);
			const x = (index % COLUMNS) * CHUNK;
			const y = Math.floor(index / COLUMNS) * CHUNK;
			for (let i = 0; i < owners.length; i++) {
				const px = x + (i % CHUNK);
				const py = y + Math.floor(i / CHUNK);
				if (px >= WIDTH || py >= HEIGHT) continue;
				const code = owners[i];
				const countryId = code ? byCode[code] : 0;
				if (code && !countryId)
					throw new Error("Saved territory has an unknown country");
				this.owners[py * WIDTH + px] = countryId;
				if (countryId) {
					const country = this.countries.get(countryId);
					if (!country)
						throw new Error("Saved territory has an unknown country");
					country.count++;
					this.extendBounds(countryId, py * WIDTH + px);
					this.changedCountries.add(countryId);
					this.enclosureCountries.set(countryId, null);
				}
			}
			// Positions don't survive a restart (live map starts empty), so any
			// chunk persisting dots must be republished empty. Dots bytes are
			// small; decoding beats keeping a queryable flag for this one path.
			if (this.chunkHasDots(chunk)) this.dirtyChunks.add(index);
		}
		// Stale roster rows (including grace tombstones) never survive a
		// restart: the live map is empty, so queue them all for removal.
		for (const player of players) this.dirtyRemovedPlayerRows.add(player.id);
		// No players exist yet after a restart, so zero-land countries are
		// abandoned by definition: drop them and free their names for reuse.
		for (const [countryId, country] of this.countries) {
			if (country.count === 0) {
				this.countries.delete(countryId);
				this.ownerCodes[countryId] = 0;
				this.dirtyCountries.delete(countryId);
				this.dirtyRemovedCountries.add(countryId);
			}
		}
		this.fillEnclosures();
	}

	country(value: unknown, isBot = false) {
		const name = countryName(value);
		const existing = [...this.countries.values()].find(
			(c) => c.name.toLowerCase() === name.toLowerCase(),
		);
		if (existing) return existing;
		// Newcomers join existing countries once the world is full of them.
		if (this.countries.size >= MAX_COUNTRIES) return undefined;
		// Ids never repeat, so a removed row and a later row never collide
		// inside one publication batch.
		const countryId = this.nextCountryId++;
		if (countryId > 65535)
			throw new Error("Country storage is full; reset the world");
		const used = new Set([...this.countries.values()].map((c) => c.color));
		const color = COUNTRY_COLORS.find((color) => !used.has(color));
		if (!color) throw new Error("No country colors available");
		const code = COUNTRY_COLOR_INDEX.get(color);
		if (!code) throw new Error("No country colors available");
		const country = {
			country_id: countryId,
			name,
			color,
			count: 0,
			is_bot: isBot,
		};
		this.ownerCodes[countryId] = code;
		this.countries.set(countryId, country);
		this.dirtyCountries.add(countryId);
		return country;
	}

	// A country with no land and no live holders is gone: its slot and name
	// become available for newcomers. Zero-land countries with live players
	// stay, so roaming dots keep their identity.
	maybeDeleteCountry(countryId: number) {
		const country = this.countries.get(countryId);
		if (!country || country.count !== 0) return;
		// Grace tombstones never pin a country: only live holders count.
		for (const player of this.players.values())
			if (player.country_id === countryId) return;
		this.countries.delete(countryId);
		this.ownerCodes[countryId] = 0;
		this.bounds.delete(countryId);
		this.enclosureCountries.delete(countryId);
		this.changedCountries.delete(countryId);
		this.dirtyCountries.delete(countryId);
		this.dirtyRemovedCountries.add(countryId);
	}

	/** Non-bot players counted by the spawn point they came from. */
	private humansPerPoint() {
		const counts = new Array<number>(SPAWN_POINTS.length).fill(0);
		for (const player of this.players.values()) {
			if (player.is_bot || player.point === undefined) continue;
			counts[player.point] = (counts[player.point] ?? 0) + 1;
		}
		return counts;
	}

	// Waves latch and never revert: three points are enough while the world
	// is small, and players leaving must not re-confine later spawns.
	private activePointCount() {
		const used = this.humansPerPoint();
		if (
			this.wave === 1 &&
			used.slice(0, SPAWN_WAVE).every((count) => count > 0)
		)
			this.wave = 2;
		if (
			this.wave === 2 &&
			used.slice(0, SPAWN_WAVE * 2).every((count) => count >= 4)
		)
			this.wave = 3;
		return this.wave * SPAWN_WAVE;
	}

	/** Spiral outward from an anchor so joiners do not stack on the anchor. */
	private spiralAnchor(center: { x: number; y: number }, index: number) {
		const local = index % MAX_PLAYERS;
		const spread = 16 * Math.sqrt(local);
		const theta = local * GOLDEN_ANGLE;
		return {
			x: center.x + Math.round(Math.cos(theta) * spread),
			y: center.y + Math.round(Math.sin(theta) * spread),
		};
	}

	// Round-robin the active points, then spiral outward inside each one so
	// players in the same point still keep their distance.
	private humanAnchor(index: number) {
		const active = this.activePointCount();
		const point = index % active;
		const center = SPAWN_POINTS[point] as { x: number; y: number };
		const perCenter = Math.ceil(MAX_PLAYERS / active);
		const local = Math.floor(index / active) % perCenter;
		return { ...this.spiralAnchor(center, local), point };
	}

	/** Anchor on a cell: spiral outward, reading ownership from the bitmap. */
	private anchorAt(
		countryId: number,
		x: number,
		y: number,
		index: number,
		point?: number,
	) {
		return {
			...this.spiralAnchor({ x, y }, index),
			own: this.owners[y * WIDTH + x] === countryId,
			point,
		};
	}

	// One anchor chain for humans and bots: a live teammate (on own land when
	// possible), else the country's own land, else a spawn point. Bots take
	// their assigned point and spiral around its first human; humans round-
	// robin the active points.
	private spawnAnchor(
		countryId: number,
		bot: boolean,
		team: number,
	): { x: number; y: number; own: boolean; point?: number } {
		const teammates = [...this.players.values()].filter(
			(player) => player.country_id === countryId,
		);
		const mate =
			teammates.find(
				(player) => this.owners[player.y * WIDTH + player.x] === countryId,
			) ?? teammates[0];
		if (mate)
			return this.anchorAt(
				countryId,
				mate.x,
				mate.y,
				teammates.length,
				mate.point,
			);
		const owned = this.findOwnedCell(countryId);
		if (owned !== undefined)
			return this.anchorAt(
				countryId,
				owned % WIDTH,
				Math.floor(owned / WIDTH),
				0,
			);
		if (bot) {
			const point = team >> 1;
			const host = [...this.players.values()].find(
				(player) => !player.is_bot && player.point === point,
			);
			const center = host ?? (SPAWN_POINTS[point] as { x: number; y: number });
			return this.anchorAt(countryId, center.x, center.y, team & 1);
		}
		return { ...this.humanAnchor(this.spawnCount++), own: false };
	}

	/** First owned cell within the country's cached bounds, capped for safety. */
	private findOwnedCell(countryId: number) {
		const box = this.bounds.get(countryId);
		if (!box) return undefined;
		let budget = SPAWN_OWNED_CELL_BUDGET;
		for (let y = box.top; y <= box.bottom; y++) {
			for (
				let cell = y * WIDTH + box.left;
				cell <= y * WIDTH + box.right;
				cell++
			) {
				if (this.owners[cell] === countryId) return cell;
				if (--budget <= 0) return undefined;
			}
		}
		return undefined;
	}

	/** Bucket players by 16px cells so a spacing test is constant time. */
	private spacingBuckets(countryId: number) {
		const buckets = new Map<
			number,
			{ x: number; y: number; radiusSq: number }[]
		>();
		const add = (x: number, y: number, radiusSq: number) => {
			const key =
				(y >> SPAWN_BUCKET_SHIFT) * SPAWN_BUCKET_COLUMNS +
				(x >> SPAWN_BUCKET_SHIFT);
			const list = buckets.get(key);
			const entry = { x, y, radiusSq };
			if (list) list.push(entry);
			else buckets.set(key, [entry]);
		};
		// Humans and bots share one spacing rule; the spawn points keep each
		// region sparse enough for it to fit.
		for (const other of this.players.values())
			add(other.x, other.y, (countryId === other.country_id ? 12 : 28) ** 2);
		return buckets;
	}

	private bucketFits(
		list: { x: number; y: number; radiusSq: number }[] | undefined,
		x: number,
		y: number,
	) {
		if (!list) return true;
		for (const other of list) {
			const dx = x - other.x,
				dy = y - other.y;
			if (dx * dx + dy * dy < other.radiusSq) return false;
		}
		return true;
	}

	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: a bounded 5x5 bucket scan is clearer inline than split further.
	private fitsSpacing(
		buckets: Map<number, { x: number; y: number; radiusSq: number }[]>,
		x: number,
		y: number,
	) {
		const bx = x >> SPAWN_BUCKET_SHIFT;
		const by = y >> SPAWN_BUCKET_SHIFT;
		// A 28px reach spans at most two 16px buckets on either axis.
		for (let oy = -2; oy <= 2; oy++) {
			const row = by + oy;
			if (row < 0 || row >= SPAWN_BUCKET_ROWS) continue;
			for (let ox = -2; ox <= 2; ox++) {
				const col = bx + ox;
				if (col < 0 || col >= SPAWN_BUCKET_COLUMNS) continue;
				if (
					!this.bucketFits(buckets.get(row * SPAWN_BUCKET_COLUMNS + col), x, y)
				)
					return false;
			}
		}
		return true;
	}

	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: the ring search first preserves spacing, then admits players on cramped land.
	private spawn(countryId: number, bot: boolean, team: number) {
		const anchor = this.spawnAnchor(countryId, bot, team);
		const occupied = new Set(
			[...this.players.values()].map((p) => p.y * WIDTH + p.x),
		);
		const buckets = this.spacingBuckets(countryId);
		// An anchor on the country's own land prefers own cells first.
		const passes = anchor.own
			? [
					{ spaced: true, own: true },
					{ spaced: true, own: false },
					{ spaced: false, own: false },
				]
			: [
					{ spaced: true, own: false },
					{ spaced: false, own: false },
				];
		// Prefer breathing room, but tiny islands must still admit players on free land.
		for (const pass of passes) {
			// Spiral anchors can sit off-map; reach to the farthest corner
			// from the anchor, not just the map's larger dimension, or the
			// fallback can miss a strip on the far side.
			const reach = pass.own
				? SPAWN_OWN_RADIUS
				: pass.spaced
					? 128
					: Math.max(anchor.x, WIDTH - anchor.x, anchor.y, HEIGHT - anchor.y) +
						1;
			for (let radius = 0; radius < reach; radius++) {
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
							(!pass.spaced || this.fitsSpacing(buckets, x, y)) &&
							(!pass.own || this.owners[y * WIDTH + x] === countryId),
					);
					if (position) return { ...position, point: anchor.point };
				}
			}
		}
		throw new Error("No available land");
	}

	// Same-id grace reconnects resume their tombstone cell when it is still
	// free land; otherwise they fall through to the normal ring search.
	private spawnAt(
		countryId: number,
		bot: boolean,
		team: number,
		now: number,
		id: string,
	): Player {
		const grave = this.graveyard.get(id);
		if (grave) {
			this.graveyard.delete(id);
			this.dirtyRemovedPlayerRows.delete(id);
			const { last_x: x, last_y: y } = grave.row;
			if (
				x >= 0 &&
				x < WIDTH &&
				y >= 0 &&
				y < HEIGHT &&
				this.land[y * WIDTH + x] &&
				![...this.players.values()].some((p) => p.x === x && p.y === y)
			)
				return this.makePlayer(id, countryId, bot, x, y, now, grave.point);
		}
		const position = this.spawn(countryId, bot, team);
		return this.makePlayer(
			id,
			countryId,
			bot,
			position.x,
			position.y,
			now,
			position.point,
		);
	}

	private makePlayer(
		id: string,
		countryId: number,
		bot: boolean,
		x: number,
		y: number,
		now: number,
		point?: number,
	): Player {
		// Every human carries a point; joiners of existing territory round-robin
		// like fresh founders so the point's bots still spawn for them. Bots
		// carry none.
		if (!bot && point === undefined)
			point = this.humanAnchor(this.spawnCount++).point;
		const player: Player = {
			id,
			country_id: countryId,
			is_bot: bot,
			last_x: x,
			last_y: y,
			x,
			y,
			seq: -1,
			direction: "idle",
			credit: 0,
			heardAt: now,
			point,
		};
		this.players.set(id, player);
		this.dirtyChunks.add(chunkIndex(x, y));
		this.dirtyPlayerRows.add(id);
		return player;
	}

	private add(
		id: string,
		country: Country,
		now: number,
		bot = false,
		team = -1,
	) {
		return this.spawnAt(country.country_id, bot, team, now, id);
	}

	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: keep untrusted input validation adjacent to player admission.
	input(id: string, data: Record<string, unknown>, now: number) {
		const direction = data.direction;
		if (typeof direction !== "string" || !Object.hasOwn(steps, direction))
			return;
		if (!Number.isSafeInteger(data.seq) || Number(data.seq) < 0) return;
		let player = this.players.get(id);
		if (!player) {
			if (this.humanCount >= MAX_PLAYERS) return;
			if (!Number.isSafeInteger(data.country_id)) return;
			const country = this.countries.get(Number(data.country_id));
			if (!country || country.is_bot) return;
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
		player.direction = direction as Direction;
	}

	remove(id: string, now: number) {
		const player = this.players.get(id);
		if (!player) return;
		this.dirtyChunks.add(chunkIndex(player.x, player.y));
		this.players.delete(id);
		// Tombstone: the dots vanish now, but the roster row lingers with its
		// final position so a same-id reconnect resumes in place. Expiry runs
		// from the removal time (not last contact), so silent-timeout removals
		// get the full grace window too. It is purely in-memory; the row shape
		// never changes, so rejoin overwrites it with no field-clearing hazards.
		const row: PlayerRow = {
			id: player.id,
			country_id: player.country_id,
			is_bot: player.is_bot,
			last_x: player.x,
			last_y: player.y,
		};
		if (player.name !== undefined) row.name = player.name;
		this.graveyard.set(id, {
			row,
			expires: now + PLAYER_GRACE_MS,
			point: player.point,
		});
		this.dirtyPlayerRows.add(id);
		this.maybeDeleteCountry(player.country_id);
	}

	tick(now: number) {
		this.ticks++;
		for (const player of this.players.values()) {
			if (player.is_bot) continue;
			if (now - player.heardAt > INPUT_LEASE_MS * 5) {
				this.remove(player.id, now);
				continue;
			}
			if (now - player.heardAt > INPUT_LEASE_MS) player.direction = "idle";
			this.move(player);
		}
		// Expire grace tombstones whose players never came back. Live rejoins
		// cancel by deleting the graveyard entry (and any stale queued remove).
		this.sweepGraveyard(now);
		this.tickBots(now);
		this.fillEnclosures();
	}

	private sweepGraveyard(now: number) {
		for (const [id, grave] of this.graveyard) {
			if (now < grave.expires) continue;
			this.graveyard.delete(id);
			if (!this.players.has(id)) this.dirtyRemovedPlayerRows.add(id);
		}
	}

	private advancePlan(player: Player) {
		const plan = player.plan;
		if (!plan || plan.cells[0] !== player.y * WIDTH + player.x) return;
		plan.cells.shift();
		// A finished roam keeps moving; only a finished sweep pauses.
		if (!plan.cells.length && !plan.roam)
			player.thinkAt = this.ticks + this.pauseTicks();
	}

	private tickBots(now: number) {
		if (!this.botsEnabled) return;
		this.populateBots(now);
		// Empty worlds wait for people, so territory is not consumed between sessions.
		if (!this.humanCount) return;
		for (const player of this.players.values()) {
			if (!player.is_bot) continue;
			if (!player.credit) this.steerBot(player);
			this.move(player);
			this.advancePlan(player);
		}
	}

	stepCost(
		countryId: number,
		from: number,
		to: number,
		owner = this.owners[to],
	) {
		let cost = RULES.neutral;
		if (this.land[to] && owner)
			cost = owner === countryId ? RULES.own : RULES.enemy;
		if (this.land[from] !== this.land[to]) cost += RULES.crossing;
		return cost;
	}

	private move(player: Player) {
		if (player.direction === "idle") return;
		const [dx, dy] = steps[player.direction];
		// Horizontal movement wraps around the seam; only the poles block.
		const x = wrapX(player.x + dx),
			y = player.y + dy;
		if (y < 0 || y >= HEIGHT) {
			player.credit = 0;
			return;
		}
		const from = player.y * WIDTH + player.x,
			to = y * WIDTH + x;
		const owner = this.owners[to];
		const cost = this.stepCost(player.country_id, from, to);
		if (++player.credit < cost) return;
		player.credit = 0;
		const before = chunkIndex(player.x, player.y);
		this.dirtyChunks.add(before);
		player.x = x;
		player.y = y;
		const after = chunkIndex(x, y);
		this.dirtyChunks.add(after);
		// Roster position tracks chunk crossings only (not every cell): exact
		// enough for O(1) locate, quiet enough to keep the cold subscription
		// cold. ponytail: per-tick sync if locate ever misses on fast movers.
		if (after !== before) {
			player.last_x = x;
			player.last_y = y;
			this.dirtyPlayerRows.add(player.id);
		}
		if (!this.land[to] || owner === player.country_id) return;
		this.claim(to, player.country_id);
	}

	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: each affected country fills and updates ownership at most once.
	private fillEnclosures() {
		if (!this.enclosureCountries.size) {
			this.changedCountries.clear();
			return;
		}
		// Keep entries until the pass ends: captures can append affected countries,
		// but each country runs at most once, in first-change order.
		for (const countryId of this.changedCountries) {
			if (
				!this.enclosureCountries.has(countryId) ||
				!this.countries.get(countryId)?.count
			)
				continue;
			const box = this.bounds.get(countryId);
			if (!box) continue;
			const starts = this.enclosureCountries.get(countryId);
			// A processed country needs no more candidates from its own captures.
			this.enclosureCountries.set(countryId, null);
			const local = starts
				? localEnclosures(this.owners, countryId, starts, box, WIDTH)
				: undefined;
			if (local) {
				for (const cell of local) this.claim(cell, countryId, true);
				continue;
			}
			// Filling only grows a country inside its original bounds. Other
			// countries only shrink, so these bounds stay safe throughout the pass.
			const labels = this.filler.fill(this.owners, countryId, box);
			for (let y = box.top; y <= box.bottom; y++) {
				const end = y * WIDTH + box.right;
				for (let cell = y * WIDTH + box.left; cell <= end; cell++)
					if (labels[cell] === 0 && this.land[cell])
						this.claim(cell, countryId, true);
			}
		}
		this.changedCountries.clear();
		this.enclosureCountries.clear();
	}

	private queueEnclosure(countryId: number, cell: number) {
		let starts = this.enclosureCountries.get(countryId);
		if (starts === null) return;
		if (!starts) {
			starts = new Set();
			this.enclosureCountries.set(countryId, starts);
		}
		if (starts.size === LOCAL_SEARCH_BUDGET)
			this.enclosureCountries.set(countryId, null);
		else starts.add(cell);
	}

	private extendBounds(countryId: number, cell: number) {
		// bounds only grow; recompute after losses if loose bounds become costly.
		const x = cell % WIDTH,
			y = Math.floor(cell / WIDTH);
		const box = this.bounds.get(countryId);
		if (!box)
			this.bounds.set(countryId, { left: x, right: x, top: y, bottom: y });
		else {
			box.left = Math.min(box.left, x);
			box.right = Math.max(box.right, x);
			box.top = Math.min(box.top, y);
			box.bottom = Math.max(box.bottom, y);
		}
	}

	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: update both owners and collect bounded enclosure candidates at their shared mutation point.
	private claim(cell: number, countryId: number, fromFill = false) {
		const owner = this.owners[cell];
		if (!this.land[cell] || owner === countryId) return;
		this.owners[cell] = countryId;
		this.extendBounds(countryId, cell);
		this.changedCountries.add(countryId);
		const starts = this.enclosureCountries.get(countryId);
		if (
			starts !== null &&
			// A later claim can consume a queued start while its hole still exists.
			(starts?.has(cell) || mayEnclose(this.owners, countryId, cell, WIDTH))
		) {
			const x = cell % WIDTH;
			if (cell >= WIDTH) this.queueEnclosure(countryId, cell - WIDTH);
			if (x < WIDTH - 1) this.queueEnclosure(countryId, cell + 1);
			if (cell < this.owners.length - WIDTH)
				this.queueEnclosure(countryId, cell + WIDTH);
			if (x > 0) this.queueEnclosure(countryId, cell - 1);
		}
		this.dirtyChunks.add(chunkIndex(cell % WIDTH, Math.floor(cell / WIDTH)));
		const country = this.countries.get(countryId);
		if (country) country.count++;
		this.dirtyCountries.add(countryId);
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

	/** Persisted dots are untrusted input: corrupt rows republish empty. */
	private chunkHasDots(chunk: ChunkRow): boolean {
		try {
			const dots = JSON.parse(decoder.decode(chunk.dots));
			return !Array.isArray(dots) || dots.length > 0;
		} catch {
			return true;
		}
	}

	/** Wire owner code for a country id; 0 when it has no palette color. */
	private codeOf(countryId: number) {
		let code = this.ownerCodes[countryId];
		if (!code && countryId) {
			const color = this.countries.get(countryId)?.color;
			code = (color ? COUNTRY_COLOR_INDEX.get(color) : undefined) ?? 0;
			this.ownerCodes[countryId] = code;
		}
		return code;
	}

	chunk(index: number): ChunkRow {
		if (
			!Number.isSafeInteger(index) ||
			index < 0 ||
			index >= COLUMNS * Math.ceil(HEIGHT / CHUNK)
		)
			throw new RangeError("Chunk index is out of range");
		const x = (index % COLUMNS) * CHUNK,
			y = Math.floor(index / COLUMNS) * CHUNK;
		const owners = new Uint8Array(CHUNK * CHUNK);
		const columns = Math.min(CHUNK, WIDTH - x),
			rows = Math.min(CHUNK, HEIGHT - y);
		const codes = this.ownerCodes;
		for (let dy = 0; dy < rows; dy++) {
			let target = dy * CHUNK;
			const start = (y + dy) * WIDTH + x;
			for (let dx = 0; dx < columns; dx++, target++) {
				const countryId = this.owners[start + dx];
				let code = codes[countryId];
				// Directly injected country rows skip country(); resolve once.
				if (!code && countryId) code = this.codeOf(countryId);
				owners[target] = code;
			}
		}
		const dots: Dot[] = [...this.players.values()]
			.filter((p) => chunkIndex(p.x, p.y) === index)
			.map(({ id, x, y }) => ({ player_id: id, x, y }));
		return {
			id: rowId(index),
			owners,
			dots: encoder.encode(JSON.stringify(dots)),
		};
	}
}
