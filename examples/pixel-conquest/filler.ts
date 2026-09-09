export type Bounds = {
	left: number;
	right: number;
	top: number;
	bottom: number;
};

export class HoleFiller {
	private readonly labels: Uint8Array;
	private stack = new Uint32Array(1024);
	private top = 0;

	constructor(
		private readonly width: number,
		private readonly height: number,
	) {
		this.labels = new Uint8Array(width * height);
	}

	private push(cell: number) {
		if (this.top === this.stack.length) {
			const grown = new Uint32Array(this.stack.length * 2);
			grown.set(this.stack);
			this.stack = grown;
		}
		this.stack[this.top++] = cell;
	}

	private seedEdge(start: number, step: number, count: number) {
		let placed = false;
		for (let i = 0, cell = start; i < count; i++, cell += step) {
			if (this.labels[cell] === 0) {
				if (!placed) this.push(cell);
				placed = true;
			} else placed = false;
		}
	}

	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: Milazzo rectangular-block spine with deferred fringe seeds.
	fill(owners: Uint16Array, code: number, bounds: Bounds): Uint8Array {
		const labels = this.labels,
			width = this.width,
			height = this.height;
		const { left, right, top, bottom } = bounds;
		// Bounds must contain every pixel of this country. All other cells connect
		// to the world edge; only the supplied rectangle needs mask preparation.
		labels.fill(1);
		for (let y = top; y <= bottom; y++) {
			const end = y * width + right;
			for (let cell = y * width + left; cell <= end; cell++)
				labels[cell] = owners[cell] === code ? 2 : 0;
		}
		this.top = 0;
		this.seedEdge(top * width + left, 1, right - left + 1);
		this.seedEdge(bottom * width + left, 1, right - left + 1);
		this.seedEdge(top * width + left, width, bottom - top + 1);
		this.seedEdge(top * width + right, width, bottom - top + 1);
		while (this.top) {
			const seed = this.stack[--this.top];
			if (labels[seed]) continue;
			let x = seed % width;
			let y = (seed - x) / width;
			// Up/left are already set for core-originated seeds, so this is a
			// no-op there and only costs two blocked-cell checks.
			while (true) {
				const ox = x,
					oy = y;
				while (y !== 0 && labels[(y - 1) * width + x] === 0) y--;
				while (x !== 0 && labels[y * width + x - 1] === 0) x--;
				if (x === ox && y === oy) break;
			}
			// MyFillCore: fill rectangular blocks down-right, defer fringes.
			let lastRowLength = 0;
			while (true) {
				let rowLength = 0;
				let sx = x;
				const rowBase = y * width;
				if (lastRowLength !== 0 && labels[rowBase + x] !== 0) {
					while (true) {
						if (--lastRowLength === 0) break;
						++x;
						if (labels[rowBase + x] === 0) break;
					}
					if (lastRowLength === 0) break;
					sx = x;
				} else {
					while (x !== 0 && labels[rowBase + x - 1] === 0) {
						--x;
						labels[rowBase + x] = 1;
						rowLength++;
						lastRowLength++;
						if (
							y !== 0 &&
							labels[rowBase - width + x] === 0 &&
							labels[rowBase - width + x + 1] !== 0
						)
							this.push(rowBase - width + x);
					}
				}
				while (sx < width && labels[rowBase + sx] === 0) {
					labels[rowBase + sx] = 1;
					rowLength++;
					sx++;
				}
				if (rowLength < lastRowLength) {
					const end = x + lastRowLength;
					for (let gx = sx + 1; gx < end; gx++) {
						if (labels[rowBase + gx] === 0 && labels[rowBase + gx - 1] !== 0)
							this.push(rowBase + gx);
					}
				} else if (rowLength > lastRowLength && y !== 0) {
					const aboveBase = rowBase - width;
					const start = x + lastRowLength;
					for (let ux = start + 1; ux < sx; ux++) {
						if (
							labels[aboveBase + ux] === 0 &&
							(ux === start + 1 || labels[aboveBase + ux - 1] !== 0)
						)
							this.push(aboveBase + ux);
					}
				}
				lastRowLength = rowLength;
				if (lastRowLength === 0) break;
				if (++y >= height) break;
			}
		}
		return labels;
	}
}
