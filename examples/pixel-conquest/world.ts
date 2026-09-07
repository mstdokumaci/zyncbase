import {
	CHUNK,
	type ChunkRow,
	COLUMNS,
	type Country,
	chunkIndex,
	countryName,
	type Direction,
	type Dot,
	encoder,
	HEIGHT,
	INPUT_LEASE_MS,
	MAX_PLAYERS,
	RULES,
	readOwners,
	rowId,
	WIDTH,
} from "./shared";

type Player = Dot & { direction: Direction; credit: number; heardAt: number };
const steps = {
	idle: [0, 0],
	up: [0, -1],
	down: [0, 1],
	left: [-1, 0],
	right: [1, 0],
};

export class World {
	readonly owners = new Uint16Array(WIDTH * HEIGHT);
	readonly players = new Map<string, Player>();
	readonly countries = new Map<number, Country>();
	readonly dirtyChunks = new Set<number>();
	readonly dirtyCountries = new Set<number>();
	inputMessages = 0;
	ticks = 0;

	constructor(readonly land: Uint8Array) {}

	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: one pass restores the bitmap and recomputes its counts together.
	restore(countries: Country[], chunks: ChunkRow[]) {
		for (const country of countries) {
			const { id, code, name, color } = country;
			this.countries.set(code, { id, code, name, color, count: 0 });
			this.dirtyCountries.add(country.code);
		}
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
				}
			}
			// Reconcile dots before admitting players after a restart.
			if (chunk.occupied) this.dirtyChunks.add(chunk.index);
		}
	}

	private country(name: string) {
		const existing = [...this.countries.values()].find(
			(c) => c.name.toLowerCase() === name.toLowerCase(),
		);
		if (existing) return existing;
		const code = Math.max(0, ...this.countries.keys()) + 1;
		if (code > 65535)
			throw new Error("Country storage is full; reset the world");
		const country = {
			id: rowId(code),
			code,
			name,
			color: `hsl(${(code * 137.508) % 360} 70% 62%)`,
			count: 0,
		};
		this.countries.set(code, country);
		this.dirtyCountries.add(code);
		return country;
	}

	private spawn() {
		const anchor = this.players.values().next().value ?? { x: 933, y: 276 };
		const occupied = new Set(
			[...this.players.values()].map((p) => p.y * WIDTH + p.x),
		);
		// ponytail: local ring scan; use a spatial index if dense spawning becomes expensive.
		for (let radius = 0; radius < Math.max(WIDTH, HEIGHT); radius++) {
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
						!occupied.has(y * WIDTH + x),
				);
				if (position) return position;
			}
		}
		throw new Error("No available land");
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
			if (this.players.size >= MAX_PLAYERS) return;
			let name: string;
			try {
				name = countryName(data.country);
			} catch {
				return;
			}
			const position = this.spawn();
			const country = this.country(name);
			player = {
				id,
				...position,
				code: country.code,
				seq: -1,
				sentAt: 0,
				direction: "idle",
				credit: 0,
				heardAt: now,
			};
			this.players.set(id, player);
			this.dirtyChunks.add(chunkIndex(player.x, player.y));
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
	}

	tick(now: number) {
		this.ticks++;
		for (const player of this.players.values()) {
			if (now - player.heardAt > INPUT_LEASE_MS * 5) {
				this.remove(player.id);
				continue;
			}
			if (now - player.heardAt > INPUT_LEASE_MS) player.direction = "idle";
			this.move(player);
		}
	}

	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: destination cost must be determined before ownership changes.
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
		let cost = RULES.neutral;
		if (this.land[to] && owner)
			cost = owner === player.code ? RULES.own : RULES.enemy;
		if (this.land[from] !== this.land[to]) cost += RULES.crossing;
		if (++player.credit < cost) return;
		player.credit = 0;
		this.dirtyChunks.add(chunkIndex(player.x, player.y));
		player.x = x;
		player.y = y;
		this.dirtyChunks.add(chunkIndex(x, y));
		if (!this.land[to] || owner === player.code) return;
		this.owners[to] = player.code;
		const country = this.countries.get(player.code);
		if (country) country.count++;
		this.dirtyCountries.add(player.code);
		if (owner) {
			const previous = this.countries.get(owner);
			if (previous) previous.count--;
			this.dirtyCountries.add(owner);
		}
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
			.map(({ id, code, x, y, seq, sentAt }) => ({
				id,
				code,
				x,
				y,
				seq,
				sentAt,
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
