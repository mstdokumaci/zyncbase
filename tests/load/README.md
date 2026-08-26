# Raw server load tests

These tests use native `k6/websockets` and the ZyncBase MessagePack wire protocol.
They intentionally do not import the TypeScript SDK at runtime, so SDK CPU and
memory do not hide server limits.

## Run

Install k6, then run a benchmark:

```sh
bun run test:load --profile connections
bun run test:load --profile store-accepted
bun run test:load --profile store-committed
bun run test:load --profile store-identical-filter
bun run test:load --profile presence-user
bun run test:load --profile presence-shared
```

Real runs reject configurations below 5,000 total WebSocket connections. Tiny
protocol checks are separate and are marked `benchmarkEligible: false`:

```sh
bun run test:load:smoke --profile store-identical-filter
```

The runner builds a ReleaseFast server, creates a fresh database, bundles the
test, raises the child-process file limit, starts the server, runs k6, and always
stops the server. Results remain under `test-artifacts/load/<timestamp>-<profile>/`.

## Profiles

| Profile | Default topology | What it measures |
| --- | --- | --- |
| `connections` | 5,000 clients | Ticket exchange, WebSocket establishment, SchemaSync, and idle connection cost |
| `store-accepted` | 5,000 writers | Mutation admission throughput; committed final sentinels prove each writer queue drained |
| `store-committed` | 5,000 writers | Durable commit throughput and commit latency with bounded per-client pipelines |
| `store-identical-filter` | 5,000 subscribers + 32 writers | Store subscription fanout through one structurally identical `match == true` filter group |
| `presence-user` | 5,000 subscribers + 32 writers | User-presence coalescing and namespace-wide fanout |
| `presence-shared` | 5,000 subscribers + 1 writer | Shared-presence coalescing and namespace-wide fanout |

Shared presence deliberately has exactly one writer. That keeps final-state
convergence unambiguous while still stressing the full subscriber fanout path.

## Load shape

Connection and standalone-store benchmarks default to 20 seconds for setup with
a 10-second connection ramp. Fanout profiles use 45 seconds with a 15-second
ramp because registering 5,000 subscriptions has a longer tail. All profiles use
1 second for the ready
barrier, 10 seconds warmup, 30 seconds measurement, and 10 seconds cooldown.
The default aggregate target is 10,000 messages/second for standalone store
profiles and a conservative 100 writes/second for fanout profiles. Each VU owns
20 sockets and uses one drift-correcting send pump. Hot-path accepted and presence
frames are pre-encoded.

Useful overrides:

```sh
bun run test:load --profile store-identical-filter \
  --subscribers 10000 --writers 64 --rate 25000 --duration 60
```

Supported flags are `--clients`, `--subscribers`, `--writers`, `--rate`,
`--sockets-per-vu`, `--setup`, `--connect-ramp`, `--barrier`, `--warmup`, `--duration`,
`--cooldown`, `--probe-rate`, `--max-inflight`, and `--max-event-loop-lag`.
Values are positive integers.
`--connect-ramp` may also be zero.

## Validity and results

A successful benchmark requires all clients to reach the setup barrier, no wire,
server, write, disconnect, generator-lag, or socket-backpressure errors, at least
98% of the requested measured sends, and exact final convergence. Presence gaps
during the run are valid because the engine coalesces updates; the final sentinel
must still reach every subscriber.

Low-rate probes carry send timestamps and report end-to-end fanout latency.
Counters use logical deltas, user updates, and shared patches after decoding
concatenated MessagePack messages—not WebSocket frame counts.

Each artifact directory contains:

- `k6-summary.json`: k6 metrics, thresholds, topology, and benchmark eligibility.
- `resources.json`: one-second CPU and RSS samples for both ZyncBase and k6.
- `run.json`: k6 version, git commit, host details, options, and exit status.
- `server-config.json`, `server.log`, and `data/`: the exact isolated server run.

If a benchmark fails a generator lag/backpressure/send-count threshold while k6
CPU is saturated, increase `--sockets-per-vu` or split k6 onto another machine before
attributing the limit to ZyncBase.
