# Combo server load test

This is a server-side load test for ZyncBase. It drives a captured realtime
workload — filtered store subscriptions, writes, presence, and five isolated
namespaces — and reports wall time, CPU, message rate, and fanout volume.

The measured claim is:

> On a 12-logical-CPU host, with the load generator sharing that host, ZyncBase
> handled 50,000 concurrent clients across five isolated namespaces. The server
> used about 1.1 of the host's 12 cores. The store fanout moved 10.5M messages
> at roughly 1.8M messages/s during the store phases, plus about 0.7–0.8M
> presence messages, with 1,875 messages per store create and 3,375 per update.
> This is a burst profile, not a sustained throughput or p99 test.

## Workload

Each 10,000-client unit is four processes × 2,500 clients:

- two rooms, two tables (`items`, `events`)
- filters A/B per table
- 100 creators, 100 updaters, 100 user-presence writers, 100 shared-presence
  writers, and 2,100 passive subscribers per process
- individual `StoreSet` frames
- three presence ticks
- convergence waits for 100 ms with no inbound frames

`--shards N` runs N of these units under one server. Each shard gets its own
store and presence namespaces. An isolation probe writes in shard 0 and verifies
that the other shards receive zero frames.

## Usage

```sh
zig build -Doptimize=ReleaseFast

bun run bench:combo      # 10k clients
bun run bench:combo:50k  # 50k clients = 5 shards
```

The corpus is captured from `tests/e2e/src/test-combo-stress.ts`. Regenerate it
with `bun run bench:capture` after schema or protocol changes.

## Results

Machine: AMD Ryzen 5 3600, 12 logical CPUs, 32 GB RAM, WSL2. Server:
Zig ReleaseFast. The load generator and server share the host.

| | 10k | 50k (5 × 10k) |
|---|---:|---:|
| total wall | ~4.8–5.4 s | ~24.8 s (23.7–25.9) |
| setup / connect | ~2.1–2.6 s | ~11.5 s |
| store phases | ~1.1 s | ~5.7–7.1 s |
| presence phases | ~110 ms | ~125 ms |
| clients | 10,000 | 50,000 |
| namespaces | 1 | 5 |
| server CPU | ~1.0 cores | ~1.1 cores |
| total host CPU | ~2.7 of 12 | ~3.0 of 12 |
| store messages | 2.1 M | 10.5 M |
| store messages per create | 1,875 | 1,875 |
| store messages per update | 3,375 | 3,375 |
| store fanout rate | ~1.5–1.9 M/s | ~1.6–1.8 M/s |
| presence messages | ~0.04–0.09 M | ~0.7–0.8 M |
| workload messages | 2.1 M | ~11.2–11.3 M |

Message counts are server-side messages accepted for delivery, not client
callbacks. Fanout is `sent - write/set acks`. Setup accepted about 4,200–4,500
connections/s at 50k.

## What this shows

- 50,000 concurrent WebSocket clients completed the workload on one server.
- Five namespaces remained isolated: the probe saw fanout in shard 0 and zero
  frames in every other shard.
- Store fanout scaled linearly: 2.1M messages at 10k, 10.5M at 50k, at about
  1.8M messages/s during store phases.
- The server used about 1.1 of 12 cores. The workload is bound by the single
  event-loop thread, so adding cores does not raise this fanout ceiling.

## What this does not show

- Sustained throughput or p50/p95/p99 latency.
- A clean separate-host server ceiling. The load generator shares the host,
  which is conservative on CPU and optimistic on network (loopback).
- A general capacity rating for other schemas, filters, document sizes, or read
  patterns.
- High availability or multi-node behavior. ZyncBase is single-node; external
  routing is outside this test.

## Sizing guidance

If your app has a similar shape — filtered subscriptions, presence, moderate
writes, fanout to thousands of subscribers, single-node deployment — 50k
concurrent clients is a measured reference point.

Estimate your fanout:

```
writes/s × matching subscribers per write
+ presence updates/s × room subscribers
```

The 1,875 messages per create and 3,375 per update are specific to this corpus.
If your expected message rate is near or above the measured 1.5–1.9M messages/s,
adapt the schema, filters, and rates in this harness and run it on your
hardware.
