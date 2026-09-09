# Pixel Conquest enclosure profiling

Measured September 9, 2026 with Bun 1.4.0, macOS x64, Intel Core i9-9880H. Baseline: `9f6c5982240aa73c0960d056453db3f25ee95227`.

The selected implementation combines safe gates, bounded local searches, cached country bounds, and a TypeScript scanline fallback. It reduces simulation time and long updates on fragmented territory. Compact bot simulation remains slightly slower in absolute time; this is a tradeoff for bounded enclosure work, not a universal speedup.

## Selected algorithm

1. All movers paint before enclosure resolution. Countries are processed in first territory-change order, at most once per tick, including countries affected by captures.
2. A gain's eight-neighbor ring can prove that it cannot create a hole. A lost pixel with a straight route to the country's conservative bounding-box edge needs no defensive reclaim. Failed proofs request a search; they do not assume an enclosure exists.
3. Candidate components share a **1,024-cell local search budget per country per tick**. Proven exterior cells are reused between candidates. No pixels are painted unless every candidate is resolved within the budget. Candidate storage is also capped; exceeding either limit requests one fallback scan.
4. The fallback fills all holes for that country using four-neighbor scanlines and reusable typed arrays. Country masks and capture checks use incrementally maintained bounds, including disconnected territory. The workspace outside those bounds is marked exterior in bulk.
5. Bulk captures enqueue defensive candidates in constant time per pixel, avoiding long straight-ray checks for every captured pixel. Restore performs a full reconciliation for each populated country.

The local flood is bounded; each fallback is linear in world size and runs at most once per country per tick. Overall work still depends on how many countries change, movement checks, and captured area. Bounds only grow and can become loose after losses. This caps repeated searches, not wall-clock latency on arbitrary hardware.

Capture timing deliberately changes from the baseline's immediate per-mover resolution: a closure breached by a later mover in the same tick remains open. Captures within the resolution pass are applied in country order, not simultaneously. Water stays unowned and remains traversable background for enclosure connectivity.

## Final comparison

Three sequential repeats per variant and workload, alternating baseline then candidate, without a sampling profiler or concurrent builds/tests. Every run uses **20 countries, 40 movers, 200 warmup ticks, and 1,200 measured ticks**. The table reports medians across runs, including the median of the three per-run p99 values. Simulation excludes chunk preparation and database waiting. Over-budget counts include chunk preparation and were identical across the three repeats.

| Layout / movement | Baseline simulation | Candidate simulation | Change | Baseline / candidate p99 | Updates >50 ms, baseline / candidate |
| --- | ---: | ---: | ---: | ---: | ---: |
| Fragmented / scripted | 9,390 ms | 5,997 ms | −36.1% | 69.22 / 36.19 ms | 143 / 0 |
| Fragmented / bots | 2,998 ms | 2,212 ms | −26.2% | 29.82 / 16.55 ms | 2 / 0 |
| Compact / bots | 1,057 ms | 1,263 ms | +19.4% | 15.79 / 16.21 ms | 0 / 0 |

Simulation total ranges were 9,339–9,460 vs 5,972–6,070 ms for fragmented scripted movement, 2,984–3,048 vs 2,162–2,247 ms for fragmented bots, and 1,053–1,084 vs 1,254–1,276 ms for compact bots. The compact regression adds about 0.17 ms per tick on average. Chunk preparation totals had medians of 169–218 ms across these variants and workloads.

**Outcome equivalence:** baseline and candidate final checksums match for fragmented scripted movement and compact bots. Fragmented bots follow a different trajectory under end-of-tick capture timing, so their 26.2% reduction is an end-to-end observation, not a comparison of identical calculations. The candidate matches the unconditional end-of-tick filler on that workload. All repeats within each variant produced the same checksum.

| Workload | Final SHA-256 |
| --- | --- |
| Fragmented scripted, both variants | `ba7e0c52623ef576f18dfbaddf1563a5784632b7195eac248974ed954a8ef25b` |
| Compact bots, both variants | `adbc15375c4724ed974afd3fecfe7a6813fff4322405f76588e4aa75ab18f6af` |
| Fragmented bots, baseline | `d9dc542e6a853ef3125a9ad49da983b7f0674d2dbffd8c99b20b5682bced7d7a` |
| Fragmented bots, candidate and unconditional end-of-tick filler | `68e5f48438f0bf2243c5d4fc93ea42e03f34c0b12c1ee59e87fdab52425e95f7` |

## Workload and reproduction

[profile.ts](./profile.ts) uses the real `World.tick` on synthetic all-land terrain in the 2000 × 1000 world. Each country starts with 26,112 home pixels. Compact countries are filled rectangles; fragmented countries are open U shapes with disconnected 5 × 5 outposts in a rival's bay, totaling 522,740 initially owned pixels. The fixture is not the real coastline or a saved production map.

Scripted movers follow deterministic box routes without AI planning. Bot mode uses actual steering, route planning, movement, and captures; only the fixture's population policy allows 40 bots without humans. Warmup uses a disposable world, then the measured world is recreated. Setup, restoration, initial database writes, explicit pre-run GC, checksums, and invariants are outside the measured interval. Local runs execute without sleeping; 1,200 ticks represent 60 seconds of game time.

Run from the repository root with installed workspace dependencies:

```sh
bun examples/pixel-conquest/profile.ts --mode scripted --shape fragmented --output test-artifacts/pixel-conquest-profile/repeat-1
bun examples/pixel-conquest/profile.ts --mode bots --shape fragmented --output test-artifacts/pixel-conquest-profile/repeat-1
bun examples/pixel-conquest/profile.ts --mode bots --shape compact --output test-artifacts/pixel-conquest-profile/repeat-1
```

