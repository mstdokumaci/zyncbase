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
// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: walk the local ring once, collecting the neighbours a new wall could put at risk.
export function mayEnclose(
	owners: Uint16Array,
	countryId: number,
	cell: number,
	width: number,
	bounds: Bounds,
): number[] | undefined {
	const x = cell % width,
		y = (cell - x) / width,
		height = owners.length / width;
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
	let runs = 0;
	for (let i = 0; i < 8; i++)
		if (open & (1 << i) && !(open & (1 << ((i + 7) % 8)))) runs++;
	if (!edge && runs < 2) return undefined;
	const atRisk: number[] = [];
	for (let i = 0; i < 8; i++) {
		if (!(open & (1 << i))) continue;
		const neighbor = (y + RING_Y[i]) * width + (x + RING_X[i]);
		if (!hasStraightExit(owners, countryId, neighbor, width, bounds))
			atRisk.push(neighbor);
	}
	return atRisk.length ? atRisk : undefined;
}

// A straight route through non-country pixels proves connection to the exterior.
// Curved routes can fail this test; those deliberately request an enclosure search.
// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: eight bounded rays avoid allocation and stop at the first country pixel.
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
	let cur = cell;
	while (cur > left && owners[cur - 1] !== countryId) cur--;
	if (cur === left) return true;
	cur = cell;
	while (cur < right && owners[cur + 1] !== countryId) cur++;
	if (cur === right) return true;
	cur = cell;
	while (cur > top && owners[cur - width] !== countryId) cur -= width;
	if (cur === top) return true;
	cur = cell;
	while (cur < bottom && owners[cur + width] !== countryId) cur += width;
	if (cur === bottom) return true;
	// Diagonals last, and only for pixels no straight ray saved: a corner gap is
	// a real route out under eight-connectivity, and exactly what these miss.
	return (
		diagonalExit(owners, countryId, x, y, width, bounds, -1, -1) ||
		diagonalExit(owners, countryId, x, y, width, bounds, 1, -1) ||
		diagonalExit(owners, countryId, x, y, width, bounds, -1, 1) ||
		diagonalExit(owners, countryId, x, y, width, bounds, 1, 1)
	);
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
let visited = new Int32Array(0);
let outside = new Int32Array(0);
let stack = new Int32Array(1024);
let component = new Int32Array(1024);
let holeBuf = new Int32Array(1024);
let stamp = 0;
const OFFSETS = new Int32Array(8);

function growInt32(buffer: Int32Array) {
	const grown = new Int32Array(buffer.length * 2);
	grown.set(buffer);
	return grown;
}

// Scratch storage is reused synchronously. Nothing is painted unless every
// candidate is resolved within the shared budget; undefined requests a full fill.
// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: the bounded flood proves each component open or closed before returning captures.
export function localEnclosures(
	owners: Uint16Array,
	countryId: number,
	starts: Set<number>,
	bounds: Bounds,
	width: number,
): number[] | undefined {
	const { left, right, top, bottom } = bounds;
	if (visited.length !== owners.length) {
		visited = new Int32Array(owners.length);
		outside = new Int32Array(owners.length);
	}
	stamp++;
	// Stamps never reset per call, so only an overflow has to clear the maps.
	if (stamp === 0x7fffffff) {
		visited.fill(0);
		outside.fill(0);
		stamp = 1;
	}
	// Flat neighbour offsets, built once per call rather than once per pixel.
	for (let i = 0; i < 8; i++) OFFSETS[i] = RING_X[i] + RING_Y[i] * width;
	let remaining = LOCAL_SEARCH_BUDGET;
	let holeCount = 0;
	for (const start of starts) {
		if (
			owners[start] === countryId ||
			visited[start] === stamp ||
			outside[start] === stamp
		)
			continue;
		// Gains and bulk captures also queue exterior cells. Reuse the loss gate
		// before a broad open component can exhaust the local flood budget.
		if (hasStraightExit(owners, countryId, start, width, bounds)) {
			outside[start] = stamp;
			continue;
		}
		if (!remaining--) return;
		let depth = 0,
			seen = 0,
			open = false;
		visited[start] = stamp;
		stack[depth++] = start;
		component[seen++] = start;
		while (depth > 0 && !open) {
			const cell = stack[--depth],
				x = cell % width,
				y = (cell - x) / width;
			if (x <= left || x >= right || y <= top || y >= bottom) {
				open = true;
				break;
			}
			const px = x - left <= right - x ? -1 : 1;
			const py = y - top <= bottom - y ? -1 : 1;
			const order = PUSH_ORDER[((px + 1) >> 1) * 2 + ((py + 1) >> 1)];
			for (let i = 0; i < 8; i++) {
				const next = cell + OFFSETS[order[i]];
				if (owners[next] === countryId) continue;
				if (outside[next] === stamp) {
					open = true;
					break;
				}
				if (visited[next] === stamp) continue;
				if (!remaining--) return;
				visited[next] = stamp;
				if (seen === component.length) {
					component = growInt32(component);
					stack = growInt32(stack);
				}
				component[seen++] = next;
				stack[depth++] = next;
			}
		}
		for (let i = 0; i < seen; i++) {
			if (open) outside[component[i]] = stamp;
			else {
				if (holeCount === holeBuf.length) holeBuf = growInt32(holeBuf);
				holeBuf[holeCount++] = component[i];
			}
		}
	}
	// Match the full fill's claim order, including which other countries it affects first.
	const holes = new Array<number>(holeCount);
	for (let i = 0; i < holeCount; i++) holes[i] = holeBuf[i];
	holes.sort((a, b) => a - b);
	return holes;
}
