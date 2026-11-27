# Cordon Off profiling

**Current state (2026-11-27):** Bun 1.4.3, Linux x86_64, AMD Ryzen 5 3600; last A/B baseline `bb5149a`. Numbers in this file are session snapshots; re-baseline at the start of every session and do not compare across machines.

**Latest measured state:** local 0.15 ms/tick (simulation 0.096, serialization 0.057); 512/1,024 live farm rx 37.3/94.9 MB/s, ack p95 20.4/99.1 ms, row p95 65.4/123.8 ms; country-chunk payload −24.3% on the live 1,024 snapshot. The 1,024 stage is peer-farm-bound (9.9/12 threads), so its server latency is not a clean server measurement.

## Iteration loop

1. **Preflight.** Clean tree; record `git rev-parse HEAD`, `bun --version`, `uname -sm`, and the CPU model. Run `bun install`, `bun test examples/cordon-off`, `bun run typecheck:examples`, and `bun run lint`.
2. **Baseline.** Three repeats per workload at interval 1 and 3; one 12,000-tick run. Same machine, no concurrent work, alternating baseline and candidate.
3. **Attribute first.** Phase-split a `bun --cpu-prof` run and confirm sampled time covers the harness's phase totals. For live stages, sample the ZyncBase process natively and read `server.json`/`results.json`. Rank by absolute cost (ms/tick or cores), not by share of a small total.
4. **One target.** Pick a change reachable from the profile; do not bundle unrelated wins.
5. **A/B.** Baseline worktree at the recorded commit; three alternating pairs; medians and ranges; checksums must match. Keep only if the metric ranges separate and no user-visible behaviour regresses; otherwise revert and record why.
6. **Record.** One changelog line with the commit, the kept change, and the evidence. Detailed tables stay in this file's git history.

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

`--profile` reports JSC self samples and cannot split phases or resolve native frames. Prefer Bun's CPU profiler and phase-split the result:

```sh
bun --cpu-prof --cpu-prof-interval=250 --cpu-prof-dir test-artifacts/cordon-off-profile/attrib \
  --cpu-prof-name p.cpuprofile examples/cordon-off/profile.ts --mode bots --shape fragmented \
  --ticks 12000 --chunk-interval 3 --output test-artifacts/cordon-off-profile/attrib/out
bun examples/cordon-off/profile-attribute.ts test-artifacts/cordon-off-profile/attrib/p.cpuprofile \
  --json test-artifacts/cordon-off-profile/attrib/attribution.json
```

The report buckets samples by the harness frame (`World.tick`, `changes`, `steer`, fixture, verify) and prints self and inclusive time, plus the harness's reported phase totals for a coverage check. Coverage outside 97–105% means work is missing (blocked I/O, other threads). `--cpu-prof` profiles the main thread only; worker threads and the database process need counters or `ps`. Allocation and collector time stay attributed to the allocating function, so use a `--smol` A/B to bound GC.

### Publish/database

```sh
bun examples/cordon-off/profile.ts --publish --unpaced --chunk-interval 3 --mode bots --shape fragmented --ticks 1200
```

`--publish` starts an isolated real server/database, builds it if needed, and is not comparable to local simulation. Omit `--unpaced` for the 20 Hz cadence. No browser subscribers, presence traffic, TLS, or fan-out are simulated.

### Browser and peers

```sh
bun examples/cordon-off/profile-browser.ts --players 512,1024 --seconds 30 --countries 32 --port 19183 --output test-artifacts/cordon-off-profile/browser-run
```

This starts the real server, an observer Chromium page, and SDK peer workers. Use a direct interval-1 versus interval-3 A/B for coalescing changes. `--profile` records the observer page; `--server-profile` records the game server. The 1,024 stage measures the peer farm when it nears CPU saturation. Pin `GAME_ROUND_MS` (for example `86400000`) for A/B runs: the default one-hour boundary lands on the top of the hour and can archive/restart the world mid-stage.

For the live path, `server.json` has tick/tickIntervals/waits/commits and per-second process CPU; `results.json` has per-stage driver CPU/rx and before/after CPU for the game server and ZyncBase. For native stacks, run `sample <zyncbase-pid> 10 -file <out>` during the measured stage; SQLite and socket sends are distinguishable. The farm's worker threads are not covered by `--cpu-prof`; add counters when that is the question.

### Reading results

- `simulation` is `World.tick` only; scripted steering is excluded and bot planning is included.
- `serialization` is `changes(world)`; `commit` is database wait; `total` is their sum.
- `ticksOverBudget` counts `total` above 50 ms. `countryChunkWrites`/`Bytes` and `flushes` describe publish volume; `spikes` holds trace data.
- `profile-attribute.ts` buckets `.cpuprofile` samples by phase and prints self/inclusive time; coverage outside 97–105% means work is missing.
- Artifacts: `<label>-local.json`, `<label>-local-profile.json`, `<label>-local-profile.profile.json`, `<label>-database.json`, `<label>.cpuprofile`, attribution JSON, `server.json`, `server.log`, `results.json`. `test-artifacts/` is gitignored.
- Checksums cover ownership plus player state; they are not a persisted-DB reload or cross-version guarantee. JSC shares are self samples, not process CPU.

### Workload and fixture

`profile.ts` runs the real `World.tick` on synthetic all-land 2000 × 1000 terrain with 20 countries and 40 movers. Each country starts with 26,112 home pixels; compact countries are rectangles, fragmented ones are U shapes with rival-owned 5 × 5 outposts. The fixture is not a real coastline or production map. Warmup, setup, restoration, GC, checksums, and invariants are outside the measured interval; 1,200 ticks is 60 s of game time.

### Validation

`bun test examples/cordon-off` covers masks, bounds, budget, batching, captures, restart, and gates. `bun run test:game` is the real-server smoke suite (plaintext and IPv6/TLS). Timing thresholds are not test assertions.

## Algorithm in brief

1. All movers paint first; countries resolve enclosures once per tick in first-change order, so a closure breached later in the same tick stays open. Water is traversable background.
2. The gate uses the straight/diagonal exit proof plus an open-run count. Unresolved candidates share a 16,384-cell local flood budget; a run-length eight-connected fallback scans the country bounds. Bounds only grow.
3. Country chunks publish every 3 ticks for reconciliation; single-cell runs are one byte and longer runs are a count plus palette code. Clients predict one-cell movement paints from confirmed user rows. Enclosure captures of at least 100 cells force an immediate flush. User chunks and moves remain per tick.

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
- **2026-11-22** — Attribution pass: phase-split `bun --cpu-prof` profiles plus live native sampling; kept the roster fan-out reduction (chunk crossings no longer publish a `users` row; farm rx −12.6%, farm CPU −9.8%, ZyncBase CPU −6.7% at 512; checksums match) and rejected one-drain-per-fenced-transaction (no CPU win, ack regression). Baseline `4ca71ba`.
- **2026-11-27** — Fresh attribution found local total at 0.15 ms/tick (~0.3% of a 20 Hz core; countryChunk 0.039) and the 1,024 live stage saturating the peer farm (9.9/12 threads; server 0.13 Bun + 0.73 DB cores), which inflates 1,024 commit p95 to 65 ms. Kept the one-byte single-cell country-chunk RLE token (46.5% of live runs are length 1; payload −24.3% on a live 1,024 snapshot, −5% on the long-run local fixture): three live pairs measured farm rx −17.4% at 512 and −21.7% at 1,024, observer rx −19.4%/−8.6%, ack p95 −9.0%/−9.7%, row p95 −0.3%/−3.3%, fps flat, zero errors; local checksums match. Baseline `bb5149a`.