Repeat into separate directories. For the baseline, use the same harness in a separate checkout of the baseline commit above, with that checkout's original `world.ts` and `enclosure.ts`. The recorded baseline source snapshot differs only in import paths needed to run beside the candidate. Final raw results are in `test-artifacts/pixel-conquest-profile/mr-{baseline,candidate}-{1,2,3}/`; these are generated local artifacts, not committed source.

Additional controls:

```sh
bun examples/pixel-conquest/profile.ts --countries 4 --mode bots --shape fragmented
bun examples/pixel-conquest/profile.ts --mode bots --profile
bun examples/pixel-conquest/profile.ts --mode bots --publish
GAME_BENCH=1 bun test examples/pixel-conquest/enclosure.perf.test.ts
```

`--ticks`, `--warmup`, and `--output` control run length and artifact placement. `--profile` saves Bun's function summary, bytecode summary, and sampling traces in `.profile.json`; run sampling separately from timing. `--publish` uses an isolated real ZyncBase database, the game schema, test authorization, the SDK, and committed acknowledgments, paced at 20 Hz. It requires the repository's native build prerequisites. No browser subscribers, presence inputs, TLS, or subscriber fan-out are simulated.

Every successful run checks player/country counts, owner IDs, country totals against the full ownership bitmap, and player positions. Checksums cover ownership and player state. Publishing confirms commits but does not independently reload the full persisted map.

## Measurements behind the selection

Initial baseline sampling attributed 67.6% of sampled JavaScript execution to enclosure traversal with fragmented bots, and 97.6% with fragmented scripted movement. Bot planning accounted for 25.2% in the bot profile. These are sampled stack shares, including callees, not percentages of all Bun process CPU or allocation volume; JIT inlining limits exact line attribution.

Earlier experiments, before the final three-repeat comparison:

- Unconditional whole-world filling took about 148 seconds for the fragmented scripted run. Batching per changed country and clipping masks reduced that to about 23 seconds, still slower than baseline.
- Gates alone left a shared full-map bounds rebuild as a major cost. Incremental bounds and a bounded local flood removed that repeated work. Cached exterior results, bounds-limited rays, and local handling at world edges reduced remaining scans.
- In separate instrumented compact-bot runs, increasing the shared local budget from 256 to 1,024 reduced fallback calls from 181 to 80. Instrumented timings were not used in the final comparison.
- Clearing only a workspace halo did not improve compact-game time and regressed a wide-U kernel case by about 12%. Explicit horizontal span filling regressed comb-shaped kernel work by about 1.9×. Both kernel changes were rejected; the selected port retains full workspace clearing and the original two-direction scan.

An earlier baseline publishing run completed 1,200 ticks in 60.39 seconds and averaged about 0.12 Bun CPU cores, excluding the separate ZyncBase process. It **did not reproduce the reported sustained two-core load**. An unpaced publishing attempt timed out waiting for a committed acknowledgment at tick 372; the cause remains unverified. `--publish --unpaced` is retained to investigate that separate issue, not as a capacity result.

The local comparisons select an enclosure implementation. They do not establish production capacity or explain every source of the reported server load. This development machine also runs FortiEDR; a production comparison should use representative saved territory, inputs, and subscription traffic.

## Follow-up: bot scoring allocations

Same machine and harness as above, three interleaved repeats per variant for
compact bots (candidate then baseline in each pair to reduce drift), and one
run per variant for fragmented bots: 20 countries, 40 movers, 200 warmup
ticks, 1,200 measured ticks. Here, baseline means the enclosure implementation
selected above with the original array-based bot scorer; candidate adds the
bot scoring change. `planBot` built `cells`, an `approach` array, a sliced
route and a `Set` for each scoring (up to 324 per think), plus one reversed
route per patch and an extra approach for coastal returns. Scoring now avoids
those per-scoring route arrays and materializes only the winning plan; small
iteration arrays and a fresh `Set` remain. Final checksums match the compact
bot and candidate fragmented bot values above. These all-land fixtures do not
exercise coastal sweeps or prove every intermediate decision is identical.

| Workload | Baseline simulation | Candidate simulation | Change |
| --- | ---: | ---: | ---: |
| Compact / bots | 1,306–1,322 ms | 1,144–1,158 ms | −12.5% (medians) |
| Fragmented / bots | 2,292 ms | 2,122 ms | −7.4% (single runs) |

p99 simulation improved from ~16.5–18.1 to ~15.2–15.4 ms on compact bots.
A shared scoring `Set` with per-candidate `clear()` was tried first and
regressed compact bots by ~15% in local trials. The kept change passes a
fresh `Set` per scoring and removes the route-array traffic.

Local paced publishing (4 countries, 200 ticks) still averages ~0.03 Bun
CPU cores and does not reproduce the reported sustained two-core VM load.
Next candidates in profile order: grow-only country bounds (fallback scan
areas already reach ~1.3M cells after 400 ticks and keep the full-world
`labels.fill`; the memset itself is only ~3% of a fragmented run) and
`chunk()` `DataView`/`JSON` serialization. Either needs VM tick-stat logs
over a long session before it can be tied to the production load.

## Validation

`bun test examples/pixel-conquest` covers exhaustive 4 × 4 masks against an independent boundary flood, cropped bounds and world edges, scratch reuse, the shared local budget, full-scan batching, capture/defense/water behavior, scores/chunks, restart, and randomized gated-vs-unconditional ticks. Timing thresholds are not test assertions. The real-server smoke suite is `bun run test:game`, covering both plaintext and IPv6/TLS.
