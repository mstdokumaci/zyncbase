# Cordon Off profiling

Measured September 9, 2026 with Bun 1.4.0, macOS x64, Intel Core i9-9880H. Baseline: `9f6c5982240aa73c0960d056453db3f25ee95227`.

## Selected algorithm

1. All movers paint before enclosure resolution. Countries are processed in first territory-change order, at most once per tick, including countries affected by captures.
2. A gain's eight-neighbor ring can prove that it cannot create a hole. A lost pixel with a straight route to the country's conservative bounding-box edge needs no defensive reclaim. Failed proofs request a search; they do not assume an enclosure exists.
3. Each candidate first gets the same bounds-limited straight-exit proof. Unresolved components share a **1,024-cell local flood budget per country per tick**. Proven exterior cells are reused between candidates. No pixels are painted unless every candidate is resolved. Candidate storage is also capped at 1,024; exceeding the storage or flood limit requests one fallback scan. Ray reads are separate from the flood budget and bounded by the country's width and height per candidate.
4. The fallback fills all holes for that country using four-neighbor scanlines and reusable typed arrays. Country masks and capture checks use incrementally maintained bounds, including disconnected territory. The workspace outside those bounds is marked exterior in bulk.
5. Bulk captures enqueue defensive candidates in constant time per pixel, avoiding long straight-ray checks for every captured pixel. Restore performs a full reconciliation for each populated country.

The local flood is bounded; each fallback is linear in world size and runs at most once per country per tick. Overall work still depends on how many countries change, movement checks, and captured area. Bounds only grow and can become loose after losses. This caps repeated searches, not wall-clock latency on arbitrary hardware.

Capture timing deliberately changes from the baseline's immediate per-mover resolution: a closure breached by a later mover in the same tick remains open. Captures within the resolution pass are applied in country order, not simultaneously. Water stays unowned and remains traversable background for enclosure connectivity.

## Final comparison

Three sequential repeats per variant and workload, alternating baseline then candidate, without a sampling profiler or concurrent builds/tests. Every run uses **20 countries, 40 movers, 200 warmup ticks, and 1,200 measured ticks**. The table reports medians across runs. Simulation excludes chunk preparation and database waiting; over-budget counts include chunk preparation and were identical across repeats.

| Layout / movement | Baseline simulation | Candidate simulation | Change | Baseline / candidate p99 | Updates >50 ms, baseline / candidate |
| --- | ---: | ---: | ---: | ---: | ---: |
| Fragmented / scripted | 9,390 ms | 5,997 ms | −36.1% | 69.22 / 36.19 ms | 143 / 0 |
| Fragmented / bots | 2,998 ms | 2,212 ms | −26.2% | 29.82 / 16.55 ms | 2 / 0 |
| Compact / bots | 1,057 ms | 1,263 ms | +19.4% | 15.79 / 16.21 ms | 0 / 0 |

**Outcome equivalence:** baseline and candidate final checksums match for fragmented scripted movement and compact bots. Fragmented bots follow a different trajectory under end-of-tick capture timing, so their reduction is an end-to-end observation, not a comparison of identical calculations. All repeats within each variant produced the same checksum.

## Workload and reproduction

[profile.ts](./profile.ts) uses the real `World.tick` on synthetic all-land terrain in the 2000 × 1000 world. Each country starts with 26,112 home pixels. Compact countries are filled rectangles; fragmented countries are open U shapes with disconnected 5 × 5 outposts. Scripted movers follow deterministic box routes; bot mode uses actual steering and captures. Warmup uses a disposable world; setup, restoration, GC, checksums, and invariants are outside the measured interval. The fixture is not a real coastline or a saved production map.

Run from the repository root with installed workspace dependencies:

```sh
bun examples/cordon-off/profile.ts --mode scripted --shape fragmented --output test-artifacts/cordon-off-profile/repeat-1
bun examples/cordon-off/profile.ts --mode bots --shape fragmented --output test-artifacts/cordon-off-profile/repeat-1
bun examples/cordon-off/profile.ts --mode bots --shape compact --output test-artifacts/cordon-off-profile/repeat-1
```

Repeat into separate directories. For a baseline, use the same harness in a separate checkout of the baseline commit. `--ticks`, `--warmup`, and `--output` control run length and artifact placement; `--profile` saves sampling traces; `--publish` runs against an isolated real ZyncBase database at 20 Hz. Artifacts under `test-artifacts/` are generated and gitignored.

## Validation

`bun test examples/cordon-off` covers exhaustive 4 × 4 masks against an independent boundary flood, cropped bounds and world edges, scratch reuse, the shared local budget, full-scan batching, capture/defense/water behavior, scores/chunks, restart, and randomized gated-vs-unconditional ticks. Timing thresholds are not test assertions. The real-server smoke suite is `bun run test:game`, covering both plaintext and IPv6/TLS.

## Change log

One line per iteration; per-run tables, diagnostics, and reproduction blocks for each are in this file's git history.

- **2026-09-09** — Fresh profile identified the full enclosure fallback as the dominant cost (73.9% of stack samples on a ten-minute fragmented-bot run).
- **2026-09-10** — Straight-exit proof applied to local enclosure candidates before flooding: −40.3% fragmented bots, −30.9% compact bots, −29.2% scripted; 44.3% fewer fallback calls. Baseline `ebe25e5`.
- **2026-09-10** — Bot scoring no longer materializes per-scoring route arrays: −12.5% compact bots, −7.4% fragmented bots.
- **2026-09-11** — 1024-player ramp found the fatal issue: the 16 KB `chunks.dots` cap (not CPU) killed the game at 334+ players (schema 0.3.1 raises it to 128 KB). Added spawn spread with a 16 px spatial hash (1024 same-country spawns: 287 s → ~1 s) and a 2 Hz roster publish throttle.
- **2026-09-11** — Pipelined publish slices with `Promise.allSettled` and `PUBLISH_BATCH_SIZE` 100 → 500: +44% tick rate at 512, +60% at 1024.
- **2026-09-20** — Byte-per-cell palette owners replace `uint16` country ids (schema 0.6.0): payload per write 2.15 → 1.15 KiB, +24% tick rate at 1024. Machine: Ryzen 5 3600 / WSL2.
- **2026-09-22** — Split chunk tables (`country_chunks` RLE claim-only + `user_chunks` JSON coordinates, schema 0.7.0): payload −87% in the paced database control; browser rx −72–90%.
- **2026-09-22** — WSL2 three-pair AB of the split confirmed the 1024 stage: +41% tick rate (8.05 → 11.35 Hz), −38% commit p50, −91% bytes per row. Simulation unchanged within noise.
