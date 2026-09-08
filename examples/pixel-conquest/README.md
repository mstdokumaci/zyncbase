# Pixel Conquest

A small multiplayer territory game using ZyncBase's real presence → store path. The browser sends direction input; a Bun simulation determines movement and ownership. Browsers receive territory and player dots together through map-chunk subscriptions.

## Run locally

From the repository root, with Zig 0.16, Bun, and the repository's native build prerequisites installed:

```sh
bun install
bun run demo:game
```

Open **http://localhost:8080**. The terminal prints an invite code. Enter it and a country name; friends using the same country name join the same team. WASD, arrow keys, or the on-screen buttons move in four directions. Releasing keys or switching away stops input. Players can pass through one another; spawning avoids occupied cells.

Every world starts with **10 server-controlled bots across five countries**, two bots per country. Squares are bots; circles are people. Each two active human players replace one bot: 2 humans → 9 bots, 8 humans → 6 bots, 20 humans → no bots. Bots return as people leave. Their territory remains with its country and can be conquered normally; retiring a bot does not erase land. Bots resume after a restart, and pause when no humans are playing.

The launch command builds the SDK and a ReleaseFast ZyncBase executable, then starts both the database and game. For subsequent starts without rebuilding:

```sh
bun run demo:game:dev
```

Stop with Ctrl+C. Territory is stored in `data/pixel-conquest/`. To clear the world, stop the running game first, then run:

```sh
bun run demo:game:dev --reset
```

The reset removes game chunks and countries and starts a fresh game. It does not touch other ZyncBase data directories.

## Cloudflare and VPS

Follow [the FreeBSD + Cloudflare setup](./DEPLOYMENT.md). One public origin serves browser assets from Cloudflare, sends `/session` and `/health` to Bun, and sends `/auth/ticket` and `/ws` directly to ZyncBase over IPv6/TLS. The production Bun process runs the simulation and token issuer; it does not relay database connections or serve browser files.

Build an uploadable browser directory with `bun run demo:game:build`. Its output is `examples/pixel-conquest/dist/`. Start the VM processes with `bun run demo:game:start`. The development command `demo:game:dev` supplies local routing on port 8080 and is not used on the VM.

| Variable | Default | Purpose |
| --- | --- | --- |
| `GAME_ORIGIN` | `http://localhost:8080` | Exact browser origin; use `https://game.example.com` in deployment. |
| `GAME_JOIN_CODE` | Random code printed at startup | Shared invite code; set it to keep the same code across restarts. |
| `GAME_HOST` | `127.0.0.1` | Bind address for both VM listeners. Use `::` for IPv6 deployment. |
| `GAME_PORT` | `8081` | Bun login/health port. Deployment example: `8444`. |
| `GAME_DB_PORT` | `3001` | ZyncBase ticket/WebSocket port. Deployment example: `8443`. |
| `GAME_TLS_CERT`, `GAME_TLS_KEY` | Unset | PEM certificate and key for both listeners. Set both to enable TLS. |
| `NODE_EXTRA_CA_CERTS` | Unset | CA PEM trusted by the simulation's HTTPS/WSS client. |
| `GAME_DATA_DIR` | `<repo>/data/pixel-conquest` | Persistent game data. Run one simulation against a data directory. |
| `GAME_SERVER_BIN` | `<repo>/zig-out/bin/zyncbase` | Prebuilt ZyncBase executable. |
| `GAME_DEV_PORT` | `8080` | Development router port, used only by `demo:game:dev`. |

With TLS, the simulation connects to the hostname from `GAME_ORIGIN` on `GAME_DB_PORT`. Map that hostname to `::1` in the VM's `/etc/hosts` so simulation traffic stays local while certificate verification stays enabled. Without TLS it connects to `127.0.0.1`.

Changing the hostname requires restarting with the matching origin. Player tokens last 24 hours; a server restart or expired token requires rejoining. Territory remains owned by the country.

## Prototype choices

