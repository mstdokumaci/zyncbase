# Cordon Off profiling

Measured September 9, 2026 with Bun 1.4.0, macOS x64, Intel Core i9-9880H. Baseline: `9f6c5982240aa73c0960d056453db3f25ee95227`.

## Selected algorithm

1. All movers paint before enclosure resolution. Countries are processed in first territory-change order, at most once per tick, including countries affected by captures.
2. A gain can only enclose what sits beside it, and only while that pixel was the last way out, so the gate is the same straight-exit proof run after the claim: a neighbour it can still prove open is not at risk. A ring with no country pixel at all is skipped outright, because the open ring is itself eight-connected and dropping one cell from it severs nothing. A lost pixel with a straight route to the country's conservative bounding-box edge needs no defensive reclaim. Failed proofs request a search; they do not assume an enclosure exists.
3. Before any ray walk, the gate counts the open runs around the claimed pixel. The ring is walked in cyclic order, so consecutive entries are eight-adjacent and a single open run means every open neighbour is still joined around the new wall: nothing beside that pixel can be severed, and the proof is skipped. An incomplete ring at the array edge is never counted this way, because its run boundary may sit off the array; it falls through to the proof. Skipping those rays is what keeps the gate off the hot path: with them, nine contending nations drive the fallback scan count from 570 to 2,949 over 6,000 ticks.
4. Each candidate first gets the same bounds-limited straight-exit proof. Unresolved components share a **16,384-cell flood budget per country per tick**. The flood is a depth-first dive ordered toward the nearest bound, so an exterior-connected component is proven open in about the length of its shortest route instead of the area it covers; flat stamp maps make each visited cell one typed-array write. Proven exterior cells are reused between candidates. No pixels are painted unless every candidate is resolved. Candidate storage shares the same cap; exceeding the storage or flood limit requests one fallback scan. Ray reads are separate from the flood budget and bounded by the country's width and height per candidate.
5. The fallback is a run-length eight-connected flood over the country's bounds. Every open pixel in a row is one run, two runs in adjacent rows touch when their spans overlap by a pixel or more, and a hole is a run no perimeter run reaches, so a bbox costs one read per pixel and then work proportional to the run count. Country masks and capture checks use incrementally maintained bounds, including disconnected territory. Nothing outside those bounds is read; runs touching the bounds perimeter seed the flood as exterior.
6. A fill takes its whole region in one bulk capture instead of calling `claim` per pixel: the owner write stays in the loop and the roster counters, capture credit, dirty sets, bounds and chunk index move out of it. Chunk index and bounds come from the ascending cell order, so no division runs per pixel. Bulk captures enqueue defensive candidates in constant time per pixel, avoiding long straight-ray checks for every captured pixel. Restore performs a full reconciliation for each populated country.

The local flood is bounded; each fallback is linear in the country's bounds and runs at most once per country per tick. Overall work still depends on how many countries change, movement checks, and captured area. Bounds only grow and can become loose after losses. This caps repeated searches, not wall-clock latency on arbitrary hardware.

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
- **2026-10-12** — Dive-ordered local flood on flat stamp maps, budget 1,024 → 16,384: simulation −77% scripted fragmented, −62% bots fragmented, −20% bots compact; fallbacks 4,704 → 40. Baseline `5eb57fc`.
- **2026-10-12** — Targeted cue rows replace the forced roster flush; client renders the scoreboard once per frame with a reused number formatter: browser rx 16.0 → 9.8 MiB and script/tick −33% at 1,024. Baseline `5eb57fc`.
