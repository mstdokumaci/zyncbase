import type { JsonValue, ListenHandle, ZyncBaseClient } from "@zyncbase/client";
import { approach, LocalMotion, type MotionDot } from "./motion";
import {
	COUNTRY_CHUNK_HEIGHT,
	COUNTRY_CHUNK_WIDTH,
	COUNTRY_COLUMNS,
	COUNTRY_ROWS,
	countryChunkIndex,
	type Direction,
	type Dot,
	USER_CHUNK_HEIGHT,
	USER_CHUNK_WIDTH,
	USER_COLUMNS,
	USER_ROWS,
	WATER_COUNTRY_CHUNKS,
	WIDTH,
	wrapX,
} from "./shared";

// The data plane shared by the browser client and the headless load farm:
// viewport subscription bookkeeping, camera/motion state, and move publishing.
// Both sides run this exact code so neither can silently drift from the other.

export const FRAME_MS = 1000 / 30;
// Camera catch-up time constant. Bigger = lazier trailing behind the dot.
export const CAMERA_TAU = 120;
// Placeholder camera until locate() reads our roster row; applyOwnRow retargets.
export const INITIAL_CAMERA = { x: 933, y: 276 };
// A chunk subscription costs a listen round trip, so keep one extra country
// chunk on the leading edge of travel; user chunks are 200 cells wide and need
// no margin, and idle needs none either.
const COUNTRY_PREFETCH_CHUNKS = 1;
const USER_PREFETCH_CHUNKS = 0;
const MOVE_RETRY_MS = 500;

export type Viewport = {
	x: number;
	y: number;
	width: number;
	height: number;
	scale: number;
	direction: Direction;
	prefetchDirection: Direction;
};

type ChunkGrid = {
	width: number;
	height: number;
	columns: number;
	rows: number;
	prefetch: number;
	water?: Uint8Array;
};

export const COUNTRY_GRID: ChunkGrid = {
	width: COUNTRY_CHUNK_WIDTH,
	height: COUNTRY_CHUNK_HEIGHT,
	columns: COUNTRY_COLUMNS,
	rows: COUNTRY_ROWS,
	prefetch: COUNTRY_PREFETCH_CHUNKS,
	water: WATER_COUNTRY_CHUNKS,
};
export const USER_GRID: ChunkGrid = {
	width: USER_CHUNK_WIDTH,
	height: USER_CHUNK_HEIGHT,
	columns: USER_COLUMNS,
	rows: USER_ROWS,
	prefetch: USER_PREFETCH_CHUNKS,
};

export type ViewportBounds = {
	xMin: number;
	xMax: number;
	yMin: number;
	yMax: number;
};

// Extend the view by the grid's prefetch margin in the direction of travel so
// a tile is subscribed before its pixels reach the viewport edge. The heading
// persists while idle so a stop keeps the margin it already paid for.
export function subscriptionBounds(
	grid: ChunkGrid,
	view: Viewport,
	out: ViewportBounds = { xMin: 0, xMax: 0, yMin: 0, yMax: 0 },
) {
	const halfWidth = view.width / view.scale / 2;
	const halfHeight = view.height / view.scale / 2;
	const heading =
		view.direction === "idle" ? view.prefetchDirection : view.direction;
	out.xMin =
		view.x - halfWidth - (heading === "left" ? grid.prefetch * grid.width : 0);
	out.xMax =
		view.x + halfWidth + (heading === "right" ? grid.prefetch * grid.width : 0);
	out.yMin =
		view.y - halfHeight - (heading === "up" ? grid.prefetch * grid.height : 0);
	out.yMax =
		view.y +
		halfHeight +
		(heading === "down" ? grid.prefetch * grid.height : 0);
	return out;
}

// Water-only country chunks can never change: never subscribe.
function addVisibleColumns(
	grid: ChunkGrid,
	visible: Set<number>,
	first: number,
	last: number,
	top: number,
	bottom: number,
) {
	for (let col = first; col <= last; col++)
		for (let y = top; y <= bottom; y++) {
			const index = y * grid.columns + col;
			if (!grid.water?.[index]) visible.add(index);
		}
}

