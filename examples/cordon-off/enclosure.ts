import type { Bounds } from "./filler";

/** The eight neighbours of a cell in cyclic order, as x/y step pairs:
 * NW, N, NE, E, SE, S, SW, W. Consecutive entries are eight-adjacent, so the
 * open cells of a ring fall into runs; side-neighbours keep the odd indices. */
const RING_X = [-1, 0, 1, 1, 1, 0, -1, -1];
const RING_Y = [-1, -1, -1, 0, 1, 1, 1, 0];

// Claiming a pixel can only enclose what sits beside it, and only while that
// pixel was the last way out. hasStraightExit runs after the claim, so its rays
// stop at the new wall: a neighbour it can still prove open is not at risk.
// A ring with no country pixel at all cannot be split either - the open ring is
// itself eight-connected, so dropping one cell from it severs nothing.
//
// Returns the neighbours worth an enclosure search, or undefined when none are.
export function mayEnclose(
	owners: Uint16Array,
	countryId: number,
	cell: number,
	width: number,
	bounds: Bounds,
): number[] | undefined {
	const x = cell % width,
		y = Math.floor(cell / width),
		height = (owners.length / width) | 0;
	let open = 0,
		walled = false,
		edge = false;
	for (let i = 0; i < 8; i++) {
		const nx = x + RING_X[i],
			ny = y + RING_Y[i];
		if (nx < 0 || ny < 0 || nx >= width || ny >= height) {
			edge = true;
			continue;
		}
		if (owners[ny * width + nx] === countryId) walled = true;
		else open |= 1 << i;
	}
	if (!walled) return undefined;
	// One open run means every open neighbour is still joined around the new
	// wall, so nothing beside this cell is severed and no ray walk is needed.
	// An incomplete ring cannot be counted this way - the run boundary may sit
	// off the array - and a ring with no open cell at all counts as zero runs,
	// which is exactly the fully enclosed case.
	if (!edge && openRuns(open) < 2) return undefined;
	const atRisk = atRiskNeighbours(owners, countryId, x, y, width, bounds, open);
	return atRisk.length ? atRisk : undefined;
}

/** Number of open runs around the ring mask; bit 7 wraps to bit 0. */
function openRuns(open: number): number {
	let runs = 0;
	for (let i = 0; i < 8; i++)
		if (open & (1 << i) && !(open & (1 << ((i + 7) % 8)))) runs++;
	return runs;
}

/** Open neighbours with no proven straight exit: the ones a new wall could sever. */
function atRiskNeighbours(
	owners: Uint16Array,
	countryId: number,
	x: number,
	y: number,
	width: number,
	bounds: Bounds,
	open: number,
): number[] {
	const atRisk: number[] = [];
	for (let i = 0; i < 8; i++) {
		if (!(open & (1 << i))) continue;
		const neighbor = (y + RING_Y[i]) * width + (x + RING_X[i]);
		if (!hasStraightExit(owners, countryId, neighbor, width, bounds))
			atRisk.push(neighbor);
	}
	return atRisk;
}

// A straight route through non-country pixels proves connection to the exterior.
// Curved routes can fail this test; those deliberately request an enclosure search.
export function hasStraightExit(
	owners: Uint16Array,
	countryId: number,
	cell: number,
	width: number,
	bounds: Bounds,
) {
	if (owners[cell] === countryId) return false;
	const x = cell % width,
		y = (cell - x) / width;
	if (
		x <= bounds.left ||
		x >= bounds.right ||
		y <= bounds.top ||
		y >= bounds.bottom
	)
		return true;
	const left = cell - x + bounds.left,
		right = cell - x + bounds.right;
	const top = bounds.top * width + x,
		bottom = bounds.bottom * width + x;
	return (
		straightRay(owners, countryId, cell, left, -1) ||
		straightRay(owners, countryId, cell, right, 1) ||
		straightRay(owners, countryId, cell, top, -width) ||
		straightRay(owners, countryId, cell, bottom, width) ||
		// Diagonals last, and only for pixels no straight ray saved: a corner gap is
		// a real route out under eight-connectivity, and exactly what these miss.
		diagonalExit(owners, countryId, x, y, width, bounds, -1, -1) ||
		diagonalExit(owners, countryId, x, y, width, bounds, 1, -1) ||
		diagonalExit(owners, countryId, x, y, width, bounds, -1, 1) ||
		diagonalExit(owners, countryId, x, y, width, bounds, 1, 1)
	);
}

