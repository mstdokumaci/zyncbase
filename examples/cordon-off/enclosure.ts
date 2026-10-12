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
export const LOCAL_SEARCH_BUDGET = 1024;
const localQueue = new Uint32Array(LOCAL_SEARCH_BUDGET);
const localSeen = new Set<number>();
const localOutside = new Set<number>();

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
	// Flat neighbour offsets, built once per call rather than once per pixel.
	const ring = [
		-width - 1,
		-width,
		-width + 1,
		-1,
		1,
		width - 1,
		width,
		width + 1,
	];
	let remaining = LOCAL_SEARCH_BUDGET;
	const holes = new Set<number>();
	localOutside.clear();
	for (const start of starts) {
		if (
			owners[start] === countryId ||
			holes.has(start) ||
			localOutside.has(start)
		)
			continue;
		// Gains and bulk captures also queue exterior cells. Reuse the loss gate
		// before a broad open component can exhaust the local flood budget.
		if (hasStraightExit(owners, countryId, start, width, bounds)) {
			localOutside.add(start);
			continue;
		}
		if (!remaining--) return;
		localSeen.clear();
		localSeen.add(start);
		localQueue[0] = start;
		let tail = 1,
			open = false;
		for (let head = 0; head < tail && !open; head++) {
			const cell = localQueue[head],
				x = cell % width,
				y = (cell - x) / width;
			if (
				x <= bounds.left ||
				x >= bounds.right ||
				y <= bounds.top ||
				y >= bounds.bottom
			) {
				open = true;
				break;
			}
			for (let i = 0; i < ring.length; i++) {
				const next = cell + ring[i];
				if (owners[next] === countryId || localSeen.has(next)) continue;
				if (localOutside.has(next)) {
					open = true;
					break;
				}
				if (!remaining--) return;
				localSeen.add(next);
				localQueue[tail++] = next;
			}
		}
		for (const cell of localSeen) (open ? localOutside : holes).add(cell);
	}
	// Match the full fill's claim order, including which other countries it affects first.
	return [...holes].sort((a, b) => a - b);
}
