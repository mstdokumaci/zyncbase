import { describe, expect, test } from "bun:test";
import { compareDocIds, packDocId, unpackDocId } from "./doc_id";

/**
 * Pure unit benchmark for the doc-id decode hot path — the per-delta id
 * decode that used to run through BigInt (bytesToBigInt → decodeUuidV7DocId
 * → formatUuidBytes). Now byte-level with a bounded decode cache and LUT.
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
		expect(elapsedMs).toBeLessThan(50);
	});

	test("200k unpackDocId calls across 2,000 UUIDs stay within budget", () => {
		const ids: Uint8Array[] = [];
		for (let i = 0; i < 2000; i += 1) {
			const hexIndex = i.toString(16).padStart(4, "0");
			const suffix = (i * 7).toString(16).padStart(8, "0");
			ids.push(packDocId(`019c1e50-7d11-7000-8000-${hexIndex}${suffix}`));
		}

		const warmup = 20_000;
		for (let i = 0; i < warmup; i += 1) {
			unpackDocId(ids[i % ids.length]);
		}

		const iterations = 200_000;
		const t0 = performance.now();
		let last = "";
		for (let i = 0; i < iterations; i += 1) {
			last = unpackDocId(ids[i % ids.length]);
		}
		const elapsedMs = performance.now() - t0;

		console.log(
			`2,000-ID unpackDocId (${iterations} calls) [ms]: ${elapsedMs.toFixed(1)}  ` +
				`(${((elapsedMs / iterations) * 1000).toFixed(3)}µs/call)`,
		);

		expect(last).toBe("019c1e50-7d11-7000-8000-07cf000036a9");
		expect(elapsedMs).toBeLessThan(100);
	});

	test("100k repeated short-ID decodes stay within budget", () => {
		const ids = Array.from({ length: 100 }, (_, i) => packDocId(`task_${i}`));

		const warmup = 20_000;
		for (let i = 0; i < warmup; i += 1) {
			unpackDocId(ids[i % ids.length].subarray());
		}

		const inputs = Array.from({ length: 100_000 }, (_, i) =>
			ids[i % ids.length].subarray(),
		);
		const t0 = performance.now();
		let last = "";
		for (const bytes of inputs) {
			last = unpackDocId(bytes);
		}
		const elapsedMs = performance.now() - t0;

		console.log(
			`cached short unpackDocId (${inputs.length} calls) [ms]: ${elapsedMs.toFixed(1)}  ` +
				`(${((elapsedMs / inputs.length) * 1000).toFixed(3)}µs/call)`,
		);

		expect(last).toBe("task_99");
		expect(elapsedMs).toBeLessThan(60);
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
		expect(elapsedMs).toBeLessThan(60);
	});
});
