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

	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: the two directional scans preserve upstream's neighboring-run seed rules.
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
			const cell = this.stack[--this.top];
			if (labels[cell]) continue;
			const y = Math.floor(cell / width);
			const row = y * width;
			for (let direction = 1; direction >= -1; direction -= 2) {
				let above = true,
					below = true;
				const end = direction === 1 ? row + width : row - 1;
				for (
					let cur = direction === 1 ? cell : cell - 1;
					cur !== end;
					cur += direction
				) {
					if (labels[cur]) break;
					labels[cur] = 1;
					if (y > 0) {
						if (labels[cur - width]) above ||= labels[cur - width] === 2;
						else if (above) {
							this.push(cur - width);
							above = false;
						}
					}
					if (y < height - 1) {
						if (labels[cur + width]) below ||= labels[cur + width] === 2;
						else if (below) {
							this.push(cur + width);
							below = false;
						}
					}
				}
			}
		}
		return labels;
	}
}
