# Combo server load test

This is a server-side load test for ZyncBase. It drives a captured realtime
workload — filtered store subscriptions, writes, presence, and isolated
namespaces — and reports server CPU, memory, message and fanout counts, plus
harness-inclusive wall time and client-observed fanout latency.

The measured claim is:

> On a 12-logical-CPU host, with the load generator sharing that host, ZyncBase
> handled 50,000 concurrent clients across five isolated namespaces. The server
> used about 2 of the host's 12 cores and roughly 1.5 GB RSS. Store fanout
> moved 10.5M messages at about 2.8–3.3M messages/s, plus 1.2M presence
> messages at 8.9–9.3M messages/s, with 1,875 messages per store create and
> 3,375 per update. Client-observed store p99 during the burst was 1.7–1.9 s.
> This is a burst profile, not a sustained throughput or sustained latency test.

A 100,000-client stress run also completed; see [Beyond 50k](#beyond-50k).

## Workload

Each 10,000-client unit is two workers × 5,000 clients. Each worker drives two
logical roles of 2,500 clients, so a shard still covers two rooms and two
tables:

- two rooms, two tables (`items`, `events`)
- filters A/B per table
- 100 creators, 100 updaters, 100 user-presence writers, 100 shared-presence
  writers, and 2,100 passive subscribers per role
- individual `StoreSet` frames
- three presence ticks
- convergence waits for 100 ms with no inbound frames

`--shards N` runs N of these units under one server. Each shard gets its own
store and presence namespaces. An isolation probe writes only in shard 0 and
verifies that no other namespace receives that write (zero cross-namespace
frames).

`BENCH_LATENCY=1` adds two dedicated store subscribers per role. They record
delivery time relative to the write burst; their fanout copies are excluded
from the message totals.

## Usage

```sh
zig build -Doptimize=ReleaseFast

bun run bench:capture    # generate the workload corpus (first run only)
bun run bench:combo      # 10k clients
bun run bench:combo:50k  # 50k clients = 5 shards
bun run bench:combo:100k # 100k clients = 10 shards

BENCH_LATENCY=1 bun run bench:combo:50k  # add store fanout latency probes
```

The workload corpus is generated locally and is not checked in. Re-run
`bun run bench:capture` after schema or protocol changes.

## Results

Machine: AMD Ryzen 5 3600, 12 logical CPUs, 32 GB RAM, WSL2. Server:
Zig ReleaseFast. The load generator and server share the host. Three runs per
size.

### How to read these numbers

- **Server-side:** server CPU, server peak RSS, and message/fanout counts. These
  are read from the server process and its stats endpoint.
- **Harness-inclusive:** connect time, total wall, and p99. The Bun load
  generator runs on the same host, so these include generator scheduling and
  client processing. Generator CPU is reported so that overhead is visible.
- **Network:** loopback is intentional. It removes network variance so the
  numbers reflect server work. Real network and device latency are outside this
  benchmark and are additive for any server.
- **100k is 10 isolated namespaces × 10k clients,** not one 100k-subscriber
  namespace. Per-write fanout stays at ~1,875/3,375 in every shard.

### Throughput and resources

| | 10k | **50k (reference)** | 100k |
|---|---:|---:|---:|
| total wall (harness) | ~2.5–2.8 s | **~13.1–14.1 s** | ~32.1–32.9 s |
| connect (harness) | ~1.6–1.8 s | **~5.6–7.0 s** | ~14.1–14.9 s |
| clients | 10,000 | **50,000** | 100,000 |
| workers | 2 | **10** | 20 |
| namespaces | 1 | **5** | 10 |
| server CPU | ~1.7 of 12 cores | **~2.0–2.1** | ~2.1–2.2 |
| server peak RSS | ~0.25–0.33 GB | **~1.5–1.6 GB** | ~3.0–3.2 GB |
| server RSS per 1k clients | ~24–32 MB | **~30–32 MB** | ~30–32 MB |
| store messages | 2.1 M | **10.5 M** | 21.0 M |
| messages per create | 1,875 | **1,875** | 1,875 |
| messages per update | 3,375 | **3,375** | 3,375 |
| store fanout rate | ~4.3–5.6 M/s | **~2.8–3.3 M/s** | ~2.3–2.8 M/s |
| presence messages | 0.06–0.10 M | **~1.2 M** | ~2.1–2.4 M |
| presence fanout rate | ~0.5–0.7 M/s | **~8.9–9.3 M/s** | ~14.5–16.3 M/s |
| workload messages | ~2.2 M | **~11.7 M** | ~23.1–23.4 M |

Message counts are server-side messages accepted for delivery, not client
callbacks. Fanout is `sent - write/set acks`. Server RSS is peak while the
clients are connected; "per 1k" is the increase over the idle server.

### Client-observed latency

Store fanout latency, measured in separate `BENCH_LATENCY=1` runs with
dedicated probe subscribers on the shared host:

| | 10k | **50k** | 100k |
|---|---:|---:|---:|
| create p50 | 0.13 s | **1.0–1.1 s** | 2.1–2.3 s |
| create p99 | 0.27 s | **1.7–1.9 s** | 3.4–3.5 s |
| update p50 | 0.13 s | **0.95–1.2 s** | ~2.7 s |
| update p99 | 0.18 s | **1.8–1.9 s** | 4.0–5.2 s |

Latency is measured from the start of the write burst to delivery at a probe
subscriber. It includes the time the server spends working through the burst
plus generator scheduling; it is an upper bound on server-side delivery. A
server-internal p99 would need timestamps inside the server, which this harness
does not add.

The co-located load generator used ~2.2 cores at 10k, ~2.9 cores at 50k, and
~3.2 cores at 100k. The host was not CPU-saturated, but the generator still
competes for cache and memory bandwidth.

### Beyond 50k

100k clients completed and stayed isolated across 10 namespaces, but the server
used only ~2.1–2.2 cores — barely more than at 50k — while wall time grew to
~32–33 s and client-observed store p99 rose to 3.4–5.2 s. Its two event-loop
threads are saturated at that point. Treat 50k as the reference operating point
and 100k as a ceiling/stress result, not a recommendation.

Remember that 100k here is ten namespaces of 10k clients, not one namespace
with 100k subscribers. A single large namespace would fan out each write to
many more clients and is not measured by this corpus.

## What this shows

- 50,000 concurrent WebSocket clients completed the workload on one server;
  100,000 also completed, with higher wall time and client-observed tail
  latency.
- Namespaces remained isolated at every size: the probe wrote only in shard 0,
  shard 0 saw the fanout, and all other shards saw zero cross-namespace frames.
- Store fanout scaled linearly with clients: 2.1M messages at 10k, 10.5M at
  50k, and 21.0M at 100k.
- The server used about 2 cores and about 30 MB per 1,000 clients at 50k,
  leaving host CPU and memory headroom.
- The 50k client-observed burst tail stayed around 2 s p99.

## What this does not show

- Sustained throughput or sustained-load latency.
- A separate-host client ceiling. The generator shares the host, so connect,
  wall, and p99 include client CPU contention.
- Server-internal latency. p99 is client-observed, not measured inside the
  server.
- Network or device latency. Loopback is intentional; real network and device
  latency are additive and out of scope.
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
If your expected message rate is near or above the measured 2.8–3.3M messages/s,
adapt the schema, filters, and rates in this harness and run it on your
hardware.

For memory, this workload used about 30 MB of server RSS per 1,000 connected
clients, or roughly 1.5 GB at 50k and 3 GB at 100k. Treat that as a starting
point, not a per-client guarantee: payloads, caches, and retained history all
add to it.

If you expect to operate beyond roughly 50k clients on one node, measure your
own tail latency: this harness stays stable to 50k, then spends the extra
clients on queueing rather than throughput.
