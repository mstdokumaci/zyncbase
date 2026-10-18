# Cordon Off profiling

**Current state (2026-10-18):** Bun 1.4.0, Linux x86_64, AMD Ryzen 5 3600. Last profiling session: 2026-10-17 at `4c50d7d`; current HEAD `1c9ba73` contains no Cordon Off changes after that. Use the actual commit under test as the next baseline; record it when the session starts.

**Initial comparison:** measured 2026-09-09 with Bun 1.4.0 on macOS x64, Intel Core i9-9880H; baseline `9f6c5982240aa73c0960d056453db3f25ee95227`. That commit predates the `examples/pixel-conquest` → `examples/cordon-off` rename. Its table below is historical context, not a reusable baseline.

## Fresh-session protocol

### Preflight

- Confirm a clean tree and record the exact commit: `git rev-parse HEAD`, `git status --short`.
- Record `bun --version`, `uname -sm`, and the CPU model.
- Install workspace dependencies with `bun install`. Run `bun test examples/cordon-off`, `bun run typecheck:examples`, and `bun run lint` before measuring.
- Close other workloads, builds, and tests. Use the same machine, Bun version, and power profile for baseline and candidate; never run them concurrently.
- For A/B, create a baseline worktree with `git worktree add ../zyncbase-baseline <sha>` and run `bun install` there. The harness and fixture must be identical on both sides; only the code under test should differ.

### Timing runs

Use three repeats per workload, alternating baseline then candidate, with a fixed workload order. Do **not** pass `--profile`, `--trace`, or `--publish` (unless measuring publish separately). One output directory per repeat; result filenames include the country count, shape, mode, and `local`/`database`.

```sh
for r in 1 2 3; do
  bun examples/cordon-off/profile.ts --mode scripted --shape fragmented --output "test-artifacts/cordon-off-profile/repeat-$r"
  bun examples/cordon-off/profile.ts --mode bots --shape fragmented --output "test-artifacts/cordon-off-profile/repeat-$r"
  bun examples/cordon-off/profile.ts --mode bots --shape compact --output "test-artifacts/cordon-off-profile/repeat-$r"
done
```

Report medians **and ranges** across repeats. Do not claim a win when the ranges overlap; treat small differences as noise. Timing runs use 20 countries, 40 movers, 200 warmup ticks, and 1,200 measured ticks (60 s simulated at 50 ms/tick) unless stated otherwise.

### Sampling runs

Run sampling separately from timing. The JSC profiler adds overhead, so timings from a `--profile` run are not comparable to timing runs; do not combine `--profile` with `--trace`.

```sh
bun examples/cordon-off/profile.ts --mode bots --shape fragmented --profile --ticks 12000 --output test-artifacts/cordon-off-profile/sample-fragmented-bots
bun examples/cordon-off/profile.ts --mode bots --shape compact --profile --ticks 12000 --output test-artifacts/cordon-off-profile/sample-compact-bots
bun examples/cordon-off/profile.ts --mode scripted --shape fragmented --profile --ticks 12000 --output test-artifacts/cordon-off-profile/sample-scripted-fragmented
```

Use 1,200 ticks for a quick profile and 12,000 ticks to catch long-run drift in bounds or fallback area. `--profile` writes `<label>.profile.json` next to the timing result; `functions` and `bytecodes` are formatted text, and `stackTraces` is an array of raw stack strings. Samples are stack-inclusive (callees count toward the caller), `#<nil>` frames are common, and JIT inlining limits line-level attribution. `--profile` samples the harness process only; use `profile-browser.ts --server-profile` for the separate ZyncBase server.

### Spike diagnostics

Use `--trace` on one run when a workload has large updates:

```sh
bun examples/cordon-off/profile.ts --mode scripted --shape fragmented --trace --output test-artifacts/cordon-off-profile/trace-scripted
```

Inspect `spikes.topTotal`, `spikes.topSim`, and `spikes.topCommit` in the result JSON. Repeated tick indices across runs usually mean deterministic events; one-off spikes are usually GC or scheduler noise. Do not use trace runs in the final timing table.

