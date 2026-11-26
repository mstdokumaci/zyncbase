# Combo server load test

This test drives the workload from `tests/e2e/src/test-combo-stress.ts` against
one ZyncBase server. The clients are WebSocket load generators. They exist only
to put the same load on the server from the same machine; nothing here measures
client behavior.

The measured claim is:

> On a 12-logical-CPU host, with the load generator sharing that host, ZyncBase
> handled 50,000 concurrent clients across five isolated shards, each with its
> own store and presence namespaces. The server used about 1.1 of the host's
> 12 cores; host CPU was not the constraint. The workload moved about 11.2M
> server messages at roughly 1.5–1.9M messages/s during active phases, with
> 1,875 messages per store create and 3,375 per update. It was a burst, not a
> sustained throughput or p99 test.

## Workload

Each 10,000-client unit is four processes × 2,500 clients:

- two rooms, two tables (`items`, `events`)
- filters A/B per table
- 100 creators, 100 updaters, 100 user-presence writers, 100 shared-presence
  writers, and 2,100 passive subscribers per process
- individual `StoreSet` frames, not batches
- store phases await `WriteCommitted`
- three presence ticks, with full tick 0 and partial ticks 1/2
- convergence waits for 100 ms with no inbound frames

The corpus is captured from the current combo test. Store creates and updates
are individual frames; the load generator replays them unchanged.

## Message measurement

The benchmark samples the server's `GET /stats` endpoint before and after each
phase. `messages.sent_total` counts every message inside a coalesced frame, so
the report is in messages, not bytes. Fanout is `sent - write/set acks`.
Per-phase numbers are averages and can include spillover from the previous
phase; workload totals are the stable measurement.

## Sharding

`--shards N` runs N independent 10k units under one server:

```
shard 0: 4 processes × 2,500 clients → public, presence-combo-room-{0,1}
shard 1: 4 processes × 2,500 clients → public-s1, presence-combo-s1-room-{0,1}
...
```

Each shard still does one 10k unit's work per process. Three details make the
isolation real:

- **Namespaces per shard.** Store and presence namespaces are rewritten into the
  captured namespace frames; all other frames are reused unchanged.
- **Document IDs per shard.** The store tables use a global document primary
  key, so replaying the same captured IDs in parallel namespaces would overwrite
  rows across shards. The last byte of each captured 16-byte document ID is
  XOR-ed with the shard number, keeping create/update pairs aligned while making
  every shard's rows distinct.
- **Loopback IP per shard.** Each shard connects to `127.0.0.(shard+1)` on the
  same listener. This keeps the source-port tuple space separate; without it the
  50k localhost sockets exhaust the ephemeral port range during setup.

After the workload, an isolation probe has shard 0 write one store document and
one user-presence update. It then asserts shard 0 sees fanout and shards 1..N
see zero frames. The probe runs after the measured phases, so it does not
pollute the workload counters.

Transient localhost connection resets during the connect burst are retried up to
three times. Setup response types are validated; any non-`ok` setup response
fails the run.

## Usage

```sh
zig build -Doptimize=ReleaseFast

bun run bench:capture    # capture the combo workload and build the corpus
bun run bench:corpus     # rebuild corpus from benchmark/corpus/raw
bun run bench:combo      # 10k clients
bun run bench:combo:50k  # 50k clients = 5 isolated shards
bun test benchmark/load/protocol.test.ts  # namespace/doc-id rewrite checks
```

The corpus is generated and gitignored under `benchmark/corpus/`. Regenerate it
after schema or protocol changes. The 2,500 clients per process is fixed by the
captured global IDs.

## Baseline — 2026-11-26

Machine: AMD Ryzen 5 3600, 12 logical CPUs, 32 GB RAM, WSL2. Server:
Zig ReleaseFast. The load generator and server share the same host. Values are
the observed range across runs.

| | 10k | 50k (5 × 10k) |
|---|---:|---:|
| total wall | ~4.8 s (4.4–5.1) | ~26 s (24–28.4) |
| setup / connect | ~2.1 s | ~11.5 s |
| store phases | ~1.1 s | ~5.7–7.1 s |
| presence phases | ~110 ms | ~125 ms |
| clients | 10,000 | 50,000 |
| shards | 1 | 5 |
| server CPU | ~1.0 cores | ~1.1 cores |
| load generator CPU | ~1.6 cores | ~1.9–2.0 cores |
| total host CPU | ~2.7 of 12 | ~3.0 of 12 |
| store messages | 2.1 M | 10.5 M |
| store messages per create | 1,875 | 1,875 |
| store messages per update | 3,375 | 3,375 |
| store fanout rate | ~1.5–1.9 M/s | ~1.5–1.9 M/s |
| presence messages | ~0.03–0.04 M | ~0.75–0.83 M |
| workload messages | 2.13–2.14 M | ~11.2–11.3 M |
| workload message rate | ~1.3–1.5 M/s | ~1.5–1.9 M/s |
| messages per client frame | 44–56 | 76–105 |
| store payload per shard | 155.2 MB | 155.2 MB |
| total payload per shard | ~315 MB | ~270–297 MB |

