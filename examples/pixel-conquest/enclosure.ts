import type { Bounds } from "./filler";

// A gain can split the exterior only if its open side-neighbors do not all
// connect around the eight-cell ring. False rules out a new enclosure; true
// requests an enclosure search. At world edges, search conservatively.
// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: walk the local ring once, counting groups that contain a side-neighbor.
export function mayEnclose(
	owners: Uint16Array,
	code: number,
	cell: number,
	width: number,
) {
	const x = cell % width;
	if (
		x === 0 ||
		x === width - 1 ||
		cell < width ||
		cell >= owners.length - width
	)
		return true;
	const ring = [
		cell - width - 1,
		cell - width,
		cell - width + 1,
		cell + 1,
		cell + width + 1,
		cell + width,
		cell + width - 1,
		cell - 1,
	];
	const wall = ring.findIndex((neighbor) => owners[neighbor] === code);
	if (wall === -1) return false;
	let groups = 0,
		side = false;
	for (let i = 1; i <= ring.length; i++) {
		const index = (wall + i) % ring.length;
		if (owners[ring[index]] === code) {
			if (side && ++groups > 1) return true;
			side = false;
		} else if (index % 2 === 1) side = true;
	}
	return false;
}

// A straight route through non-country pixels proves connection to the exterior.
// Curved routes can fail this test; those deliberately request an enclosure search.
// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: four bounded rays avoid allocation and stop at the first country pixel.
export function hasStraightExit(
	owners: Uint16Array,
	code: number,
	cell: number,
	width: number,
	bounds: Bounds,
) {
	if (owners[cell] === code) return false;
	const x = cell % width,
		y = Math.floor(cell / width);
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
	while (cur > left && owners[cur - 1] !== code) cur--;
	if (cur === left) return true;
	cur = cell;
	while (cur < right && owners[cur + 1] !== code) cur++;
	if (cur === right) return true;
	cur = cell;
	while (cur > top && owners[cur - width] !== code) cur -= width;
	if (cur === top) return true;
	cur = cell;
	while (cur < bottom && owners[cur + width] !== code) cur += width;
	return cur === bottom;
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
	code: number,
	starts: Set<number>,
	bounds: Bounds,
	width: number,
): number[] | undefined {
	let remaining = LOCAL_SEARCH_BUDGET;
	const holes = new Set<number>();
	localOutside.clear();
	for (const start of starts) {
		if (owners[start] === code || holes.has(start) || localOutside.has(start))
			continue;
		// Gains and bulk captures also queue exterior cells. Reuse the loss gate
		// before a broad open component can exhaust the local flood budget.
		if (hasStraightExit(owners, code, start, width, bounds)) {
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
				y = Math.floor(cell / width);
			if (
				x <= bounds.left ||
				x >= bounds.right ||
				y <= bounds.top ||
				y >= bounds.bottom
			) {
				open = true;
				break;
			}
			for (const next of [cell - width, cell + 1, cell + width, cell - 1]) {
				if (owners[next] === code || localSeen.has(next)) continue;
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
