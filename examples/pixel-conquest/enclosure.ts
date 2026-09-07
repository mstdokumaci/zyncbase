import { WIDTH } from "./shared";

export type Bounds = {
	left: number;
	right: number;
	top: number;
	bottom: number;
};

export function neighbors(cell: number) {
	return [cell - WIDTH, cell + 1, cell + WIDTH, cell - 1];
}

// A component reaching a country's bounding edge has an unobstructed route outside.
// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: flood until the component closes or reaches the outside.
export function enclosedRegion(
	owners: Uint16Array,
	code: number,
	bounds: Bounds,
	start: number,
) {
	if (owners[start] === code) return [];
	const cells = [start];
	const seen = new Set(cells);
	for (let head = 0; head < cells.length; head++) {
		const cell = cells[head],
			x = cell % WIDTH,
			y = Math.floor(cell / WIDTH);
		if (
			x <= bounds.left ||
			x >= bounds.right ||
			y <= bounds.top ||
			y >= bounds.bottom
		)
			return [];
		for (const next of neighbors(cell)) {
			if (owners[next] === code || seen.has(next)) continue;
			seen.add(next);
			cells.push(next);
		}
	}
	return cells;
}

// Startup reconciliation visits each component once, including open components.
// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: seed the rectangle edges, flood the exterior, then collect its interior.
export function enclosedOnRestore(
	owners: Uint16Array,
	code: number,
	bounds: Bounds,
) {
	const outside = new Set<number>();
	const queue: number[] = [];
	const visit = (cell: number) => {
		if (owners[cell] === code || outside.has(cell)) return;
		outside.add(cell);
		queue.push(cell);
	};
	for (let x = bounds.left; x <= bounds.right; x++) {
		visit(bounds.top * WIDTH + x);
		visit(bounds.bottom * WIDTH + x);
	}
	for (let y = bounds.top; y <= bounds.bottom; y++) {
		visit(y * WIDTH + bounds.left);
		visit(y * WIDTH + bounds.right);
	}
	for (let head = 0; head < queue.length; head++) {
		const cell = queue[head],
			x = cell % WIDTH,
			y = Math.floor(cell / WIDTH);
		if (x > bounds.left) visit(cell - 1);
		if (x < bounds.right) visit(cell + 1);
		if (y > bounds.top) visit(cell - WIDTH);
		if (y < bounds.bottom) visit(cell + WIDTH);
	}
	const enclosed: number[] = [];
	for (let y = bounds.top + 1; y < bounds.bottom; y++) {
		for (let x = bounds.left + 1; x < bounds.right; x++) {
			const cell = y * WIDTH + x;
			if (owners[cell] !== code && !outside.has(cell)) enclosed.push(cell);
		}
	}
	return enclosed;
}