- One 2000 × 1000 world, cropped to longitude −135°…180°, latitude −60°…85°, with **661,568 land pixels**. New players spawn near the first connected player, starting around northern Italy.
- Each 32 × 32 chunk stores a little-endian uint16 ownership bitmap in `bytes`, plus a JSON-encoded `bytes` list of player dots. Water remains unowned. Arrays are not used as positional store data.
- `RULES` in `shared.ts` sets the 50 ms tick and own/neutral/enemy movement costs of 1/2/4 ticks. Entering or leaving water adds 4 ticks. Completed steps paint land, and enclosing an area captures its land for the surrounding country. The same rule lets a defender reclaim a severed extension. Water remains unowned.
- Flushes wait for **committed** acknowledgment. Ticks pause while a commit is pending, so slow storage slows the game without accumulating writes or producing catch-up bursts. A write or database connection failure stops the game; restart restores committed territory and reconciles dots. A commit acknowledgment does not measure browser delivery.
- Input heartbeats renew a two-second movement lease; silent players stop, and their dots expire after ten seconds. Normal disconnects remove dots sooner. Rejoining preserves country territory, not the old player position.
- Players cannot write chunks, countries, or shared presence. Browser code does not subscribe to presence. ZyncBase currently uses the same read gate for joining a presence namespace and subscribing to it, so authorized players could inspect input presence with a custom client; there is no hidden game information there.
- Admission is capped at 32 humans for this demo, with bots yielding space as humans join. This is a product limit, **not a measured server capacity**. No rounds, victory rules, body-blocking, minimap, or prediction yet.
- Bots prefer nearby unclaimed or enemy land, avoid water, and stay near human activity. They use the same movement costs and authoritative store updates as people. This is a simple gameplay opponent, not a simulation of browser connections or network load.

The terminal logs cumulative inputs, ticks, committed flushes, changed chunk writes, chunk payload bytes (before subscriber fan-out), and the latest commit duration. The browser displays echoed input-to-view time. These are diagnostic observations, not a throughput benchmark. Measure the complete workload on the VPS, including actual outgoing traffic and overlapping visible-chunk subscriptions, before drawing performance conclusions; FortiEDR makes this development machine unsuitable for that comparison.

## Checks

Build once with `bun run demo:game`, then stop it. Run:

```sh
bun run test:game
bunx biome check --write --error-on-warnings
bun run lint
```

`test:game` checks movement costs, stop/resume behavior, chunk boundaries, input expiry, map data, bot teams and replacement counts, and restart reconciliation. Its real-server smoke checks use isolated temporary databases and a development router mirroring Cloudflare. They exercise plaintext and IPv6/TLS origins (with a temporary trusted certificate generated by OpenSSL), and SDK clients to check invitations, subscriptions, write restrictions, disconnect cleanup, bot retirement and return, persistence, and manual reset.

The enclosure performance tests also run with `test:game`. They count ownership bitmap reads during actual simulation steps, so regressions fail independently of machine speed. To print median step times as well:

```sh
GAME_BENCH=1 bun test examples/pixel-conquest/enclosure.perf.test.ts
```

Fixtures cover small and large U-shaped countries, a rotated U, a solid square, and a large loop closure. A step along the inner border of the 202,500-pixel U originally needed 3,763,788 bitmap reads; checking local connectivity first reduces that to 13. Steps that cannot close a gap skip the flood fill. Actual closures still search and fill their enclosed area. Timings exclude fixture setup and bitmap-read instrumentation, use two warmups and seven samples, and measure simulation only; database commits, browser delivery, and VPS capacity require separate measurements.

For a manual browser check, open two windows, join different countries, move across the same area, release the keys, switch tabs while moving, disconnect one player, and restart the server. Test teammates by entering the same country name. Repeat at the public Cloudflare hostname before inviting everyone.

## Map source

`land.json` contains run-length encoded land spans derived from [Natural Earth's 1:110m land polygons](https://github.com/nvkelso/natural-earth-vector/blob/master/geojson/ne_110m_land.geojson), sampled at pixel centers with an equirectangular projection over the bounds above. Natural Earth data is [public domain](https://www.naturalearthdata.com/about/terms-of-use/). Land and water are terrain; player-created countries are independent of real political borders.