// One walk covers seam copies, row bounds, and the water filter for either grid.
function visibleChunksInto(
	grid: ChunkGrid,
	bounds: ViewportBounds,
	visible: Set<number>,
) {
	visible.clear();
	const { xMin, xMax, yMin, yMax } = bounds;
	const top = Math.max(0, Math.floor(yMin / grid.height));
	const bottom = Math.min(grid.rows - 1, Math.floor(yMax / grid.height));
	for (let k = Math.floor(xMin / WIDTH); k <= Math.floor(xMax / WIDTH); k++) {
		const start = Math.max(0, xMin - k * WIDTH),
			end = Math.min(WIDTH, xMax - k * WIDTH);
		if (start >= end) continue;
		const first = Math.floor(start / grid.width),
			last = Math.min(grid.columns - 1, Math.ceil(end / grid.width) - 1);
		addVisibleColumns(grid, visible, first, last, top, bottom);
	}
	return visible;
}

export function visibleChunks(grid: ChunkGrid, view: Viewport) {
	return visibleChunksInto(grid, subscriptionBounds(grid, view), new Set());
}

export function subscriptionKey(grid: ChunkGrid, view: Viewport) {
	const { xMin, xMax, yMin, yMax } = subscriptionBounds(grid, view);
	return `${Math.floor(xMin / grid.width)},${Math.floor(xMax / grid.width)},${Math.floor(yMin / grid.height)},${Math.floor(yMax / grid.height)}`;
}

export type PendingUnlisten = Promise<ListenHandle>;
export type ChunkSink = {
	receive: (row: JsonValue) => void;
	removed?: (index: number) => void;
};

// Serve exactly the currently visible chunks of one grid: unlisten and drop
// tiles that left the ring, listen for tiles that entered it. A listen issued
// while the transport is down queues until the session is ready, so ring
// changes during an outage are safe; a rejected handle would pin its chunk
// index forever, so it removes itself below.
export class ViewportSubscriptions {
	private readonly country = new Map<number, PendingUnlisten>();
	private readonly user = new Map<number, PendingUnlisten>();
	// Chunk-aligned bounds of the last synced ring, per grid. Numeric so the
	// tick-rate gating check allocates nothing.
	private readonly countryBounds: ViewportBounds = {
		xMin: 0,
		xMax: 0,
		yMin: 0,
		yMax: 0,
	};
	private readonly userBounds: ViewportBounds = {
		xMin: 0,
		xMax: 0,
		yMin: 0,
		yMax: 0,
	};
	private lastCountry: [number, number, number, number] = [NaN, NaN, NaN, NaN];
	private lastUser: [number, number, number, number] = [NaN, NaN, NaN, NaN];
	private readonly countryVisible = new Set<number>();
	private readonly userVisible = new Set<number>();
	// A rejected listen removes itself from its map, but the key-gated check
	// below would never notice — this flag forces the next update to re-sync.
	private resyncNeeded = false;

	constructor(
		// Lazy: no client exists before admission, so updates no-op until one does.
		private readonly store: () => ZyncBaseClient["store"] | undefined,
		private readonly sinks: { country: ChunkSink; user: ChunkSink },
	) {}

	get count() {
		return this.country.size + this.user.size;
	}

