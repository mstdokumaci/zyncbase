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
	decoder,
	encoder,
	HEIGHT,
	INPUT_LEASE_MS,
	MAX_COUNTRIES,
	MAX_PLAYERS,
	PLAYER_GRACE_MS,
	playerName,
	RULES,
	readOwners,
	rowId,
	type UserRow,
	WIDTH,
	wrapX,
} from "./shared";

type Player = {
	id: string;
	name?: string;
	country_id: number;
	is_bot: boolean;
	lastX: number;
	lastY: number;
	x: number;
	y: number;
	seq: number;
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
// Human spawn regions: the historical northern-Italy start (where bots
// spawn) plus farthest-point samples over mostly-land chunks. Players round-
// robin across them so a 1024 crowd spreads over the map instead of stacking
// on one continent — which also splits subscriber fan-out by region.
const SPAWN_CENTERS = 8;
const SPAWN_EDGE_MARGIN = 128;
const SPAWN_BUCKET_SHIFT = 4;
const SPAWN_BUCKET_COLUMNS = Math.ceil(WIDTH / (1 << SPAWN_BUCKET_SHIFT));
const SPAWN_BUCKET_ROWS = Math.ceil(HEIGHT / (1 << SPAWN_BUCKET_SHIFT));
const SPAWN_OWNED_CELL_BUDGET = 1 << 16;
const SPAWN_OWN_RADIUS = 32;
const DEFAULT_SPAWN = { x: 933, y: 276 };
const GOLDEN_ANGLE = 2.399963229728653;
// readOwners decodes little-endian, so serialization must too.
const LITTLE_ENDIAN = new Uint8Array(new Uint16Array([1]).buffer)[0] === 1;

export class World {
	readonly owners = new Uint16Array(WIDTH * HEIGHT);
	readonly players = new Map<string, Player>();
	readonly countries = new Map<number, Country>();
	readonly dirtyChunks = new Set<number>();
	readonly dirtyCountries = new Set<number>();
	readonly dirtyRemovedCountries = new Set<number>();
	readonly dirtyUsers = new Set<string>();
	readonly dirtyRemovedUsers = new Set<string>();
	// Departed players kept briefly for same-id grace reconnects: store row
	// (with final position) lingers, live map entry is gone immediately so
	// ghosts never draw, block spawns, or pin countries.
	private readonly graveyard = new Map<
		string,
		{ row: UserRow; expires: number }
	>();
	inputMessages = 0;
	ticks = 0;
	private nextCode = 1;
	private botsEnabled = false;
	// Human spawn cursor: drives round-robin center selection and the golden-
	// angle spiral inside each region.
	private spawnCount = 0;
	private readonly filler = new HoleFiller(WIDTH, HEIGHT);
	private readonly bounds = new Map<number, Bounds>();
	private readonly changedCountries = new Set<number>();
	private readonly enclosureCountries = new Map<number, Set<number> | null>();
	private readonly spawnCenters: { x: number; y: number }[];

	constructor(readonly land: Uint8Array) {
		this.spawnCenters = this.computeSpawnCenters();
	}

	get humanCount() {
		return [...this.players.values()].filter((player) => !player.is_bot).length;
	}

	/** Cold roster value for publishing (id rides in the path, not the body). */
	userRow(id: string): Omit<UserRow, "id"> | undefined {
		const player = this.players.get(id);
		if (player) {
			const row: Omit<UserRow, "id"> = {
				country_id: player.country_id,
				is_bot: player.is_bot,
				lastX: player.lastX,
				lastY: player.lastY,
			};
			if (player.name !== undefined) row.name = player.name;
			return row;
		}
		const grave = this.graveyard.get(id);
		if (!grave) return undefined;
		const { id: _dropped, ...row } = grave.row;
		return row;
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
			const id = `bot-${i}`;
			if (i >= target) this.remove(id, now);
			else if (!this.players.has(id)) {
				const country = this.country(botCountries[Math.floor(i / 2)], true);
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
	restore(
		countries: Country[],
		chunks: ChunkRow[],
		players: { id: string }[] = [],
		persistedNextCode = 0,
	) {
		for (const country of countries) {
			const { id, code, name, color, is_bot } = country;
			this.countries.set(code, {
				id,
				code,
				name,
				color,
				count: 0,
				is_bot,
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
			// Positions don't survive a restart (live map starts empty), so any
			// chunk persisting dots must be republished empty. Dots bytes are
			// small; decoding beats keeping a queryable flag for this one path.
			if (this.chunkHasDots(chunk)) this.dirtyChunks.add(index);
		}
		// Stale roster rows (including grace tombstones) never survive a
		// restart: the live map is empty, so queue them all for removal.
		for (const player of players) this.dirtyRemovedUsers.add(player.id);
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

	country(value: unknown, isBot = false) {
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
			is_bot: isBot,
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
		// Grace tombstones never pin a country: only live holders count.
		for (const player of this.players.values())
			if (player.country_id === code) return;
		this.countries.delete(code);
		this.bounds.delete(code);
		this.enclosureCountries.delete(code);
		this.changedCountries.delete(code);
		this.dirtyCountries.delete(code);
		this.dirtyRemovedCountries.add(code);
	}

	// First center is the historical northern-Italy start where bots spawn;
	// the rest are farthest-point samples over inland chunks that are at
	// least 60% land, so each region has room to spiral out.
	private computeSpawnCenters() {
		const centers = [{ ...DEFAULT_SPAWN }];
		const candidates = this.spawnCandidates();
		while (centers.length < SPAWN_CENTERS && candidates.length)
			centers.push(this.takeFarthest(candidates, centers));
		return centers;
	}

	/** Inland chunk centers that are at least 60% land. */
	private spawnCandidates() {
		const candidates: { x: number; y: number }[] = [];
		for (
			let row = Math.ceil(SPAWN_EDGE_MARGIN / CHUNK);
			row < Math.ceil(HEIGHT / CHUNK);
			row++
		) {
			for (
				let col = Math.ceil(SPAWN_EDGE_MARGIN / CHUNK);
				col < COLUMNS;
				col++
			) {
				const x = Math.min(col * CHUNK + CHUNK / 2, WIDTH - 1);
				const y = Math.min(row * CHUNK + CHUNK / 2, HEIGHT - 1);
				if (x > WIDTH - SPAWN_EDGE_MARGIN || y > HEIGHT - SPAWN_EDGE_MARGIN)
					continue;
				if (this.chunkLandFraction(col, row) >= 0.6) candidates.push({ x, y });
			}
		}
		return candidates;
	}

	private chunkLandFraction(col: number, row: number) {
		let owned = 0,
			area = 0;
		for (let y = row * CHUNK; y < Math.min((row + 1) * CHUNK, HEIGHT); y++) {
			for (let x = col * CHUNK; x < Math.min((col + 1) * CHUNK, WIDTH); x++) {
				area++;
				owned += this.land[y * WIDTH + x] as number;
			}
		}
		return owned / area;
	}

	/** Pull the candidate farthest from every chosen center (greedy cover). */
	private takeFarthest(
		candidates: { x: number; y: number }[],
		centers: { x: number; y: number }[],
	) {
		let best = candidates[0] as { x: number; y: number };
		let bestDistance = -1;
		for (const candidate of candidates) {
			let nearest = Number.POSITIVE_INFINITY;
			for (const center of centers) {
				const dx = candidate.x - center.x,
					dy = candidate.y - center.y;
				nearest = Math.min(nearest, dx * dx + dy * dy);
				if (nearest <= bestDistance) break;
			}
			if (nearest > bestDistance) {
				bestDistance = nearest;
				best = candidate;
			}
		}
		candidates.splice(candidates.indexOf(best), 1);
		return best;
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

	// Round-robin the regions, then spiral outward inside each one so players
	// in the same region still keep their distance.
	private humanAnchor(index: number) {
		const center = this.spawnCenters[index % this.spawnCenters.length] as {
			x: number;
			y: number;
		};
		const perCenter = Math.ceil(MAX_PLAYERS / this.spawnCenters.length);
		const local = Math.floor(index / this.spawnCenters.length) % perCenter;
		return this.spiralAnchor(center, local);
	}

	// Humans reinforce their country: own land first, then a live teammate,
	// then the regional round-robin. Bots spread over the first regions by
	// country code so every region has an early opponent.
	private spawnAnchor(code: number, bot: boolean, team: number) {
		if (bot) {
			const region = this.spawnCenters[
				(code - 1) % this.spawnCenters.length
			] as { x: number; y: number };
			const angle = (team * Math.PI * 2) / botCountries.length - Math.PI / 2;
			return {
				x: region.x + Math.round(Math.cos(angle) * 48),
				y: region.y + Math.round(Math.sin(angle) * 48),
				own: false,
			};
		}
		const teammates = [...this.players.values()].filter(
			(player) => player.country_id === code,
		);
		const mate =
			teammates.find(
				(player) => this.owners[player.y * WIDTH + player.x] === code,
			) ?? teammates[0];
		if (mate)
			return {
				...this.spiralAnchor(mate, teammates.length),
				own: this.owners[mate.y * WIDTH + mate.x] === code,
			};
		const owned = this.findOwnedCell(code);
		if (owned !== undefined)
			return {
				...this.spiralAnchor(
					{ x: owned % WIDTH, y: Math.floor(owned / WIDTH) },
					0,
				),
				own: true,
			};
		return { ...this.humanAnchor(this.spawnCount++), own: false };
	}

	/** First owned cell within the country's cached bounds, capped for safety. */
	private findOwnedCell(code: number) {
		const box = this.bounds.get(code);
		if (!box) return undefined;
		let budget = SPAWN_OWNED_CELL_BUDGET;
		for (let y = box.top; y <= box.bottom; y++) {
			for (
				let cell = y * WIDTH + box.left;
				cell <= y * WIDTH + box.right;
				cell++
			) {
				if (this.owners[cell] === code) return cell;
				if (--budget <= 0) return undefined;
			}
		}
		return undefined;
	}

	/** Bucket players by 16px cells so a spacing test is constant time. */
	private spacingBuckets(
		code: number,
		extra?: { x: number; y: number; radiusSq: number },
	) {
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
		// Humans and bots share one spacing rule; the round-robin spawn
		// regions keep each region sparse enough for it to fit.
		for (const other of this.players.values())
			add(other.x, other.y, (code === other.country_id ? 12 : 28) ** 2);
		if (extra) add(extra.x, extra.y, extra.radiusSq);
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
	private spawn(code: number, bot: boolean, team: number) {
		const center = [...this.players.values()].find(
			(player) => !player.is_bot,
		) ?? { ...DEFAULT_SPAWN };
		const anchor = this.spawnAnchor(code, bot, team);
		const occupied = new Set(
			[...this.players.values()].map((p) => p.y * WIDTH + p.x),
		);
		const buckets = this.spacingBuckets(
			code,
			bot ? { x: center.x, y: center.y, radiusSq: 28 * 28 } : undefined,
		);
		// Humans reinforcing a country prefer its own cells; bots keep the
		// plain ring search around the first human.
		const ownsAnchor = !bot && anchor.own;
		const passes = ownsAnchor
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
							(!pass.own || this.owners[y * WIDTH + x] === code),
					);
					if (position) return position;
				}
			}
		}
		throw new Error("No available land");
	}

	// Same-id grace reconnects resume their tombstone cell when it is still
	// free land; otherwise they fall through to the normal ring search.
	private spawnAt(
		code: number,
		bot: boolean,
		team: number,
		now: number,
		id: string,
	): Player {
		const grave = this.graveyard.get(id);
		if (grave) {
			this.graveyard.delete(id);
			this.dirtyRemovedUsers.delete(id);
			const { lastX: x, lastY: y } = grave.row;
			if (
				x >= 0 &&
				x < WIDTH &&
				y >= 0 &&
				y < HEIGHT &&
				this.land[y * WIDTH + x] &&
				![...this.players.values()].some((p) => p.x === x && p.y === y)
			)
				return this.makePlayer(id, code, bot, x, y, now);
		}
		const position = this.spawn(code, bot, team);
		return this.makePlayer(id, code, bot, position.x, position.y, now);
	}

	private makePlayer(
		id: string,
		code: number,
		bot: boolean,
		x: number,
		y: number,
		now: number,
	): Player {
		const player: Player = {
			id,
			country_id: code,
			is_bot: bot,
			lastX: x,
			lastY: y,
			x,
			y,
			seq: -1,
			direction: "idle",
			credit: 0,
			heardAt: now,
		};
		this.players.set(id, player);
		this.dirtyChunks.add(chunkIndex(x, y));
		this.dirtyUsers.add(id);
		return player;
	}

	private add(id: string, country: Country, now: number, bot = false) {
		return this.spawnAt(
			country.code,
			bot,
			botCountries.indexOf(country.name),
			now,
			id,
		);
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
			if (!Number.isSafeInteger(data.countryCode)) return;
			const country = this.countries.get(Number(data.countryCode));
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
		const row: UserRow = {
			id: player.id,
			country_id: player.country_id,
			is_bot: player.is_bot,
			lastX: player.x,
			lastY: player.y,
		};
		if (player.name !== undefined) row.name = player.name;
		this.graveyard.set(id, { row, expires: now + PLAYER_GRACE_MS });
		this.dirtyUsers.add(id);
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
		// Expire grace tombstones whose owners never came back. Live rejoins
		// cancel by deleting the graveyard entry (and any stale queued remove).
		this.sweepGraveyard(now);
		this.tickBots(now);
		this.fillEnclosures();
	}

	private sweepGraveyard(now: number) {
		for (const [id, grave] of this.graveyard) {
			if (now < grave.expires) continue;
			this.graveyard.delete(id);
			if (!this.players.has(id)) this.dirtyRemovedUsers.add(id);
		}
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
			player.lastX = x;
			player.lastY = y;
			this.dirtyUsers.add(player.id);
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

	/** Persisted dots are untrusted input: corrupt rows republish empty. */
	private chunkHasDots(chunk: ChunkRow): boolean {
		try {
			const dots = JSON.parse(decoder.decode(chunk.dots));
			return !Array.isArray(dots) || dots.length > 0;
		} catch {
			return true;
		}
	}

	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: index validation plus the LE fast path and portable fallback.
	chunk(index: number): ChunkRow {
		if (
			!Number.isSafeInteger(index) ||
			index < 0 ||
			index >= COLUMNS * Math.ceil(HEIGHT / CHUNK)
		)
			throw new RangeError("Chunk index is out of range");
		const x = (index % COLUMNS) * CHUNK,
			y = Math.floor(index / COLUMNS) * CHUNK;
		const owners = new Uint8Array(CHUNK * CHUNK * 2);
		const columns = Math.min(CHUNK, WIDTH - x),
			rows = Math.min(CHUNK, HEIGHT - y);
		if (LITTLE_ENDIAN) {
			const view = new Uint16Array(owners.buffer);
			for (let dy = 0; dy < rows; dy++)
				view.set(
					this.owners.subarray(
						(y + dy) * WIDTH + x,
						(y + dy) * WIDTH + x + columns,
					),
					dy * CHUNK,
				);
		} else {
			// Native uint16 writes are not portable; keep the wire format LE.
			const view = new DataView(owners.buffer);
			for (let dy = 0; dy < rows; dy++)
				for (let dx = 0; dx < columns; dx++)
					view.setUint16(
						(dy * CHUNK + dx) * 2,
						this.owners[(y + dy) * WIDTH + x + dx],
						true,
					);
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
