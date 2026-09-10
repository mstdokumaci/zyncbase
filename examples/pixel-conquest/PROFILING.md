# Pixel Conquest enclosure profiling

Measured September 9, 2026 with Bun 1.4.0, macOS x64, Intel Core i9-9880H. Baseline: `9f6c5982240aa73c0960d056453db3f25ee95227`.

The selected implementation combines safe gates, bounded local searches, cached country bounds, and a TypeScript scanline fallback. The [September 10 iteration](#iteration-2026-09-10-straight-exit-checks-for-local-candidates) applies the existing straight-exit proof to local candidates, avoiding more fallback scans while preserving game outcomes. Earlier comparisons below describe their own baselines.

## Selected algorithm

1. All movers paint before enclosure resolution. Countries are processed in first territory-change order, at most once per tick, including countries affected by captures.
2. A gain's eight-neighbor ring can prove that it cannot create a hole. A lost pixel with a straight route to the country's conservative bounding-box edge needs no defensive reclaim. Failed proofs request a search; they do not assume an enclosure exists.
3. Each candidate first gets the same bounds-limited straight-exit proof. Unresolved components share a **1,024-cell local flood budget per country per tick**. Proven exterior cells are reused between candidates. No pixels are painted unless every candidate is resolved. Candidate storage is also capped at 1,024; exceeding the storage or flood limit requests one fallback scan. Ray reads are separate from the flood budget and bounded by the country's width and height per candidate.
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

`bun test examples/pixel-conquest` covers exhaustive 4 × 4 masks against an independent boundary flood, cropped bounds and world edges, scratch reuse, the shared local budget, full-scan batching, capture/defense/water behavior, scores/chunks, restart, and randomized gated-vs-unconditional ticks. Bot scoring is compared with materialized reference routes for both directions and approach orders, revisits, coastal returns, ties, and world borders. Timing thresholds are not test assertions. The real-server smoke suite is `bun run test:game`, covering both plaintext and IPv6/TLS.

## Fresh profile: 2026-09-09

**The next target is the full enclosure fallback.** On a ten-minute fragmented
bot simulation, enclosure processing accounts for 73.9% of recorded stack
samples, including 60.3% inside `HoleFiller.fill`. Bot planning accounts for
18.8% and chunk preparation for 6.1%. Recomputing country bounds looks
unpromising in this fixture: the stored bounds remain almost tight.

Source: `ae1b60b` (`Example game bot performance`), with no game or database
implementation changes. Machine: Intel Core i9-9880H, macOS x64, Bun 1.4.0.
The existing SDK was rebuilt before the database run. Builds and checks ran
outside measurement intervals. Raw JSON, sampling traces, logs and the
diagnostic preload are in
[`fresh-20260909`](../../test-artifacts/pixel-conquest-profile/fresh-20260909/).
These are local generated artifacts.

### Fresh timing baseline

Three sequential repeats per workload, each with 20 countries, 40 movers,
200 disposable warmup ticks and 1,200 measured ticks. Workload order in each
repeat was fragmented bots, compact bots, fragmented scripted. Sampling was
disabled. Values are medians across runs; simulation ranges are in parentheses.

| Workload | Simulation total | Chunk preparation total | Simulation p99 | Whole update p99 | Updates >50 ms, by repeat |
| --- | ---: | ---: | ---: | ---: | --- |
| Fragmented bots | 2,060 ms (2,025–2,072) | 211 ms | 15.21 ms | 15.55 ms | 0 / 0 / 0 |
| Compact bots | 1,106 ms (1,106–1,130) | 166 ms | 15.05 ms | 15.41 ms | 0 / 0 / 0 |
| Fragmented scripted | 6,127 ms (6,044–6,160) | 205 ms | 36.86 ms | 37.38 ms | 0 / 1 / 0 |

All repeats and their separate sampled runs retain the previously documented
final checksums for the selected implementation. These results are a new
baseline, not a measured optimization against the older report.

### Where Bun spends its time

Separate runs used the harness's `--profile` option. Percentages below count
recorded stack traces containing the named function, including callees.
The filler column is a subset of enclosure processing; the two must not be
added together. Samples describe the measured Bun workload, not ZyncBase CPU
usage or a breakdown of every Bun background thread.

| Workload | Stack samples | Enclosure processing | Filler, included at left | Bot planning | Chunk preparation |
| --- | ---: | ---: | ---: | ---: | ---: |
| Fragmented bots, 1,200 ticks | 1,852 | 58.6% | 46.6% | 30.0% | 9.4% |
| Compact bots, 1,200 ticks | 1,050 | 29.9% | 23.8% | 56.0% | 11.6% |
| Fragmented scripted, 1,200 ticks | 5,218 | 96.4% | 78.0% | 0% | 3.2% |
| Fragmented bots, 12,000 ticks | 27,224 | 73.9% | 60.3% | 18.8% | 6.1% |

The unsampled 12,000-tick run represents ten minutes of game time and took
35.08 seconds: 32.96 seconds of simulation and 2.10 seconds of chunk
preparation. Whole-update p99 was 16.75 ms, maximum 37.76 ms, with no updates
over 50 ms. This longer timing is a single run.

### Why the filler remains expensive

The implementation already uses horizontal scanline filling and reusable
scratch buffers. Each fallback still clears the full two-million-cell label
buffer, prepares the country's rectangular mask, floods its exterior, and
then scans the rectangle again in `World.fillEnclosures` to find captures.
Those broad passes scale with bounding area even when few pixels change.

A separate diagnostic preload wrapped the existing methods, counted fallback
areas and recomputed exact country bounds every 1,200 ticks. It did not alter
ownership or decisions. Its timings include instrumentation and are excluded
from the timing baseline above.

| Diagnostic interval | Fallback calls | Median fallback rectangle | Sum of fallback rectangle areas | Largest rectangle |
| --- | ---: | ---: | ---: | ---: |
| First simulated minute | 884 | 139,000 cells | 202,570,142 cells | 1,341,424 cells |
| Tenth simulated minute | 1,613 | 501,860 cells | 909,803,041 cells | 1,668,312 cells |

Across ten minutes, 9,966 fallback calls accumulated 3.943 billion cells of
rectangle area. This counts each fallback rectangle once; it is not a count
of all reads, writes or flood visits. The tenth minute processes 4.49 times
the rectangle area of the first minute.

Exact bounds matched stored bounds at every snapshot through minute seven.
At minute ten, tightening would reduce summed active-country rectangle area
by only 0.1425%. These snapshots are not weighted by fallback frequency, but
they do not support the earlier suggestion that stale bounds are the first
optimization to pursue for this workload.

The native label-buffer `fill` accounts for only 1.5% of samples in the long
run. Removing that clear alone has limited potential. A useful next A/B
experiment is to avoid the explicit rectangular owner-mask preparation pass
by testing ownership during the flood and using reusable visit markers.
Extra ownership checks may offset the saved pass, so this is a hypothesis to
benchmark, not an established faster algorithm. Phase timing inside the
fallback should accompany that experiment; this sampling profile does not
reliably separate its inner loops. Preserve enclosure tests and final
checksums when evaluating it. Compact bot workloads still need their own
comparison because bot scoring is their largest cost.

The long unsampled, sampled and diagnostic runs all end with checksum
`d201cfc3153b9fea3f869293f05ccaacb72ef9b344ab8b95ff6ee3dc482ec81b`.

### Real database control

One separate fragmented-bot run used 20 countries, 40 movers and 1,200 ticks,
paced at 20 Hz, against the local ZyncBase server with committed SDK batches.
It completed in 60.15 seconds with 1,179 commits, 25,251 chunk writes and
53,964,488 chunk payload bytes. Commit-phase latency was 2.35 ms median,
4.95 ms p95 and 9.88 ms p99. Whole-update p99 was 21.84 ms, maximum 33.12 ms,
and no update exceeded 50 ms. Bun used 5.37 CPU seconds, averaging 0.089 CPU
cores over the run. The final checksum matches the local fragmented-bot run.

This control does not saturate ZyncBase or measure its maximum throughput.
The fixtures use synthetic land and omit browser subscribers, presence input
traffic, TLS and subscriber fan-out. They identify a local simulation
bottleneck without establishing the cause of sustained load on a deployed VM.

### Reproduce this capture

Use the commands in the earlier reproduction section for the three short
workloads, repeating into `fresh-20260909/repeat-{1,2,3}`. Run each workload
separately with `--profile` into `fresh-20260909/sampled`. Additional runs:

```sh
bun run --filter @zyncbase/client build
bun examples/pixel-conquest/profile.ts --mode bots --shape fragmented --publish --output test-artifacts/pixel-conquest-profile/fresh-20260909/published
bun examples/pixel-conquest/profile.ts --mode bots --shape fragmented --ticks 12000 --output test-artifacts/pixel-conquest-profile/fresh-20260909/long
bun examples/pixel-conquest/profile.ts --mode bots --shape fragmented --ticks 12000 --profile --output test-artifacts/pixel-conquest-profile/fresh-20260909/long
bun --preload ./examples/pixel-conquest/diagnostics.preload.ts examples/pixel-conquest/profile.ts --mode bots --shape fragmented --ticks 12000 --output test-artifacts/pixel-conquest-profile/fresh-20260909/long/diagnostic
```

The diagnostic preload is a tracked source file; earlier captures referenced a
local-only copy under `test-artifacts/`, which is gitignored and absent on a
clean checkout.

All 16 successful harness runs passed the existing ownership, country-count
and player-position assertions. The diagnostic preload additionally checked
that stored bounds enclosed the exact bounds at every snapshot.
All 16 result checksums were also checked against their expected workload
checksum. `bun run lint`, `bunx biome check --write --error-on-warnings` and
`git diff --check` passed; Biome applied no fixes.

## Iteration: 2026-09-10, straight-exit checks for local candidates

Baseline: `ebe25e528df5baf0dca88657d9f178d55cc3c882`. Same Intel Core
i9-9880H, macOS x64 and Bun 1.4.0. This iteration changes only the game's
local enclosure search; the ZyncBase server, SDK, bot decisions, capture
order and scanline filler are unchanged.

### Fresh profile and selected change

A fresh, separate 1,200-tick fragmented-bot sample recorded 1,568 stacks:
52.9% included enclosure processing, 37.8% included the filler, 35.7%
included bot planning and 8.9% included chunk preparation. The filler share
is included in enclosure processing. These are sampled Bun stacks, not
ZyncBase CPU measurements.

`claim()` already uses `hasStraightExit()` to skip defensive searches for
exposed losses. Gains and bulk captures can also queue exterior pixels,
but those candidates previously entered the breadth-first flood directly.
A large open component could exhaust 1,024 discovered cells before reaching
its boundary and request an expensive full-country scan.

`localEnclosures()` now applies that same exact straight-exit proof before
flooding each unresolved candidate. A successful proof caches the start as
exterior; a blocked or curved route still uses the existing bounded flood
and fallback. The 1,024-cell flood and candidate-storage limits remain;
ray reads are additional, bounded by country dimensions per candidate.
This preserves capture order and avoids changing the flood-fill kernel.

### Paired timing results

Three sequential repeats per variant and workload, with the pair order
alternated as described below. Sampling and diagnostic instrumentation were
disabled. Values are medians across runs, including the median of per-run
p99 values. Simulation excludes chunk preparation and database waiting;
whole-update p99 includes chunk preparation.

| Workload | Ticks | Baseline simulation | Candidate simulation | Change | Whole-update p99, baseline / candidate |
| --- | ---: | ---: | ---: | ---: | ---: |
| Fragmented bots | 1,200 | 1,671 ms | 998 ms | −40.3% | 13.73 / 13.28 ms |
| Compact bots | 1,200 | 1,098 ms | 759 ms | −30.9% | 16.43 / 13.65 ms |
| Fragmented scripted | 1,200 | 4,321 ms | 3,058 ms | −29.2% | 26.79 / 24.32 ms |
| Fragmented bots, ten simulated minutes | 12,000 | 24,119 ms | 15,692 ms | −34.9% | 11.61 / 9.75 ms |

Simulation ranges were 1,656–1,778 vs 994–1,002 ms for fragmented bots;
1,011–1,676 vs 730–791 ms for compact bots; 4,273–4,689 vs 3,005–3,325 ms
for scripted movement; and 23,951–24,862 vs 15,616–16,165 ms for the long
run. The first compact baseline was an outlier with five updates over 50 ms;
the other two had none. All other baseline runs and every candidate run had
zero over-budget updates. The outlier is retained in the range and median;
these measurements do not isolate its cause.

Chunk-preparation medians were 193 / 176 ms, 188 / 179 ms, 196 / 178 ms and
2,038 / 1,929 ms in table order. The long run's median elapsed time fell
from 26.04 to 17.56 seconds, and measured Bun CPU time from 28.40 to 19.45
seconds. These are unpaced local runs, not a database throughput result.

Every pair matched initial and final checksums, chunk-write counts and
payload byte counts. All 24 runs passed the harness's ownership, country
count and player-position assertions. Final checksums match the previously
recorded candidate values for all three short workloads and `d201cfc3…82ec81b`
for the ten-minute workload. This iteration preserves the same trajectories
in the measured fixtures.

### Why the gain holds

Separate diagnostic runs used the existing preload on both variants. These
counts exclude disposable warmup and restoration; their instrumented timings
are excluded from the comparison above.

| Interval | Fallback calls, baseline / candidate | Summed rectangle area, baseline / candidate |
| --- | ---: | ---: |
| First simulated minute | 884 / 292 | 202,570,142 / 59,784,480 cells |
| Tenth simulated minute | 1,613 / 1,280 | 909,803,041 / 657,001,802 cells |
| All ten minutes | 9,966 / 5,547 | 3,942,801,033 / 2,074,372,971 cells |

That is **44.3% fewer fallback calls and 47.4% less fallback rectangle area**
over ten minutes. Area counts each fallback rectangle once, not every memory
access or flood visit. Both diagnostic runs retained the long checksum and
passed the stored-bounds assertions at every snapshot.

A separate candidate sample recorded 965 stacks: enclosure processing fell
to 25.1% of samples, including 17.0% in the filler; bot planning accounted
for 56.3% and chunk preparation for 16.0%. This short workload now spends
more sampled time in bot planning. Larger territories still incur full
fallback scans; the tenth minute alone accounts for 657 million cells of
rectangle area even with the new proof.

### Rejected experiments

- Testing ownership during the scanline flood, with native rectangle clears
  instead of an explicit owner-mask loop, passed the exhaustive tests and
  checksums but regressed the initial fragmented-bot trial from 1,684 to
  2,062 ms and scripted movement from 4,333 to 6,167 ms. These are single
  exploratory runs, not a general result about every direct-ownership design.
- Depth-first local traversal improved the short workloads, but the three
  ten-minute comparisons regressed from 21.38–24.21 seconds to 32.10–36.21
  seconds of simulation. Checksums matched. The final change retains
  breadth-first traversal; long-session verification prevented selecting a
  short-workload improvement that would hurt the demo later.

### Reproduction

Use the unchanged [profile.ts](./profile.ts) harness with 20 countries,
40 movers and 200 disposable warmup ticks. For each of three repeats, run
fragmented bots, compact bots, fragmented scripted movement (1,200 ticks
each), then fragmented bots for 12,000 ticks. Pair baseline and candidate
within each workload; use baseline first on repeats 1 and 3, candidate first
on repeat 2. Run builds, tests and sampling outside these timing intervals.
Use a separate checkout at the baseline commit for the baseline commands.

```sh
bun examples/pixel-conquest/profile.ts --mode bots --shape fragmented --output test-artifacts/pixel-conquest-profile/iteration-20260910/repeat-1
bun examples/pixel-conquest/profile.ts --mode bots --shape compact --output test-artifacts/pixel-conquest-profile/iteration-20260910/repeat-1
bun examples/pixel-conquest/profile.ts --mode scripted --shape fragmented --output test-artifacts/pixel-conquest-profile/iteration-20260910/repeat-1
bun examples/pixel-conquest/profile.ts --mode bots --shape fragmented --ticks 12000 --output test-artifacts/pixel-conquest-profile/iteration-20260910/long-1
bun examples/pixel-conquest/profile.ts --mode bots --shape fragmented --profile --output test-artifacts/pixel-conquest-profile/iteration-20260910/sampled
bun --preload ./examples/pixel-conquest/diagnostics.preload.ts examples/pixel-conquest/profile.ts --mode bots --shape fragmented --ticks 12000 --output test-artifacts/pixel-conquest-profile/iteration-20260910/diagnostic
bun examples/pixel-conquest/profile.ts --mode bots --shape fragmented --publish --output test-artifacts/pixel-conquest-profile/iteration-20260910/published
```

Local raw results and the source snapshot are in
[`iteration-20260910`](../../test-artifacts/pixel-conquest-profile/iteration-20260910/).
`final-{baseline,candidate}-{1,2,3}-{1200,12000}` contains the selected
comparison; `comparison-*` contains the rejected depth-first experiment.
The baseline snapshot changes only imports for running alongside the
candidate. Generated artifacts are gitignored; the reproduction above uses
tracked files available on a clean checkout.