	// Recompute tiles only when the prefetched bounds cross a chunk edge or a
	// listen was rejected: chunk updates arrive at tick rate and must not
	// rescan subscriptions each time.
	update(view: Viewport, force = false) {
		const store = this.store();
		if (!store) return;
		const cb = subscriptionBounds(COUNTRY_GRID, view, this.countryBounds);
		const ub = subscriptionBounds(USER_GRID, view, this.userBounds);
		const cl = Math.floor(cb.xMin / COUNTRY_GRID.width);
		const cr = Math.floor(cb.xMax / COUNTRY_GRID.width);
		const ct = Math.floor(cb.yMin / COUNTRY_GRID.height);
		const cbb = Math.floor(cb.yMax / COUNTRY_GRID.height);
		const ul = Math.floor(ub.xMin / USER_GRID.width);
		const ur = Math.floor(ub.xMax / USER_GRID.width);
		const ut = Math.floor(ub.yMin / USER_GRID.height);
		const ubb = Math.floor(ub.yMax / USER_GRID.height);
		if (
			!force &&
			!this.resyncNeeded &&
			cl === this.lastCountry[0] &&
			cr === this.lastCountry[1] &&
			ct === this.lastCountry[2] &&
			cbb === this.lastCountry[3] &&
			ul === this.lastUser[0] &&
			ur === this.lastUser[1] &&
			ut === this.lastUser[2] &&
			ubb === this.lastUser[3]
		)
			return;
		this.resyncNeeded = false;
		this.lastCountry[0] = cl;
		this.lastCountry[1] = cr;
		this.lastCountry[2] = ct;
		this.lastCountry[3] = cbb;
		this.lastUser[0] = ul;
		this.lastUser[1] = ur;
		this.lastUser[2] = ut;
		this.lastUser[3] = ubb;
		this.syncChunks(
			store,
			"country_chunks",
			this.country,
			this.sinks.country,
			visibleChunksInto(COUNTRY_GRID, cb, this.countryVisible),
		);
		this.syncChunks(
			store,
			"user_chunks",
			this.user,
			this.sinks.user,
			visibleChunksInto(USER_GRID, ub, this.userVisible),
		);
	}

	// Drop every served chunk of both grids (session end).
	reset() {
		this.drop(this.country, this.sinks.country);
		this.drop(this.user, this.sinks.user);
		this.lastCountry[0] = NaN;
		this.lastCountry[1] = NaN;
		this.lastCountry[2] = NaN;
		this.lastCountry[3] = NaN;
		this.lastUser[0] = NaN;
		this.lastUser[1] = NaN;
		this.lastUser[2] = NaN;
		this.lastUser[3] = NaN;
		this.resyncNeeded = false;
	}

	private drop(subs: Map<number, PendingUnlisten>, sink: ChunkSink) {
		for (const [index, unlisten] of subs) {
			void unlisten.then((handle) => handle.unlisten()).catch(() => {});
			sink.removed?.(index);
		}
		subs.clear();
	}

	private syncChunks(
		store: ZyncBaseClient["store"],
		table: string,
		subs: Map<number, PendingUnlisten>,
		sink: ChunkSink,
		visible: Set<number>,
	) {
		for (const [index, unlisten] of subs) {
			if (visible.has(index)) continue;
			void unlisten.then((handle) => handle.unlisten()).catch(() => {});
			subs.delete(index);
			sink.removed?.(index);
		}
		for (const index of visible) {
			if (subs.has(index)) continue;
			// Direct document listens: chunk ids are the store primary keys, so
			// no secondary index or query-subscription group is needed per tile.
			const key = index;
			const unlisten = store.listen([table, String(index)], (row) => {
				if (!subs.has(key)) return;
				if (row) sink.receive(row);
				else sink.removed?.(key);
			});
			subs.set(index, unlisten);
			void unlisten.catch(() => {
				if (subs.get(key) !== unlisten) return;
				subs.delete(key);
				this.resyncNeeded = true;
			});
		}
	}
}

// Palette-code owner of a cell for prediction, answered from the subscribed
// country-chunk cache. Water is always unowned and water-only chunks have no
// rows; answer without a subscribed chunk so prediction keeps working over the
// ocean.
export function ownerAt(
	chunks: Map<number, { colorIndexes: Uint8Array }>,
	land: Uint8Array,
	x: number,
	y: number,
) {
	const wrapped = wrapX(x);
	if (!land[y * WIDTH + wrapped]) return 0;
	return chunks.get(countryChunkIndex(wrapped, y))?.colorIndexes[
		(y % COUNTRY_CHUNK_HEIGHT) * COUNTRY_CHUNK_WIDTH +
			(wrapped % COUNTRY_CHUNK_WIDTH)
	];
}

// Send one direction change. The action is retried only while `isCurrent`
// still holds: a stale client or direction must not resurrect old input.
export function sendPlayerMove(
	client: ZyncBaseClient,
	direction: Direction,
	seq: number,
	isCurrent: () => boolean,
	retryMs = MOVE_RETRY_MS,
) {
	const send = () => {
		void client.actions.call("player_move", { direction, seq }).catch(() => {
			if (!isCurrent()) return;
			setTimeout(() => {
				if (isCurrent()) send();
			}, retryMs);
		});
	};
	send();
}