### Publishing (optional)

`--publish` starts an isolated real server and database and is not comparable to local simulation. It runs at 20 Hz by default; `--unpaced` removes that pacing and lifts the server's 100 msg/s guard. No browser subscribers, presence traffic, TLS, or fan-out are simulated. It requires the native build prerequisites; the harness builds the server if needed.

### Session record

Record the date, commit under test, baseline commit, Bun version, OS/arch/CPU, commands, artifact directories, per-workload medians/ranges, checksums, and profile targets. Add one changelog line when the session completes.

## Latest results

The next session should fill this from three local timing repeats at the current baseline. The historical numbers below are not a substitute.

| Workload | Simulation total (median, range) | Simulation p99 | Serialization total | Whole-update p99 | Updates >50 ms | Final checksum |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Fragmented / scripted | TBD | TBD | TBD | TBD | TBD | TBD |
| Fragmented / bots | TBD | TBD | TBD | TBD | TBD | TBD |
| Compact / bots | TBD | TBD | TBD | TBD | TBD | TBD |

## Selected algorithm

1. All movers paint before enclosure resolution. Countries are processed in first territory-change order, at most once per tick, including countries affected by captures.
2. A gain can only enclose what sits beside it, and only while that pixel was the last way out, so the gate is the same `hasStraightExit` proof (straight rays, then diagonals) run after the claim: a neighbour it can still prove open is not at risk. A ring with no country pixel at all is skipped outright, because the open ring is itself eight-connected and dropping one cell from it severs nothing. A lost pixel with a straight or diagonal route to the country's conservative bounding-box edge needs no defensive reclaim. Failed proofs request a search; they do not assume an enclosure exists.
3. Before any ray walk, the gate counts the open runs around the claimed pixel. The ring is walked in cyclic order, so consecutive entries are eight-adjacent and a single open run means every open neighbour is still joined around the new wall: nothing beside that pixel can be severed, and the proof is skipped. An incomplete ring at the array edge is never counted this way, because its run boundary may sit off the array; it falls through to the proof. The deterministic nine-nation, 6,000-tick fixture in `enclosure.perf.test.ts` pins the selected gate at 570 whole-country fallback fills; the test also records that a gate that skips the ray walks lands near 2,949.
4. Each candidate first gets the same bounds-limited `hasStraightExit` proof. Unresolved components share a **16,384-cell flood budget per country per tick**. The flood is a depth-first dive ordered toward the nearest bound, so an exterior-connected component is proven open in about the length of its shortest route instead of the area it covers; flat stamp maps make each visited cell one typed-array write. Proven exterior cells are reused between candidates. No pixels are painted unless every candidate is resolved. Candidate storage shares the same cap; exceeding the storage or flood limit requests one fallback scan. Ray reads are separate from the flood budget and bounded by the country's width and height per candidate.
5. The fallback is a run-length eight-connected flood over the country's bounds. Every open pixel in a row is one run, two runs in adjacent rows touch when their spans overlap by a pixel or more, and a hole is a run no perimeter run reaches, so a bbox costs one read per pixel and then work proportional to the run count. The run builder and capture checks use incrementally maintained bounds, including disconnected territory. Nothing outside those bounds is read; runs touching the bounds perimeter seed the flood as exterior.
6. A fill takes its whole region in one bulk capture instead of calling `claim` per pixel: the owner write stays in the loop and the roster counters, capture credit, dirty sets, bounds and chunk index move out of it. Chunk index and bounds come from the ascending cell order, so no division runs per pixel. Bulk captures enqueue defensive candidates in constant time per pixel, avoiding long straight-ray checks for every captured pixel. Restore performs a full reconciliation for each populated country.

The local flood is bounded; each fallback is linear in the country's bounds and runs at most once per country per tick. Overall work still depends on how many countries change, movement checks, and captured area. Bounds only grow and can become loose after losses. This caps repeated searches, not wall-clock latency on arbitrary hardware.

