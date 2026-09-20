import {
	type Direction,
	type Dot,
	HEIGHT,
	RULES,
	WIDTH,
	wrapX,
} from "./shared";

const steps = {
	idle: [0, 0],
	up: [0, -1],
	down: [0, 1],
	left: [-1, 0],
	right: [1, 0],
};

// Deterministic axis mixing for joystick diagonals: accumulate the minority
// axis's share of the vector and take it whenever the accumulated share fills
// one step. A 45° push strict-alternates; other angles get a fixed, evenly
// spaced pattern. Random selection here read as dropped input and visible runs.
export function mixDiagonalAxis(ax: number, ay: number, phase: number) {
	const total = ax + ay;
	if (!(total > 0)) return { index: 0 as const, phase };
	phase += ay / total;
	return phase >= 1
		? { index: 1 as const, phase: phase - 1 }
		: { index: 0 as const, phase };
}

// Frame-rate-independent exponential approach toward a target. A gap wider
// than half a world is a camera re-anchor (canonical locate vs. unrolled world
// copies), not motion: snap instead of panning through WIDTH cells of map.
export function approach(
	current: number,
	target: number,
	elapsed: number,
	tau: number,
) {
	if (Math.abs(target - current) > WIDTH / 2) return target;
	const next = current + (target - current) * (1 - Math.exp(-elapsed / tau));
	// Land exactly so callers can detect a settled value without epsilon.
	return Math.abs(target - next) < 0.01 ? target : next;
}

// Joystick steering state machine. A held stick emits a stream of move events;
// the diagonal axis sequence and its carried phase must survive them, or every
// event restarts the alternation and the vertical axis never gets enough
// server ticks to land.
export class JoystickSteering {
	private x = 0;
	private y = 0;
	private directions: Direction[] = [];
	private phase = 0;

	// Feed a screen-space vector (y grows downward). Returns the direction to
	// dispatch when the axes change, or undefined while the sequence holds.
	move(x: number, y: number): Direction | undefined {
		this.x = x;
		this.y = y;
		const ax = Math.abs(x),
			ay = Math.abs(y);
		if (ax < 0.15 && ay < 0.15) {
			this.reset();
			return "idle";
		}
		const h = x > 0 ? "right" : "left";
		const v = y > 0 ? "down" : "up";
		if (ax >= ay * 5) {
			this.reset();
			return h;
		}
		if (ay >= ax * 5) {
			this.reset();
			return v;
		}
		if (this.directions[0] === h && this.directions[1] === v) return undefined;
		this.directions = [h, v];
		// Consume the step dispatched now so the first confirmation alternates
		// instead of repeating the horizontal axis.
		const next = mixDiagonalAxis(ax, ay, 0);
		this.phase = next.phase;
		return this.directions[next.index];
	}

	// A server move was confirmed. Returns the next axis of the diagonal, or
	// undefined when the current input is not a diagonal.
	confirmed(): Direction | undefined {
		if (this.directions.length < 2) return undefined;
		const next = mixDiagonalAxis(
			Math.abs(this.x),
			Math.abs(this.y),
			this.phase,
		);
		this.phase = next.phase;
		return this.directions[next.index];
	}

	release() {
		this.x = 0;
		this.y = 0;
		this.reset();
	}

	private reset() {
		this.directions = [];
		this.phase = 0;
	}
}

// Render-side position: hot dot plus its cold country, joined from the
// users roster at receive time. Dots alone carry no identity metadata, and
// chunk owners are palette codes, so the joined value is the own color index.
export type MotionDot = Dot & { colorIndex: number };

export class LocalMotion {
	private offset = { x: 0, y: 0 };
	// Whole-world copies of the current dot. The rendered position is unrolled
	// (e.g. 2000 is canonical 0), so crossing the seam is a normal step and the
	// camera keeps panning right instead of snapping back.
	private shift = 0;
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
		// Wrap-aware delta: 1999 -> 0 is one step right, not a relocation.
		let dx = dot.x - this.dot.x;
		dx -= WIDTH * Math.round(dx / WIDTH);
		const distance = Math.abs(dx) + Math.abs(dot.y - this.dot.y);
		const relocated =
			dot.player_id !== this.dot.player_id ||
			dot.colorIndex !== this.dot.colorIndex;
		if (!distance && !relocated && direction === this.direction) {
			this.dot = dot;
			if (this.duration === this.stepDuration()) return;
		}
		const position = this.position(now);
		// Keep the unrolled copy nearest the displayed point; respawns and large
		// corrections still snap rather than pan.
		this.shift +=
			WIDTH * Math.round((position.x - (dot.x + this.shift)) / WIDTH);
		this.offset =
			relocated || distance > 2
				? { x: 0, y: 0 }
				: { x: position.x - dot.x - this.shift, y: position.y - dot.y };
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
			x: this.dot.x + this.shift + dx * progress + this.offset.x * correction,
			y: this.dot.y + dy * progress + this.offset.y * correction,
		};
	}

	private stepDuration() {
		if (this.direction === "idle") return Number.POSITIVE_INFINITY;
		const [dx, dy] = steps[this.direction];
		const y = this.dot.y + dy;
		if (y < 0 || y >= HEIGHT) return Number.POSITIVE_INFINITY;
		const x = wrapX(this.dot.x + dx);
		const owner = this.ownerAt(x, y);
		if (owner === undefined) return Number.POSITIVE_INFINITY;
		const from = this.dot.y * WIDTH + this.dot.x,
			to = y * WIDTH + x;
		let cost = RULES.neutral;
		if (this.land[to] && owner)
			cost = owner === this.dot.colorIndex ? RULES.own : RULES.enemy;
		if (this.land[from] !== this.land[to]) cost += RULES.crossing;
		return cost * RULES.tickMs;
	}
}