export type ViewSessionOptions = {
	store: ZyncBaseClient["store"];
	sinks: { country: ChunkSink; user: ChunkSink };
	// Current viewport pixel size and zoom; update with setViewport on
	// resize/zoom so the frame path never re-reads browser globals.
	width: number;
	height: number;
	scale: number;
	land: Uint8Array;
	ownerAt: (x: number, y: number) => number | undefined;
	// Whether moves may be sent right now (online + joined + current client).
	isOnline: () => boolean;
	// Current client to send actions on; undefined when offline.
	client: () => ZyncBaseClient | undefined;
	// Called when a received dot confirms a real position change.
	onConfirmed?: () => void;
};

// The client-side position/subscription state machine: the owned dot predicts
// through LocalMotion, the camera eases behind it, and chunk subscriptions
// follow the camera's chunk-aligned bounds. The browser renders from this
// state; the load farm drives it headless.
export class ViewSession {
	readonly camera = { ...INITIAL_CAMERA };
	direction: Direction = "idle";
	prefetchDirection: Direction = "idle";
	motion: LocalMotion | undefined;
	dirty = true;
	readonly subscriptions: ViewportSubscriptions;

	private width: number;
	private height: number;
	private scale: number;
	private readonly viewportScratch: Viewport = {
		x: 0,
		y: 0,
		width: 0,
		height: 0,
		scale: 1,
		direction: "idle",
		prefetchDirection: "idle",
	};
	private readonly frameResult: {
		due: boolean;
		active: boolean;
		position?: { x: number; y: number };
	} = { due: false, active: false };
	private lastSentDirection: Direction = "idle";
	private seq = 0;
	private lastFrame = 0;
	private drawnX = Number.NaN;
	private drawnY = Number.NaN;

	constructor(private readonly options: ViewSessionOptions) {
		this.subscriptions = new ViewportSubscriptions(
			options.store,
			options.sinks,
		);
		this.width = options.width;
		this.height = options.height;
		this.scale = options.scale;
	}

	setViewport(width: number, height: number, scale: number) {
		this.width = width;
		this.height = height;
		this.scale = scale;
	}

	viewport(): Viewport {
		const view = this.viewportScratch;
		view.x = this.camera.x;
		view.y = this.camera.y;
		view.width = this.width;
		view.height = this.height;
		view.scale = this.scale;
		view.direction = this.direction;
		view.prefetchDirection = this.prefetchDirection;
		return view;
	}

	// From the join reply or locate(): snap the camera to the admitted cell and
	// recompute the listening ring from there.
	admit(position?: { x: number; y: number }) {
		this.motion = undefined;
		if (position) {
			this.camera.x = position.x + 0.5;
			this.camera.y = position.y + 0.5;
		} else {
			this.camera.x = INITIAL_CAMERA.x;
			this.camera.y = INITIAL_CAMERA.y;
		}
		this.dirty = true;
		this.subscriptions.update(this.viewport(), true);
	}

	// A located roster row re-targets the listening ring. Only before a local
	// dot exists: the located cell is the chunk entry, up to
	// COUNTRY_CHUNK_WIDTH-1 cells off, so it must not fight the eased follow
	// once motion owns the view.
	retarget(x: number, y: number) {
		if (!this.motion) {
			this.camera.x = x + 0.5;
			this.camera.y = y + 0.5;
			this.dirty = true;
		}
		this.subscriptions.update(this.viewport(), true);
	}

	setDirection(next: Direction) {
		if (next === this.direction) return;
		this.direction = next;
		this.lastSentDirection = next;
		if (next !== "idle") this.prefetchDirection = next;
		this.publishDirection();
		// Non-forced: a heading change only matters when it moves the
		// prefetched bounds across a chunk edge; the key gate decides.
		this.subscriptions.update(this.viewport());
	}

	release() {
		this.lastSentDirection = "idle";
		this.setDirection("idle");
	}