Compared with the original baseline, capture timing is deliberately end-of-tick: a closure breached by a later mover in the same tick remains open. Captures within the resolution pass are applied in country order, not simultaneously. Water stays unowned and remains traversable background for enclosure connectivity.

## Historical comparison (2026-09-09)

The table compares the initial baseline `9f6c598` with the then-current candidate; the candidate commit is not recorded, so this is historical context, not a reusable baseline. Three sequential repeats per variant and workload, alternating baseline then candidate, without a sampling profiler or concurrent builds/tests. Every run used 20 countries, 40 movers, 200 warmup ticks, and 1,200 measured ticks. Values are medians as reported by the original comparison; the table does not record whether its p99 column is simulation-only or whole-update. Over-budget counts use total update time above 50 ms and were identical across repeats.

| Layout / movement | Baseline simulation | Candidate simulation | Change | Baseline / candidate p99 | Updates >50 ms, baseline / candidate |
| --- | ---: | ---: | ---: | ---: | ---: |
| Fragmented / scripted | 9,390 ms | 5,997 ms | −36.1% | 69.22 / 36.19 ms | 143 / 0 |
| Fragmented / bots | 2,998 ms | 2,212 ms | −26.2% | 29.82 / 16.55 ms | 2 / 0 |
| Compact / bots | 1,057 ms | 1,263 ms | +19.4% | 15.79 / 16.21 ms | 0 / 0 |

**Outcome equivalence:** baseline and candidate final checksums match for fragmented scripted movement and compact bots. Fragmented bots follow a different trajectory under end-of-tick capture timing, so their reduction is an end-to-end observation, not a comparison of identical calculations. All repeats within each variant produced the same checksum. Per-run ranges, final checksums, and the original reproduction notes are in this file's git history.

## Workload and reproduction

[profile.ts](./profile.ts) uses the real `World.tick` on synthetic all-land terrain in the 2000 × 1000 world. Each country starts with 26,112 home pixels. Compact countries are filled rectangles; fragmented countries are open U shapes, and each has a rival-owned, disconnected 5 × 5 outpost in its bay, for 522,740 initially owned pixels in total. The fixture is not a real coastline or a saved production map; water and coastline paths are not exercised.

Scripted movers follow deterministic box routes; `steer()` runs before the measured interval, so scripted steering cost is excluded. Bot mode uses actual steering, route planning, movement, and captures inside `World.tick`; the fixture's population policy allows 40 bots without a human. Warmup uses a disposable world, then the measured world is recreated. Setup, restoration, initial database writes, explicit pre-run GC, checksums, and invariants are outside the measured interval. Local runs do not sleep; 1,200 ticks represent 60 seconds of game time.

Run from the repository root with installed workspace dependencies:

```sh
bun examples/cordon-off/profile.ts --mode scripted --shape fragmented --output test-artifacts/cordon-off-profile/repeat-1
bun examples/cordon-off/profile.ts --mode bots --shape fragmented --output test-artifacts/cordon-off-profile/repeat-1
bun examples/cordon-off/profile.ts --mode bots --shape compact --output test-artifacts/cordon-off-profile/repeat-1
```

`--ticks`, `--warmup`, `--countries`, `--output`, `--publish`, `--unpaced`, `--trace`, and `--profile` control run length, fixture size, artifact placement, database writes, pacing, spike tracing, and sampling. `--countries` is capped at 20, so the standard run has 40 movers. `--unpaced` only changes behavior with `--publish`. The result JSON records options, machine, initial/final checksums, per-phase summaries, over-budget count, chunk write counts and bytes, flush count, and optional spikes.

Artifact names:

- `<countries>-<shape>-<mode>-local.json`: timing result without profiling.
- `<countries>-<shape>-<mode>-local-profile.json`: timing result from a profiled run; do not compare its timings.
- `<countries>-<shape>-<mode>-local-profile.profile.json`: JSC sampling profile.
- `<countries>-<shape>-<mode>-database.json`: database/publish result.

