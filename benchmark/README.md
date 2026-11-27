# Combo server load test

This is a server-side load test for ZyncBase. It drives a captured realtime
workload — filtered store subscriptions, writes, presence, and isolated
namespaces — and reports server CPU, memory, message and fanout counts, plus
client-observed fanout latency.

The measured claim is:

> On a 12-logical-CPU host, ZyncBase handled 50,000 concurrent clients across
> five isolated namespaces. The server used about 2 of the host's 12 cores and
> roughly 1.5 GB RSS. Store fanout moved 10.5M messages at about
> 2.6–3.9M messages/s, plus ~0.9M presence messages at 4.8–6.5M messages/s,
> with 1,875 messages per store create and 3,375 per update. Client-observed
> store p99 during the burst was 1.0–1.5 s. This is a burst profile, not a
> sustained throughput or sustained latency test.

A 100,000-client stress run also completed; see [Beyond 50k](#beyond-50k).

## Workload

Each 10,000-client unit is four roles of 2,500 clients:

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

## Usage

```sh
zig build -Doptimize=ReleaseFast

bun run bench:capture    # generate the workload corpus (first run only)
bun run bench:combo      # 10k clients
bun run bench:combo:50k  # 50k clients = 5 shards
bun run bench:combo:100k # 100k clients = 10 shards
```

The workload corpus is generated locally and is not checked in. Re-run
`bun run bench:capture` after schema or protocol changes.

## Results

Machine: AMD Ryzen 5 3600, 12 logical CPUs, 32 GB RAM, WSL2. Server:
Zig ReleaseFast. Three runs per size.

CPU, memory, and message counts are measured on the server. Latency is measured
at loopback clients; it includes server fanout queueing but excludes wide-area
network and device time.

| | 10k | **50k (reference)** | 100k |
|---|---:|---:|---:|
| clients | 10,000 | **50,000** | 100,000 |
| namespaces | 1 | **5** | 10 |
| server CPU | ~1.7 of 12 cores | **~2.0–2.1** | ~2.1–2.2 |
| server peak RSS | ~0.25–0.33 GB | **~1.3–1.6 GB** | ~2.2–3.2 GB |
| server RSS per 1k clients | ~24–32 MB | **~26–32 MB** | ~22–32 MB |
| store messages | 2.1 M | **10.5 M** | 21.0 M |
| messages per create | 1,875 | **1,875** | 1,875 |
| messages per update | 3,375 | **3,375** | 3,375 |
| store fanout rate | ~4.3–5.6 M/s | **~2.6–3.9 M/s** | ~2.3–2.7 M/s |
| presence messages | 0.06–0.10 M | **0.8–1.0 M** | ~2.0–2.8 M |
| presence fanout rate | ~0.5–0.7 M/s | **~4.8–6.5 M/s** | ~12–18 M/s |
| workload messages | ~2.2 M | **~11.3–11.5 M** | ~23.0–23.8 M |

Message counts are server-side messages accepted for delivery, not client
callbacks. Fanout is `sent - write/set acks`. Server RSS is peak while the
clients are connected; "per 1k" is the increase over the idle server. Presence
updates are state broadcasts, not events, so the server may coalesce them;
presence counts are not directly proportional across sizes.

### Client-observed latency

| | 10k | **50k** | 100k |
|---|---:|---:|---:|
| store create p50 | 0.13 s | **0.6–0.9 s** | 2.0–2.3 s |
| store create p99 | 0.27 s | **1.0–1.5 s** | 3.4–3.9 s |
| store update p50 | 0.13 s | **0.6–0.9 s** | 2.2–2.8 s |
| store update p99 | 0.18 s | **1.3–1.5 s** | 4.7–5.2 s |

Latency is measured from the start of the write burst to delivery at a
subscriber. It is a burst-tail number, not idle or sustained-load latency.

### Beyond 50k

100k clients completed and stayed isolated across 10 namespaces. Server CPU
stayed at ~2.1–2.2 cores — barely more than at 50k — while store fanout rate
fell to 2.3–2.7M messages/s and client-observed store p99 rose to 3.4–5.2 s.
This is the server's single-node ceiling for this workload. Treat 50k as the
reference operating point and 100k as a stress result, not a recommendation.

Remember that 100k here is ten namespaces of 10k clients, not one namespace
with 100k subscribers. A single large namespace would fan out each write to
many more clients and is not measured by this corpus.

## What this shows

- 50,000 concurrent WebSocket clients completed the workload on one server;
  100,000 also completed, with lower fanout rate and higher tail latency.
- Namespaces remained isolated at every size: the probe wrote only in shard 0,
  shard 0 saw the fanout, and all other shards saw zero cross-namespace frames.
- Store fanout scaled linearly with clients: 2.1M messages at 10k, 10.5M at
  50k, and 21.0M at 100k.
- Presence fanout reached 4.8–6.5M messages/s at 50k.
- The server used about 2 cores and about 30 MB per 1,000 clients at 50k,
  leaving host CPU and memory headroom.
- The 50k store burst tail stayed around 1.5 s p99.

## What this does not show

- Sustained throughput or sustained-load latency.
- Server-internal latency. The p99 above is measured at loopback clients.
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
If your expected message rate is near or above the measured 2.6–3.9M messages/s,
adapt the schema, filters, and rates in this harness and run it on your
hardware.

For memory, this workload used about 30 MB of server RSS per 1,000 connected
clients, or roughly 1.3–1.6 GB at 50k and 2.2–3.2 GB at 100k. Treat that as a
starting point, not a per-client guarantee: payloads, caches, and retained
history all add to it.

If you expect to operate beyond roughly 50k clients on one node, measure your
own tail latency: this harness stays stable to 50k, then spends the extra
clients on queueing rather than throughput.