	publishDirection() {
		this.motion?.update(
			this.motion.dot,
			this.options.isOnline() ? this.direction : "idle",
			performance.now(),
		);
		const moveClient = this.options.client();
		if (!moveClient || !this.options.isOnline()) return;
		const moveDirection = this.direction;
		const moveSeq = ++this.seq;
		sendPlayerMove(
			moveClient,
			moveDirection,
			moveSeq,
			() =>
				this.options.isOnline() &&
				this.options.client() === moveClient &&
				this.direction === moveDirection &&
				this.seq === moveSeq,
		);
	}

	// An own dot arrived from the user-chunk subscription.
	receiveSelf(dot: MotionDot, now: number) {
		const moving = this.options.isOnline() ? this.direction : "idle";
		if (this.motion) {
			const confirmed =
				positionChanged(dot, this.motion.dot) &&
				this.options.isOnline() &&
				isConsistentMove(this.motion.dot, dot, this.lastSentDirection);
			this.motion.update(dot, moving, now);
			if (confirmed) this.options.onConfirmed?.();
			this.subscriptions.update(this.viewport());
			return;
		}
		this.motion = new LocalMotion(
			dot,
			moving,
			now,
			this.options.land,
			this.options.ownerAt,
		);
		this.subscriptions.update(this.viewport());
	}

	// The motion's color joins the roster later than its first dot, so refresh
	// it here without treating the change as a relocation.
	refreshColor(colorIndex: number, now: number) {
		if (!this.motion) return;
		if (this.motion.dot.colorIndex === colorIndex) return;
		this.motion.update(
			{ ...this.motion.dot, colorIndex },
			this.options.isOnline() ? this.direction : "idle",
			now,
		);
	}

	// One render frame: ease the camera toward the predicted dot, then follow
	// its chunk-aligned subscription bounds. `active` is false on idle frames
	// that change nothing, matching the browser's repaint gate.
	frame(now: number): {
		due: boolean;
		active: boolean;
		position?: { x: number; y: number };
	} {
		const out = this.frameResult;
		const elapsed = now - this.lastFrame;
		// Allow timestamp rounding at the frame boundary without accumulating
		// drift.
		if (elapsed + 0.1 < FRAME_MS) {
			out.due = false;
			out.active = false;
			out.position = undefined;
			return out;
		}
		const position = this.motion?.position(now);
		const moved =
			position !== undefined &&
			(position.x !== this.drawnX || position.y !== this.drawnY);
		// The camera keeps easing after the dot stops: stay active until it has
		// settled exactly on the target.
		const settling =
			position !== undefined &&
			(this.camera.x !== position.x + 0.5 ||
				this.camera.y !== position.y + 0.5);
		if (!this.dirty && !moved && !settling) {
			// Keep the easing clock current: elapsed must never span an idle
			// pause, or the first frame after it would ease by the whole pause
			// at once.
			this.lastFrame = now;
			out.due = true;
			out.active = false;
			out.position = position;
			return out;
		}
		this.lastFrame += Math.floor((elapsed + 0.1) / FRAME_MS) * FRAME_MS;
		this.dirty = false;
		if (position) {
			this.drawnX = position.x;
			this.drawnY = position.y;
			this.camera.x = approach(
				this.camera.x,
				position.x + 0.5,
				elapsed,
				CAMERA_TAU,
			);
			this.camera.y = approach(
				this.camera.y,
				position.y + 0.5,
				elapsed,
				CAMERA_TAU,
			);
		}
		this.subscriptions.update(this.viewport());
		out.due = true;
		out.active = true;
		out.position = position;
		return out;
	}
}

function positionChanged(a: Dot, b: Dot) {
	return a.x !== b.x || a.y !== b.y || a.slot !== b.slot;
}

function isConsistentMove(from: Dot, to: Dot, dir: Direction): boolean {
	let dx = to.x - from.x;
	dx -= WIDTH * Math.round(dx / WIDTH);
	const dy = to.y - from.y;
	switch (dir) {
		case "left":
			return dx < 0 && dy === 0;
		case "right":
			return dx > 0 && dy === 0;
		case "up":
			return dx === 0 && dy < 0;
		case "down":
			return dx === 0 && dy > 0;
		default:
			return false;
	}
}
