import { describe, expect, test } from "bun:test";
import { compareDocIds, packDocId, unpackDocId } from "./doc_id";

/**
 * Pure unit benchmark for the doc-id decode hot path — the per-delta id
 * decode that used to run through BigInt (bytesToBigInt → decodeUuidV7DocId
 * → formatUuidBytes). Now byte-level with a LUT hex formatter.
 */
describe("doc_id performance", () => {
	test("500k unpackDocId calls stay within budget", () => {
		const ids: Uint8Array[] = [];
		for (let i = 0; i < 100; i += 1) {
			const suffix = String(i).padStart(8, "0");
			ids.push(packDocId(`0189abcd-ef12-7345-89ab-cdef${suffix}`));
		}

		const warmup = 20_000;
		for (let i = 0; i < warmup; i += 1) {
			unpackDocId(ids[i % ids.length]);
		}

		const iterations = 500_000;
		const t0 = performance.now();
		let last = "";
		for (let i = 0; i < iterations; i += 1) {
			last = unpackDocId(ids[i % ids.length]);
		}
		const elapsedMs = performance.now() - t0;

		console.log(
			`unpackDocId (${iterations} calls) [ms]: ${elapsedMs.toFixed(1)}  ` +
				`(${((elapsedMs / iterations) * 1000).toFixed(3)}µs/call)`,
		);

		// Sanity: the decode produced a correct value, not just a fast one.
		expect(last).toBe("0189abcd-ef12-7345-89ab-cdef00000099");
		// Measured ~0.12µs/call (≈60ms for 500k). Threshold has ~10x headroom
		// for CI variance; the old BigInt path ran ~40x slower and fails here.
		expect(elapsedMs).toBeLessThan(600);
	});

	test("500k compareDocIds calls stay within budget", () => {
		const ids = Array.from(
			{ length: 100 },
			(_, i) => `0189abcd-ef12-7345-89ab-cdef${String(i).padStart(8, "0")}`,
		);

		const warmup = 20_000;
		for (let i = 0; i < warmup; i += 1) {
			compareDocIds(ids[i % ids.length], ids[(i * 17) % ids.length]);
		}

		const iterations = 500_000;
		const t0 = performance.now();
		for (let i = 0; i < iterations; i += 1) {
			compareDocIds(ids[i % ids.length], ids[(i * 17) % ids.length]);
		}
		const elapsedMs = performance.now() - t0;

		console.log(
			`compareDocIds (${iterations} calls) [ms]: ${elapsedMs.toFixed(1)}  ` +
				`(${((elapsedMs / iterations) * 1000).toFixed(3)}µs/call)`,
		);

		expect(compareDocIds(ids[0], ids[1])).toBeLessThan(0);
		// Direct comparison is ~0.2µs/call locally. Repacking both IDs took
		// ~5µs/call and fails this budget.
		expect(elapsedMs).toBeLessThan(600);
	});
});