/** Walks one straight ray from `cell` to `bound`; true when it never meets country ground. */
function straightRay(
	owners: Uint16Array,
	countryId: number,
	cell: number,
	bound: number,
	step: number,
): boolean {
	let cur = cell;
	while (cur !== bound && owners[cur + step] !== countryId) cur += step;
	return cur === bound;
}

/** True when a diagonal leaves the rectangle without meeting country ground. */
function diagonalExit(
	owners: Uint16Array,
	countryId: number,
	x: number,
	y: number,
	width: number,
	bounds: Bounds,
	dx: number,
	dy: number,
) {
	let cx = x + dx,
		cy = y + dy;
	while (
		cx >= bounds.left &&
		cx <= bounds.right &&
		cy >= bounds.top &&
		cy <= bounds.bottom
	) {
		if (owners[cy * width + cx] === countryId) return false;
		cx += dx;
		cy += dy;
	}
	return true;
}

// Bound all local work per country, then use the whole-country scan as fallback.
// A stamp write is cheap enough that the budget mostly guards pathological
// geometry: the dive resolves every candidate in the profile workloads well
// inside it, and only enclosed regions too large to walk locally fall back.
export const LOCAL_SEARCH_BUDGET = 16384;

// The flood is a depth-first dive toward the nearest bound, so a component that
// reaches the exterior is proven open in about the length of its shortest route
// rather than the area of the region it covers. Push order is worst-first, so
// the neighbour closest to the bound ends up on top of the stack.
const PUSH_ORDER: Int8Array[] = [];
for (const px of [-1, 1])
	for (const py of [-1, 1])
		PUSH_ORDER.push(
			Int8Array.from(
				[0, 1, 2, 3, 4, 5, 6, 7].sort(
					(a, b) =>
						RING_X[a] * px + RING_Y[a] * py - (RING_X[b] * px + RING_Y[b] * py),
				),
			),
		);

// Flat stamp maps replace Set storage: a visited cell costs one typed-array
// write instead of a hash insert, which is what makes deeper dives affordable.
// Visited and exterior-proven cells share one marks array (positive/negative
// stamp), halving the random reads the neighbour loop pays per cell.
let marks = new Int32Array(0);
const stack = new Int32Array(LOCAL_SEARCH_BUDGET + 1);
const component = new Int32Array(LOCAL_SEARCH_BUDGET + 1);
const holeBuf = new Int32Array(LOCAL_SEARCH_BUDGET * 2 + 1);
let stamp = 0;
let budget = 0;
let holeCount = 0;
let depth = 0;
let seen = 0;
const OFFSETS = new Int32Array(8);
const QUADRANT_OFFSETS: Int32Array[] = [
	new Int32Array(8),
	new Int32Array(8),
	new Int32Array(8),
	new Int32Array(8),
];

// Scratch storage is reused synchronously. Nothing is painted unless every
// candidate is resolved within the shared budget; undefined requests a full fill.
export function localEnclosures(
	owners: Uint16Array,
	countryId: number,
	starts: Set<number>,
	bounds: Bounds,
	width: number,
): number[] | undefined {
	const outsideMark = nextStamp(owners);
	// Flat neighbour offsets, built once per call rather than once per pixel.
	buildOffsets(width);
	const midX = (bounds.left + bounds.right) >> 1;
	const midY = (bounds.top + bounds.bottom) >> 1;
	budget = LOCAL_SEARCH_BUDGET;
	holeCount = 0;
	for (const start of starts) {
		if (alreadyMarked(owners, countryId, start)) continue;
		// Gains and bulk captures also queue exterior cells. Reuse the loss gate
		// before a broad open component can exhaust the local flood budget.
		if (hasStraightExit(owners, countryId, start, width, bounds)) {
			marks[start] = outsideMark;
			continue;
		}
		if (!budget--) return;
		if (
			floodComponent(
				owners,
				countryId,
				start,
				bounds,
				width,
				midX,
				midY,
				outsideMark,
			) === "exhausted"
		)
			return;
	}
	// Match the full fill's claim order, including which other countries it affects first.
	// Sort the scratch view natively (no comparator, numeric order) and copy:
	// the comparator form costs about a millisecond per six thousand holes.
	const sorted = holeBuf.subarray(0, holeCount);
	sorted.sort();
	const holes = new Array<number>(holeCount);
	for (let i = 0; i < holeCount; i++) holes[i] = sorted[i];
	return holes;
}