Artifacts under `test-artifacts/` are generated and gitignored; record summary numbers and hashes in this file because artifacts may not survive.

## Reading results

- `simulation`: `World.tick` only. Scripted steering is excluded; bot steering and planning are included.
- `serialization`: `changes(world)` (dirty rows and chunk encoding), even in local runs where the batch is discarded.
- `commit`: database commit wait; zero in local runs.
- `total`: simulation + serialization + commit.
- `ticksOverBudget`: number of `total` samples above 50 ms, not simulation alone.
- `flushes`: committed batches (database runs only).
- `countryChunkWrites`/`Bytes`, `userChunkWrites`/`Bytes`: serialized payload volume before subscribers.
- `spikes`: top-ten `total`, `sim`, and `commit` ticks when `--trace` is used.

Checksums cover ownership plus player state; they are not a full persisted-database reload or a cross-version guarantee. Fragmented bot trajectories can diverge when capture timing changes; treat that as an end-to-end observation, not an identical-calculation comparison. JSC profile shares include callees and are not percentages of total Bun process CPU or allocation volume; JIT inlining limits exact attribution.

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
- **2026-10-13** — Country chunk encoding fuses palette mapping and RLE into one pass over reused scratch (drops the 4 KiB code array, the 8 KiB encode buffer, and the second pass): local serialization −22.2% scripted fragmented, −13.2% bots fragmented, −14.7% bots compact; publish serialization −11.8% unpaced; checksums match. Unpaced publish no longer stalls on the 100 msg/s guard (522 ticks/s, commit p50 1.4 ms). Baseline `c1c3c1a`.
- **2026-10-13** — Peer farm runs the browser's shared data plane (`viewport.ts`: decoded chunk caches, LocalMotion, eased camera, heading-prefetch/seam subscriptions, change-only moves) plus a fast RLE decode path. At 1,024: subscriptions 47,848 → 31,850 (−33%), commit p50 111 → 95 ms, action traffic −87%, heartbeat p95 64–73 → 26 ms, and stable ramps (without the decode fix peers drop: 33 errors, hb p95 111 ms). Baseline `dc49520`.
- **2026-10-14** — Enclosure dive keeps visited and exterior-proven cells in one marks array (positive/negative stamp) and sorts hole output with the native typed-array sort instead of a comparator copy. Interleaved paced A/B on scripted fragmented: worst tick 32 → 24 ms, simulation total 436–440 → 391–412 ms, p95 1.2–1.3 → 1.2 ms; local worst tick 32 → 22 ms. Bots workloads unchanged; checksums match. Baseline `de992b0` is no longer reachable in the current history; the corresponding current-history change is `1370d7a` (parent `755305c`).
- **2026-10-16** — Fresh profile identified enclosure dive neighbor indirection, bot candidate evaluation array allocations, and chunk serialization as remaining bottlenecks. Precomputed quadrant offsets and midpoint quadrant calculation in enclosure dive, allocation-free rival/reservation searches and hoisted coordinate math in bot planning, in-loop RLE run tracking in encodeChunk, direct iteration in userChunk, and cached chunk row IDs: simulation −20.4% scripted fragmented, −12.1% bots fragmented, −12.5% bots compact; serialization −14.1% to −17.6%; p99 latency −15.9% to −24.4%; max tick latency −12.3% to −13.8%; checksums match. Baseline `5424c21`.
- **2026-10-17** — Fresh profile identified bot patch reservation Set allocations and lookups, dead areaScratch population during gain checks, in-loop step direction branching in scoreCells, unhoisted owners property loads in encodeChunk, and chunk coordinate math as bottlenecks: simulation −38.2% compact bots, −19.6% fragmented bots, −2.3% scripted fragmented; serialization −14.1% compact bots; p99 latency −51.6% compact bots (1.24 → 0.60 ms), −29.5% fragmented bots (1.05 → 0.74 ms); all checksums match deterministically. Baseline `e6b4196`.
