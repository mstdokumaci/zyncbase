import { type Direction, type Dot, HEIGHT, RULES, WIDTH } from "./shared";

const steps = {
	idle: [0, 0],
	up: [0, -1],
	down: [0, 1],
	left: [-1, 0],
	right: [1, 0],
};

// Render-side position: hot dot plus its cold country, joined from the
// users roster at receive time. Dots alone carry no identity metadata.
export type MotionDot = Dot & { country_id: number };

export class LocalMotion {
	private offset = { x: 0, y: 0 };
	private duration: number;

	constructor(
		public dot: MotionDot,
		private direction: Direction,
		private started: number,
		private readonly land: Uint8Array,
		private readonly ownerAt: (x: number, y: number) => number | undefined,
	) {
		this.duration = this.stepDuration();
	}

	update(dot: MotionDot, direction: Direction, now: number) {
		const distance =
			Math.abs(dot.x - this.dot.x) + Math.abs(dot.y - this.dot.y);
		const relocated =
			dot.player_id !== this.dot.player_id ||
			dot.country_id !== this.dot.country_id;
		if (!distance && !relocated && direction === this.direction) {
			this.dot = dot;
			if (this.duration === this.stepDuration()) return;
		}
		const position = this.position(now);
		// Respawns and large corrections should not pan across the map.
		this.offset =
			relocated || distance > 2
				? { x: 0, y: 0 }
				: { x: position.x - dot.x, y: position.y - dot.y };
		this.dot = dot;
		this.direction = direction;
		this.started = now;
		this.duration = this.stepDuration();
	}

	position(now: number) {
		const elapsed = Math.max(0, now - this.started);
		// anticipate one cell; predicting farther needs server tick/credit metadata.
		const progress = Math.min(elapsed / this.duration, 1);
		const correction = Math.max(0, 1 - elapsed / Math.min(100, this.duration));
		const [dx, dy] = steps[this.direction];
		return {
			x: this.dot.x + dx * progress + this.offset.x * correction,
			y: this.dot.y + dy * progress + this.offset.y * correction,
		};
	}

	private stepDuration() {
		if (this.direction === "idle") return Number.POSITIVE_INFINITY;
		const [dx, dy] = steps[this.direction];
		const x = this.dot.x + dx,
			y = this.dot.y + dy;
		if (x < 0 || x >= WIDTH || y < 0 || y >= HEIGHT)
			return Number.POSITIVE_INFINITY;
		const owner = this.ownerAt(x, y);
		if (owner === undefined) return Number.POSITIVE_INFINITY;
		const from = this.dot.y * WIDTH + this.dot.x,
			to = y * WIDTH + x;
		let cost = RULES.neutral;
		if (this.land[to] && owner)
			cost = owner === this.dot.country_id ? RULES.own : RULES.enemy;
		if (this.land[from] !== this.land[to]) cost += RULES.crossing;
		return cost * RULES.tickMs;
	}
}
