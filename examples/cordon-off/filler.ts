export type Bounds = {
	left: number;
	right: number;
	top: number;
	bottom: number;
};

// Enclosure is eight-connected: a pixel is captured only when nothing reaches
// the exterior through any of its eight neighbours, so a diagonal gap always
// keeps the ground open.
//
// Runs make that cheap. Every open pixel in a row is one run, two runs in
// adjacent rows touch when their spans overlap by a pixel or more, and a hole is
// a run no perimeter run reaches. So a bbox costs one read per pixel to build
// its runs and then work proportional to the number of runs, which for real
// territory is tiny next to the pixel count.
export class HoleFiller {
	private runStart = new Int32Array(1024);
	private runEnd = new Int32Array(1024);
	private runRow = new Int32Array(1024);
	/** First run of each row, indexed by absolute y; `height + 2` is fixed. */
	private readonly rowRun: Int32Array;
	private reached = new Uint8Array(1024);
	private queue = new Int32Array(1024);
	private holes = new Int32Array(1024);

	constructor(
		private readonly width: number,
		height: number,
	) {
		this.rowRun = new Int32Array(height + 2);
	}

	/**
	 * Captured cells in ascending order, as a view of reusable scratch. Runs are
	 * built row by row, so the view is already sorted and needs no second pass.
	 * A tight 4-connected wall still holds; a diagonal one no longer does.
	 */
	// biome-ignore lint/complexity/noExcessiveCognitiveComplexity: build the runs, flood them from the perimeter, then report whatever the flood never reached.
	fill(owners: Uint16Array, countryId: number, bounds: Bounds): Int32Array {
		const { left, right, top, bottom } = bounds,
			width = this.width;
		let count = 0,
			open = 0;
		// One read per pixel: a run ends at the first country pixel after it.
		for (let y = top; y <= bottom; y++) {
			this.rowRun[y] = count;
			const base = y * width;
			let x = left;
			while (x <= right) {
				if (owners[base + x] === countryId) {
					x++;
					continue;
				}
				const start = x;
				do {
					x++;
				} while (x <= right && owners[base + x] !== countryId);
				if (count === this.runStart.length) this.growRuns(count + 1);
				this.runStart[count] = start;
				this.runEnd[count] = x - 1;
				this.runRow[count] = y;
				count++;
				open += x - start;
			}
		}
		this.rowRun[bottom + 1] = count;
		if (count === 0) return this.holes.subarray(0, 0);
		this.reached.fill(0, 0, count);
		let head = 0,
			tail = 0;
		// Runs touching the rectangle's edge start on the outside, which is open.
		for (let y = top; y <= bottom; y++) {
			const from = this.rowRun[y],
				to = this.rowRun[y + 1],
				edge = y === top || y === bottom;
			for (let i = from; i < to; i++)
				if (edge || this.runStart[i] === left || this.runEnd[i] === right) {
					this.reached[i] = 1;
					this.queue[tail++] = i;
				}
		}
		while (head < tail) {
			const run = this.queue[head++],
				y = this.runRow[run],
				from = this.runStart[run] - 1,
				to = this.runEnd[run] + 1;
			for (let pass = 0; pass < 2; pass++) {
				const row = pass === 0 ? y - 1 : y + 1;
				if (row < top || row > bottom) continue;
				const rowFrom = this.rowRun[row],
					rowTo = this.rowRun[row + 1];
				// Row ends ascend, so the first run reaching `from` is a binary
				// search rather than a walk of the whole row.
				let lo = rowFrom,
					hi = rowTo;
				while (lo < hi) {
					const mid = (lo + hi) >> 1;
					if (this.runEnd[mid] < from) lo = mid + 1;
					else hi = mid;
				}
				for (let i = lo; i < rowTo && this.runStart[i] <= to; i++)
					if (!this.reached[i]) {
						this.reached[i] = 1;
						this.queue[tail++] = i;
					}
			}
		}
		this.growHoles(open);
		let holes = 0;
		for (let i = 0; i < count; i++)
			if (!this.reached[i]) {
				const base = this.runRow[i] * width;
				for (
					let cell = base + this.runStart[i];
					cell <= base + this.runEnd[i];
					cell++
				)
					this.holes[holes++] = cell;
			}
		return this.holes.subarray(0, holes);
	}

	// ponytail: doubling keeps the amortised cost per run at one copy per pixel
	// of growth, the same trick the scanline stack used. Runs stay sparse for real
	// territory; only a checkerboard bbox approaches one run per two pixels.
	private growRuns(size: number) {
		let next = this.runStart.length;
		while (next < size) next *= 2;
		const starts = new Int32Array(next);
		starts.set(this.runStart);
		this.runStart = starts;
		const ends = new Int32Array(next);
		ends.set(this.runEnd);
		this.runEnd = ends;
		const rows = new Int32Array(next);
		rows.set(this.runRow);
		this.runRow = rows;
		// Reached marks and the flood queue are indexed by run, so they grow with
		// the runs: one capacity covers all four.
		this.reached = new Uint8Array(next);
		this.queue = new Int32Array(next);
	}

	private growHoles(size: number) {
		if (size <= this.holes.length) return;
		let next = this.holes.length;
		while (next < size) next *= 2;
		const grown = new Int32Array(next);
		grown.set(this.holes);
		this.holes = grown;
	}
}