/** Grows the shared marks map when needed, bumps the stamp, returns the outside mark. */
function nextStamp(owners: Uint16Array): number {
	if (marks.length !== owners.length) marks = new Int32Array(owners.length);
	stamp++;
	// Stamps never reset per call, so only an overflow has to clear the map.
	if (stamp === 0x7fffffff) {
		marks.fill(0);
		stamp = 1;
	}
	return -stamp;
}

/** Flat neighbour offsets for this width, reused for every pixel of the call. */
function buildOffsets(width: number): void {
	for (let i = 0; i < 8; i++) OFFSETS[i] = RING_X[i] + RING_Y[i] * width;
	for (let q = 0; q < 4; q++) {
		const order = PUSH_ORDER[q];
		const qOffsets = QUADRANT_OFFSETS[q];
		for (let i = 0; i < 8; i++) qOffsets[i] = OFFSETS[order[i]];
	}
}

/** True for country pixels and for cells this search already resolved. */
function alreadyMarked(
	owners: Uint16Array,
	countryId: number,
	cell: number,
): boolean {
	const mark = marks[cell];
	return owners[cell] === countryId || mark === stamp || mark === -stamp;
}

/** True when a cell sits on the bounding rectangle's edge. */
function atBoundary(x: number, y: number, bounds: Bounds): boolean {
	return (
		x <= bounds.left ||
		x >= bounds.right ||
		y <= bounds.top ||
		y >= bounds.bottom
	);
}

/** Neighbor order that dives toward the nearest bound. */
function boundaryOffsets(x: number, y: number, midX: number, midY: number) {
	return QUADRANT_OFFSETS[((x <= midX ? 0 : 1) << 1) | (y <= midY ? 0 : 1)];
}

/**
 * Floods one component from `start`. Returns "open" when it escapes,
 * "hole" when it is captured, "exhausted" when the shared budget ran out.
 */
function floodComponent(
	owners: Uint16Array,
	countryId: number,
	start: number,
	bounds: Bounds,
	width: number,
	midX: number,
	midY: number,
	outsideMark: number,
): "open" | "exhausted" | "hole" {
	depth = 0;
	seen = 0;
	marks[start] = stamp;
	component[seen++] = start;
	stack[depth++] = start;
	while (depth > 0) {
		const cell = stack[--depth],
			x = cell % width,
			y = Math.floor(cell / width);
		if (atBoundary(x, y, bounds)) return settleComponent(true, outsideMark);
		const offsets = boundaryOffsets(x, y, midX, midY);
		for (let i = 0; i < 8; i++) {
			const next = cell + offsets[i];
			const mark = marks[next];
			if (owners[next] === countryId || mark === stamp) continue;
			if (mark === outsideMark) return settleComponent(true, outsideMark);
			if (!budget--) return "exhausted";
			marks[next] = stamp;
			component[seen++] = next;
			stack[depth++] = next;
		}
	}
	return settleComponent(false, outsideMark);
}

/** Paints or reports the flushed component, then names its verdict. */
function settleComponent(open: boolean, outsideMark: number): "open" | "hole" {
	for (let i = 0; i < seen; i++) {
		if (open) marks[component[i]] = outsideMark;
		else {
			holeBuf[holeCount++] = component[i];
		}
	}
	return open ? "open" : "hole";
}
