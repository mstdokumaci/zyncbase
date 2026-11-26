# Raw combo benchmark

A server-side replay of `tests/e2e/src/test-combo-stress.ts` that uses the
captured wire frames verbatim and no TypeScript SDK. Each 10,000-client unit
runs the same topology and phase sequence as the e2e combo, so the wall clock is
the combo load without the client SDK's encode/decode work.

## Pipeline

1. **Capture** — run the 10k e2e combo with a Bun `--preload` hook that appends
   every client->server frame to NDJSON, plus the first `SchemaSync`.
2. **Corpus** — preserve the captured frames: store namespace, store
   subscriptions A/B per table, presence namespaces per room, presence
   subscriptions, 400 individual store creates, 400 store updates, 400 user
   presence writers × 3 ticks, and 100 shared writers × 3 ticks per room.
3. **Replay** — four raw client processes × 2,500 connections per shard, each
   assigned the e2e role/table/room/filter for its local ID. Store phases await
   `WriteCommitted`; passive clients only drain. Convergence waits for inbound
   frames to go quiet for 100 ms.

The replay sends **individual `StoreSet` frames**, not `StoreBatch`, and it uses
the real A/B filters. There is no match-all mode.

## Sharding

`--shards N` runs N independent 10k combo units under one server:

```
shard 0: 4 processes × 2,500 clients → public, presence-combo-room-{0,1}
shard 1: 4 processes × 2,500 clients → public-s1, presence-combo-s1-room-{0,1}
...
```

Each shard still does one 10k combo's work per process. Three details
make the isolation real:

- **Namespaces per shard.** Store and presence namespaces are rewritten into the
  captured namespace frames; all other frames are reused unchanged.
- **Document IDs per shard.** The store tables use a global document primary
  key, so replaying the same captured IDs in parallel namespaces would overwrite
  rows across shards. The last byte of each captured 16-byte document ID is
  XOR-ed with the shard number, keeping create/update pairs aligned while making
  every shard's rows distinct.
- **Loopback IP per shard.** Each shard connects to `127.0.0.(shard+1)` on the
  same listener. This keeps the source-port tuple space separate; without it the
  50k localhost sockets exhaust the ephemeral port range and connections fail
  during setup.

After the workload, an isolation probe has shard 0 write one store document and
one user-presence update. It then asserts shard 0 sees fanout and shards 1..N
see **zero** frames. The probe runs after the measured phases, so it does not
pollute the workload counters.

Transient localhost connection resets during the connect burst are retried up to
three times. Setup response types are validated; any non-`ok` setup response
fails the run.

## Usage

```sh
zig build -Doptimize=ReleaseFast
bun run --filter @zyncbase/client build

bun run bench:capture    # 10k e2e combo capture + corpus build
bun run bench:corpus     # rebuild corpus from benchmark/corpus/raw
bun run bench:combo      # 10k raw replay
bun run bench:combo:50k  # 50k raw replay = 5 isolated shards
bun test benchmark/raw/protocol.test.ts  # namespace/doc-id rewrite checks
```

The corpus is generated and gitignored under `benchmark/corpus/`. Regenerate it
after schema, protocol, or combo-test changes. The 2,500 clients per process is
fixed by the captured global IDs.

## Baseline — 2026-11-26

Machine: AMD Ryzen 5 3600, 12 logical CPUs, WSL2. Server: Zig ReleaseFast.
Raw numbers are the median of 3 runs. SDK combo is one run of the current e2e
test on the same server.

| | 10k raw | 50k raw (5 shards) | 10k SDK combo |
|---|---:|---:|---:|
| total wall | **4,690 ms** (4,083–5,143) | **24,692 ms** (23,711–25,529) | **7,004 ms** |
| setup / connect | 2,442 ms | 12,232 ms | 2,945 ms |
| store create | 476 ms | 3,208 ms | 691 ms |
| store update | 688 ms | 3,231 ms | 896 ms |
| presence user | 55 ms | 62 ms | 536 ms |
| presence shared | 55 ms | 59 ms | 146 ms |
| convergence | 952 ms | 6,236 ms | 607 ms (max) |
| cleanup | 46 ms | 194 ms | ~123 ms |
| clients | 10,000 (4×2,500) | 50,000 (20×2,500) | 10,000 (4×2,500) |
| filters | A/B, 2 rooms, 2 tables | A/B, 2 rooms, 2 tables per shard | A/B, 2 rooms, 2 tables |
| server CPU | 0.97 cores | 1.12 cores | included in wall |
| client CPU | 7.4 s total, max 2.0 s | 52.1 s total, max 2.9 s | SDK decode included |
| per-shard payload | 315 MB (store 155.2 + presence) | 269–276 MB each (store 155.2 + coalesced presence) | — |

Scaling 5× the load costs 5.3× the wall time. The server's single event loop is
the limit at about 1.1 cores of CPU; client processes use about 2.1 cores total,
so the run is not client-bound. Per-shard payload bytes stay within ~2.5% across
shards, which is the equality check for the sharded workload.

Store fanout is identical at every scale: a store-only replay delivers
**155.2 MB per shard** at both 10k and 50k. The rest of the payload is presence
broadcasts. The presence worker merges pending updates when it falls behind, so
50k shards show fewer presence bytes while converging to the same presence
state.

The 10k raw replay is about 33% faster than the SDK combo for the same server
load: it removes the client SDK's decode/callback work, not any server work. The
store writes are committed to SQLite before fan-out; the replay includes that
path.

## Scope

- This is a **server-side** benchmark. Client SDK cost is excluded by design,
  like a database benchmark's load generator; in production the SDK runs on the
  users' browsers.
- The replay uses captured frames from the current combo test and the same
  topology; it does not verify store/presence convergence like the e2e test.
  The e2e test remains the correctness gate.
- Store deltas can be coalesced into fewer WebSocket frames, but their payload
  bytes are stable (155.2 MB per shard). Presence broadcasts are merged when the
  presence worker falls behind, so presence bytes are lower under 50k load.
  Per-shard store payload and the total wall are the stable measurements.
- 50k on this 12-core machine is bounded by the server event loop. Use a larger
  box or separate client hosts to find the server's ceiling above 50k.
