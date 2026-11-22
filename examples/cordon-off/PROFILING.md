# Cordon Off profiling

**Current state (2026-11-22):** Bun 1.4.4, macOS x86_64, Intel i9-9880H. Baseline `4ca71ba`. The 2026-10-18 baseline `cd67280` is not reachable in this history and the machine changed, so the older tables are qualitative only. Record the actual commit at session start.

## Current state

### Local simulation

3 repeats, 20 countries/40 movers, 200 warmup and 1,200 measured ticks; medians (min–max) in ms. `--chunk-interval 1` is the stress case; 3 matches the shipped country-chunk cadence.

| Workload | Cadence | Simulation | Simulation p99 | Serialization | Whole-update p99 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Fragmented / scripted | 1 | 189.2 (184.8–191.1) | 2.99 | 68.5 (68.2–69.4) | 3.12 |
| Fragmented / bots | 1 | 133.0 (130.2–153.2) | 0.42 | 104.6 (100.6–118.4) | 0.50 |
| Compact / bots | 1 | 127.0 (126.4–133.8) | 0.44 | 103.8 (100.9–109.8) | 0.54 |
| Fragmented / scripted | 3 | 185.5 (182.1–190.9) | 2.93 | 57.7 (56.8–58.3) | 2.98 |
| Fragmented / bots | 3 | 132.0 (128.5–139.6) | 0.40 | 77.4 (74.8–82.4) | 0.52 |
| Compact / bots | 3 | 125.1 (120.4–125.3) | 0.42 | 72.1 (71.1–72.8) | 0.49 |

Long run (12,000 ticks, interval 3, medians of 3): fragmented scripted 257/262/520 ms simulation/serialization/total; fragmented bots 1,310/891/2,203 (one 1,715 ms simulation outlier); compact bots 1,157/834/1,985. Early ticks cost several times the long-run average per tick because the map is still churning; keep both.

### Publish/database

2026-10-18 Linux baseline, not re-measured on the current machine. `--publish --unpaced --chunk-interval 3`, 1,200 ticks, 3 repeats.

| Workload | Commit p50 / p99 | Total | Country chunk writes / bytes |
| --- | ---: | ---: | ---: |
| Fragmented / scripted | 1.36 / 4.21 ms | 1,901.7 ms | 11,492 / 1.03 MB |
| Fragmented / bots | 1.42 / 5.41 ms | 2,185.3 ms | 12,325 / 1.61 MB |
| Compact / bots | 1.30 / 4.55 ms | 2,034.6 ms | 11,701 / 1.46 MB |

Commit dominates unpaced publish work, but the 20 Hz paced control used only 2.85 s of measured work over 60 s and had no over-budget ticks. The DB path has headroom.

### Browser and peers

**2026-11-22, macOS i9-9880H:** separate ramps; 15 s stages for 256/512, 30 s for 1,024. The 1,024 stage is farm-bound here (7.8 cores, 18 errors, two peers dropped), so its ack/row values measure the farm, not the server.

| Players | Ack p95 | Own-row p50 / p95 | Farm CPU | Farm rx | ZyncBase CPU | Game server CPU |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 256 | 75.2 ms | 50.0 / 98.7 ms | 1.38 cores | 15.1 MB/s | 0.34 cores | 0.07 cores |
| 512 | 107.6 ms | 50.0 / 113.0 ms | 4.53 cores | 45.7 MB/s | 0.71 cores | 0.09 cores |
| 1,024 | 766 ms* | 144 / 451 ms* | 7.82 cores | 91.3 MB/s | 0.85 cores | 0.12 cores |

Native `sample` of the ZyncBase process during the 512 stage (10 s, 7,086 main-thread samples): 3,441 in `kevent` (idle), ~2,814 under `notifyPostHandler` → `sendOrClose`, and **2,167 in `__sendto`**; every SQLite function is in single digits. Fan-out delivery, not SQLite, is the server's dominant main-thread cost. At 1,024 the client-side commit tail is p95 216 ms / p99 397 ms with 358-op bursts (ops p95 358, p50 3); publishes run on about 55% of ticks for the whole ramp versus 69% at 512, and the tick interval p95 slips to 63.8 ms. A stalled commit accumulates dirty chunks, so the next batch is larger and slower — a positive feedback loop.

The 2026-10-18 Linux baseline, for reference only:

`profile-browser.ts`, 30 s stages; observer Chromium plus SDK peer workers.

| Players | Ack p95 | Own-row p95 | Farm CPU | Farm rx | Late deltas |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 512 | 17.1 ms | 72.7 ms | 3.91 cores | 53.4 MiB/s | 1,478 |
| 1,024 | 140.5 ms | 185.9 ms | 9.61 cores | 130.8 MiB/s | 21,122 |

At 1,024 the observer held 30 fps with 4.2 ms draw p95; the Bun game server used about 0.1 cores and its database child about 0.7. The peer farm is the limiter, not the server.

### Attribution

Phase split of 12,000-tick CPU profiles at the shipped cadence, ms per run (one run each; sampled time is within ±3.5% of the harness's phase totals):

| Phase | Fragmented / scripted | Fragmented / bots | Compact / bots |
| --- | ---: | ---: | ---: |
| `World.tick` | 279 | 1,397 | 1,276 |
| `changes` | 273 | 915 | 1,011 |
| fixture + verify + other | 485 | 538 | 484 |

Sampled phase time matches the harness wall clock within 3.5% (99.3–103.5% coverage across six profiles), so the split explains essentially all measured CPU; the flat native/spread cost in a whole-process profile is fixture and verification, not the tick loop. GC is not material: `--smol` changes the 12,000-tick total by +0.3% to +2.9%, inside run noise.

Self time within the phases (interval 3, 12k ticks):

- **Simulation, bots fragmented:** `scoreCells` 394 ms (27% of tick), `floodComponent` 355 (25%), `planBot` 227 (16%), `rayHitsEnemy` 87, `hasStraightExit` 51, `isAllLand` 40. Compact: `scoreCells` 403 (32%), `planBot` 252 (20%), `floodComponent` 182 (14%).
- **Simulation, scripted fragmented:** `floodComponent` 184 ms (66% of tick), `move` 39 (14%), `captureEnclosure` 10.
- **Serialization, bots:** `countryChunk` 633 ms (69% of serialization) / 727 (72%), `encodeCoordinates` 98 / 98, `encodeChunk` 64 / 69.
- **Serialization, scripted:** `countryChunk` 103 ms (38%), `encodeCoordinates` 62 (23%), `userChunk` 29 (11%), `encodeChunk` 21.
- Fixture, verification, and checksums add about 0.5 s per 12,000-tick run, outside the measured phases.

### Hotspots and next targets

- **Serialization:** `countryChunk` is 69–78% of bot serialization at the shipped cadence and 38% on scripted; user-chunk coordinate encoding is 10–23%. The chunk encoder costs about 5 µs per 4,096-cell row. Pooling slices is ~3%; the order-of-magnitude option is an incremental per-row RLE cache or a compact paint protocol, both state/wire changes.
- **Bot planning:** about 55% of bot simulation (`scoreCells` 27–32% of tick, `planBot` 16–20%, `rayHitsEnemy` 6–8%, `isAllLand` 3–4%). Needs a cheaper per-cell score or fewer scored candidates.
- **Enclosure:** local flood is 25% of fragmented-bot simulation and 66% of scripted — far above the old 8–14% self-sample share, which included serialization and setup. Bounds grow loose; next measurement is per-flood attribution (calls, visited cells, exhausted budget, bounds area), then bounds tightening.
- **Fan-out delivery:** at 512, about two-thirds of the ZyncBase main thread's busy time is WebSocket sends (`notifyPostHandler` → `sendOrClose` → `__sendto`); SQLite functions are single-digit samples. At 1,024 the write-ack tail (p95 216 ms, 358-op bursts) stalls publishes and the backlog snowballs into larger, slower batches. Coalescing drains per transaction was rejected (no CPU win, worse ack). Next: split in-flight publish time into drain/encode and batch await, then measure fan-out volume per subscription (roster versus country/user chunks) before cutting it. The 1,024 client numbers are farm-bound on this machine.
- **Browser/peers:** the 1,024 stage is farm-CPU-bound; reduce subscription churn/per-peer dispatch or use a lighter farm for server-capacity tests. Watch predicted-paint corrections.
- Tick 0 is a cold-fixture/GC spike; exclude it from max/p99 interpretation.

## Running a session

### Preflight

- Start from a clean tree and record `git rev-parse HEAD`, `git status --short`, `bun --version`, `uname -sm`, and the CPU model.
- Run `bun install`, `bun test examples/cordon-off`, and `bun run typecheck:examples`; run `bun run lint` when the project tooling is installed.
- Close other builds/workloads. Use the same machine, Bun version, and power profile for baseline and candidate; never run them concurrently.
- For A/B, create a baseline worktree with `git worktree add ../zyncbase-baseline <sha>` and run `bun install` there. Keep the harness and fixture identical on both sides.

### Local simulation

Three repeats per workload, alternating baseline then candidate, fixed workload order. Do not use `--profile`, `--trace`, or `--publish` for timing runs.

```sh
repo=$(pwd)
for r in 1 2 3; do
  for tree in baseline candidate; do
    if [ "$tree" = baseline ]; then
      root="$repo/../zyncbase-baseline"
    else
      root="$repo"
    fi
    (cd "$root" && bun examples/cordon-off/profile.ts --mode scripted --shape fragmented --output "$repo/test-artifacts/cordon-off-profile/$tree-repeat-$r")
    (cd "$root" && bun examples/cordon-off/profile.ts --mode bots --shape fragmented --output "$repo/test-artifacts/cordon-off-profile/$tree-repeat-$r")
    (cd "$root" && bun examples/cordon-off/profile.ts --mode bots --shape compact --output "$repo/test-artifacts/cordon-off-profile/$tree-repeat-$r")
  done
done
```

Report medians and ranges; do not claim a win when ranges overlap. Use `--ticks 12000` for a long-run check. Add `--chunk-interval 3` for the shipped cadence; report both cadences when a change touches serialization.

### Sampling and spikes

Run sampling separately; profiler timings are not comparable.

```sh
bun examples/cordon-off/profile.ts --mode bots --shape fragmented --profile --ticks 12000 --output test-artifacts/cordon-off-profile/sample-fragmented-bots
bun examples/cordon-off/profile.ts --mode bots --shape compact --profile --ticks 12000 --output test-artifacts/cordon-off-profile/sample-compact-bots
bun examples/cordon-off/profile.ts --mode scripted --shape fragmented --profile --ticks 12000 --output test-artifacts/cordon-off-profile/sample-scripted-fragmented
```

`functions`/`bytecodes` are formatted text; `stackTraces` contains `{ interval, traces }` with leaf-first frames. Counts are self samples; `#<nil>` and JIT inlining limit attribution. Use `--trace` on one run for spike indices (`spikes.topTotal`/`topSim`/`topCommit`), not for timing.

### Attribution

`--profile` reports JSC self samples and cannot split phases or resolve native frames. For work attribution, run Bun's CPU profiler and phase-split the result:

```sh
bun --cpu-prof --cpu-prof-interval=250 --cpu-prof-dir test-artifacts/cordon-off-profile/attrib \
  --cpu-prof-name p.cpuprofile examples/cordon-off/profile.ts --mode bots --shape fragmented \
  --ticks 12000 --chunk-interval 3 --output test-artifacts/cordon-off-profile/attrib/out
bun examples/cordon-off/profile-attribute.ts test-artifacts/cordon-off-profile/attrib/p.cpuprofile \
  --json test-artifacts/cordon-off-profile/attrib/attribution.json
```

The report buckets samples by the harness frame (`World.tick`, `changes`, `steer`, fixture, verify) and prints self and inclusive time, plus the harness's reported phase totals for a coverage check. `--cpu-prof` profiles the main thread only; worker threads and the database process need counters or `ps`. Allocation and collector time stay attributed to the allocating function, so use a `--smol` A/B to bound GC.

### Publish/database

```sh
bun examples/cordon-off/profile.ts --publish --unpaced --chunk-interval 3 --mode bots --shape fragmented --ticks 1200
```

`--publish` starts an isolated real server/database, builds it if needed, and is not comparable to local simulation. Omit `--unpaced` for the 20 Hz cadence. No browser subscribers, presence traffic, TLS, or fan-out are simulated.

### Browser and peers

```sh
bun examples/cordon-off/profile-browser.ts --players 512,1024 --seconds 30 --countries 32 --port 19183 --output test-artifacts/cordon-off-profile/browser-run
```

This starts the real server, an observer Chromium page, and SDK peer workers. Use a direct interval-1 versus interval-3 A/B for coalescing changes. `--profile` records the observer page; `--server-profile` records the game server. The 1,024 stage measures the peer farm when it nears CPU saturation.

### Reading results

- `simulation` is `World.tick` only; scripted steering is excluded and bot planning is included.
- `serialization` is `changes(world)`; `commit` is database wait; `total` is their sum.
- `ticksOverBudget` counts `total` above 50 ms. `countryChunkWrites`/`Bytes` and `flushes` describe publish volume; `spikes` holds trace data.
- `profile-attribute.ts` buckets `.cpuprofile` samples by phase and prints self/inclusive time; coverage outside 97–105% means work is missing (blocked I/O, other threads).
- Artifacts: `<label>-local.json`, `<label>-local-profile.json`, `<label>-local-profile.profile.json`, `<label>-database.json`, `<label>.cpuprofile`, attribution JSON. `test-artifacts/` is gitignored.
- Checksums cover ownership plus player state; they are not a persisted-DB reload or cross-version guarantee. JSC shares are self samples, not process CPU.

### Workload and fixture

`profile.ts` runs the real `World.tick` on synthetic all-land 2000 × 1000 terrain with 20 countries and 40 movers. Each country starts with 26,112 home pixels; compact countries are rectangles, fragmented ones are U shapes with rival-owned 5 × 5 outposts. The fixture is not a real coastline or production map. Warmup, setup, restoration, GC, checksums, and invariants are outside the measured interval; 1,200 ticks is 60 s of game time.

### Validation

`bun test examples/cordon-off` covers masks, bounds, budget, batching, captures, restart, and gates. `bun run test:game` is the real-server smoke suite (plaintext and IPv6/TLS). Timing thresholds are not test assertions.

## Algorithm in brief

1. All movers paint first; countries resolve enclosures once per tick in first-change order, so a closure breached later in the same tick stays open. Water is traversable background.
2. The gate uses the straight/diagonal exit proof plus an open-run count. Unresolved candidates share a 16,384-cell local flood budget; a run-length eight-connected fallback scans the country bounds. Bounds only grow.
3. Country chunks publish every 3 ticks for reconciliation; clients predict one-cell movement paints from confirmed user rows. Enclosure captures of at least 100 cells force an immediate flush. User chunks and moves remain per tick.

## Change log

One line per iteration; detailed tables and reproduction notes are in this file's git history.

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
- **2026-10-18** — Profiled simulation, publish/database, and browser/peers; kept bot candidate reordering (simulation −13.2%/−14.5% on bot workloads), enclosure flood inlining (−10.2%/−11.7%/−5.3%), and 3-tick country-chunk coalescing with client movement-paint prediction and a 100-cell urgent-capture flush (country-chunk writes −20–32%, bytes −18–33%; 1,024-peer ack p95 152.9→140.5 ms, own-row p95 197.7→185.9 ms); rejected the chunk-row arena. Baseline `1393eff`; candidate `cd67280`.
- **2026-11-22** — Attribution pass: phase-split `bun --cpu-prof` profiles explain 99.3–103.5% of measured simulation/serialization; `--smol` bounds GC at ≤2.9%. Enclosure flood is 25% of fragmented-bot simulation and 66% of scripted (the old 8–14% share included serialization and setup); bot planning is ~55% of bot simulation; `countryChunk` is 69–78% of bot serialization. New machine baseline `4ca71ba` (macOS i9-9880H, Bun 1.4.4); the old `cd67280` baseline is unreachable. No production changes.
- **2026-11-22** — Live-stage attribution: at 512 players about two-thirds of the ZyncBase main thread's busy time is socket sends (2,167 of 7,086 samples in `__sendto`), with SQLite in single digits; at 1,024 the write-ack tail reaches p95 216 ms with 358-op bursts and publishes run on ~55% of ticks. The 512/1,024 client ack and row numbers are farm-bound on this machine. No production changes.
- **2026-11-22** — Rejected one-drain-per-fenced-transaction in the subscription worker: at 512 it left DB CPU unchanged (0.54–0.57 → 0.55–0.65 cores) and raised client commit p50 3.9–6.4 → 10.1–11.7 ms (p95 28–31 → 48–59 ms); concatenating outcomes behind the transaction's deltas in a single frame delays the client ack. Baseline/candidate worktrees at `4ca71ba`.