Setup: 50,000 connections in ~11.5 s (~4,300/s); the server sent 300k messages
and received 250k messages during setup.

Message counts are server-side messages accepted for delivery. Store counts are
stable across runs and scale linearly: 2.1M at 10k, 10.5M at 50k. Presence
messages are coalesced and vary with load, so presence totals per shard are not
directly comparable across scales.

Bytes are secondary. A store-only replay delivers 155.2 MB per shard at both
scales; the remaining payload is presence traffic. Thread count is not core
usage: the server configured 12 threads on this host, but used about 1.1 cores.

## Server CPU profile — 50k

The benchmark samples server CPU per phase and per thread. On the 50k run:

| phase | wall | server cores | main thread |
|---|---:|---:|---:|
| setup | ~11.4 s | ~1.15 | ~0.96 |
| store create | ~3 s | ~1.2 | ~1.0 |
| store update | ~3 s | ~1.2 | ~1.0 |
| presence | ~0.12 s | ~1.3 | ~0.9–1.0 |
| converge | ~0.1 s | idle | idle |

The four subscription workers, writer, readers, checkpoint thread, and presence
thread each use roughly 0.01–0.04 cores. The main event-loop thread is more than
90% of server CPU.

Setup breaks down roughly as:

- **~6.6 s** for ticket, WebSocket upgrade, schema sync, and store namespace
  - ticket issuance alone is ~2.2 s for 50k tickets
- **~4.8 s** for the store and presence subscription setup

`perf` samples of the user-space stacks show where the event-loop CPU goes:

| phase | dominant user-space cost |
|---|---|
| setup | `send` syscalls ~39%, SQLite/JWT/JSON spread behind it |
| store fanout | `send` syscalls ~62%, `memcpy` ~19%, grouping ~2–3% |

The store path is not primarily append/grouping CPU. It is dominated by sending
already-coalesced frames and copying their payloads. The setup path is also
send-heavy, with a long tail of ticket, SQLite, JSON, and allocation work.

This means:

- Adding cores will not improve this workload; the event loop is the ceiling.
- Micro-optimizing `appendToGroup` alone will not move the result much.
- The useful directions are fewer sends/frames, fewer bytes on the wire, or
  parallelizing/offloading the event-loop send path.
- Setup is the larger wall segment, and it is also send/round-trip heavy.

## What this result proves

- 50,000 concurrent WebSocket clients connected and completed the workload.
- Five shards remained isolated: the probe saw fanout in shard 0 and zero
  frames in every other shard.
- Store fanout scaled linearly in messages: 2.1M at 10k and 10.5M at 50k, with
  1,875 messages per create and 3,375 per update.
- The server accepted roughly 1.5–1.9M messages/s during active phases at 50k.
- Setup accepted about 4,300 connections/s and exchanged 300k server messages /
  250k client messages.
- Store payload was consistent across shards: 155.2 MB per 10k unit.
- No connections dropped and no server warnings were logged in these runs.
- The server used about 1.1 of 12 cores, so host CPU capacity was not the
  constraint. The main event-loop thread used about 1.0 core in every phase;
  all other server threads stayed below 0.05 cores each.

## What this result does not prove

- It is not a sustained throughput measurement. The store and presence work is a
  burst; the rest is setup and convergence.
- Message counts are server-side messages accepted for delivery, not client
  callbacks or client-decoded messages.
- Phase message rates are averages. Fanout can spill from one phase into the
  next, and presence coalescing changes presence totals.
- It has no p50/p95/p99 latency numbers.
- It is not a clean separate-host server measurement. The load generator shares
  the host, which is conservative on CPU and optimistic on network (loopback).
- It is not a core-count result. The thread budget changes with CPU count, so no
  claim is made about how the same load behaves on 8 or 16 cores.
- Per-thread CPU is sampled from `/proc`; it shows the main event-loop thread is
  the ceiling. The profile is co-located with the load generator, so syscall and
  network costs are specific to loopback on this host.
- It is not a general capacity rating for other schemas, fanout ratios, document
  sizes, or read patterns.
- The send path is single-threaded by design. More host cores do not raise this
  fanout ceiling without a server-side change.

## Sizing guidance

Use this as a reference point, not a guarantee. If your app has a similar shape
— filtered subscriptions, presence, moderate writes, fanout to thousands of
subscribers, single-node deployment — 50k concurrent clients is a measured point
on this host.

For your own project, estimate:

- peak concurrent connections
- writes per second
- matching subscribers per write (fanout)
- average update size
- presence users per room and update rate

If your expected peak is close to or above this workload, adapt the schema,
filters, and rates in this harness and run it on your hardware. If it is far
below, this result is a useful lower-bound data point.

This test does not establish a connection ceiling beyond 50k, a sustained write
rate, or a latency bound. Those require the scaling and overload tests described
in the benchmark plan.
