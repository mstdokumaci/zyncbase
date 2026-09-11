# Pixel Conquest

A small multiplayer territory game using ZyncBase's real presence → store path. The browser sends direction input; a Bun simulation determines movement and ownership. Browsers receive territory and player dots together through map-chunk subscriptions.

## Run locally

From the repository root, with Zig 0.16, Bun, OpenSSL, and the repository's native build prerequisites installed:

```sh
bun install
bun run demo:game
```

Open **http://localhost:8080**. Enter a player name (1–16 characters), then choose an existing country to team up or select **Create a country** while slots remain. Anyone with the URL can join; no invite code or account is needed. The picker previews the selected country's color and territory; the slot count refreshes every five seconds. Each human's name appears above their dot: yours is bold gold, others are muted off-white, with dark outlines for readability. Bots have no name labels. WASD, arrow keys, or the on-screen buttons move in four directions. Releasing keys or switching away stops input. The world wraps horizontally: walking off one side continues on the other, so the Pacific seam connects Russia and Canada. Players can pass through one another; spawning avoids occupied cells.

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

- One 2000 × 1000 world, cropped to longitude −135°…180°, latitude −60°…85°, with **661,453 land pixels**. The world wraps horizontally; the first and last map columns are water, so no owned wall can cross the seam and enclosure scans stay planar. New players and bots spread over eight spawn regions sampled across the map's large landmasses instead of stacking on one; the first region is northern Italy. Joiners of an existing country spawn on its territory when it has room, otherwise beside a live teammate.
- Each 32 × 32 chunk stores a little-endian uint16 ownership bitmap in `bytes`, plus a JSON-encoded `bytes` list of slim player dots (`player_id`, `x`, `y` only). Identity lives in the `users` table itself (`name`, `country_id`, `is_bot`, last-known `lastX`/`lastY`, keyed by the session identity), subscribed once and joined client-side at render; dots repeat no names. Water remains unowned. Arrays are not used as positional store data.
- `RULES` in `shared.ts` sets the 50 ms tick and own/neutral/enemy movement costs of 1/2/4 ticks. Entering or leaving water adds 6 ticks. All movers paint first, then affected countries resolve enclosures in first-change order. Safe gates skip changes that cannot enclose anything; bounded local searches handle small cases, with at most one whole-country scan per country per tick as fallback. Captures can add other affected countries to that pass, but no country runs twice. Enclosures capture land and let defenders reclaim severed extensions. Water remains unowned and gaps through water keep an area open. A closure breached later in the same tick does not capture its interior.
- Flushes wait for **committed** acknowledgment. Ticks pause while a commit is pending, so slow storage slows the game without accumulating writes or producing catch-up bursts. A write or database connection failure stops the game; restart restores committed territory and reconciles dots. A commit acknowledgment does not measure browser delivery.
- Country creation sends `countryName` once to `/session`, which returns the assigned `countryCode`. Presence identifies countries only by `countryCode`. A newly allocated country with no land or players is removed after ten seconds if its creator never connects.
- Input heartbeats renew a two-second movement lease; silent players stop, and their dots expire after ten seconds. Normal disconnects remove dots sooner. Rejoining preserves country territory, not the old player position.
- Player names are validated on admission, normalized, and fixed for that connection. Names are separate from country membership and need not be unique. Departed players keep their roster row for ten seconds so a same-id reconnect resumes in place; dots vanish immediately and never pin countries. Labels stay within 120 screen pixels, and your dot and name draw last to remain visible in a crowd.
- Players cannot write chunks, countries, or shared presence. Browser code does not subscribe to presence. ZyncBase currently uses the same read gate for joining a presence namespace and subscribing to it, so authorized players could inspect input presence with a custom client; there is no hidden game information there.
- The browser draws at up to 30 FPS and animates the local dot and camera through fractional positions using elapsed time and the existing terrain costs. It anticipates at most one unconfirmed cell, waits there if updates stall, and eases stops, turns, and server corrections over 100 ms. Unknown destination chunks wait for confirmation. Territory, scores, and coordinates remain server-confirmed; other players still display their confirmed cells.
- Admission is capped at 1024 humans and 64 live countries for this demo, with bots yielding space as humans join. These are product limits, **not a measured server capacity**. Newcomers join an existing country once 64 exist; a country with no land and no live players is deleted, freeing its slot and name, while a landless country with live players survives. The lobby polls `/health` for the country roster and disables creation at 64 countries; it disables joining and reports `The world is offline` when the simulation is down. The simulation rechecks admission if the roster changes while joining. No rounds, victory rules, body-blocking, or minimap yet.
- Countries receive an unused color from a fixed 64-color palette, sampled for separation in OKLab with varied hues and lightness. Colors persist across restarts and become reusable only when their country is deleted. Names in the picker and scoreboard supplement colors; 64 colors alone cannot provide reliable identification for every viewer.
- Admission is open. `/session` issues player tokens without credentials, while the existing origin check, shared 120-session-per-minute budget, player cap, and store-write permissions remain enforced.
- Bots prefer nearby unclaimed or enemy land, avoid water, and stay near human activity. They use the same movement costs and authoritative store updates as people. This is a simple gameplay opponent, not a simulation of browser connections or network load.

The terminal logs cumulative inputs, ticks, committed flushes, changed chunk writes, chunk payload bytes (before subscriber fan-out), and the latest commit duration. The browser displays input-to-view time measured against its own change clock. These are diagnostic observations, not a throughput benchmark. Measure the complete workload on the VPS, including actual outgoing traffic and overlapping visible-chunk subscriptions, before drawing performance conclusions; FortiEDR makes this development machine unsuitable for that comparison.

## Checks

Build once with `bun run demo:game`, then stop it. Run:

```sh
bun run test:game
bunx biome check --write --error-on-warnings
bun run lint
```

`test:game` checks movement costs, visual sub-steps and corrections, stop/resume behavior, chunk boundaries, input expiry, map data, player-name validation, bot teams and replacement counts, and restart reconciliation. Its real-server smoke checks use isolated temporary databases and a development router mirroring Cloudflare. They exercise plaintext and IPv6/TLS origins (with a temporary trusted certificate generated by OpenSSL), and SDK clients to check open admission, named dots, subscriptions, write restrictions, disconnect cleanup, bot retirement and return, persistence, and manual reset.

The enclosure tests exhaust all 4 × 4 ownership masks against an independent boundary flood and check capture, defense, water, restart, and tick batching. Performance checks verify that ordinary extensions skip scans, local searches share a 1,024-cell budget per country, and large closures use one fallback scan, independently of publication. To print median step times as well:

```sh
GAME_BENCH=1 bun test examples/pixel-conquest/enclosure.perf.test.ts
```

Fixtures cover small and large U-shaped countries, a rotated U, a solid square, and a large loop closure. Timings exclude fixture setup and call-count instrumentation, use two warmups and seven samples, and measure simulation only. [PROFILING.md](./PROFILING.md) records the 20-country, 40-mover comparison; full-world scans have predictable linear work but their cost still grows with the number of affected countries.

For a manual browser check, open two windows, join different countries, move across the same area, release the keys, switch tabs while moving, disconnect one player, and restart the server. Test teammates by selecting the same existing country. Repeat at the public Cloudflare hostname before inviting everyone.

## Map source

`land.json` contains run-length encoded land spans derived from [Natural Earth's 1:110m land polygons](https://github.com/nvkelso/natural-earth-vector/blob/master/geojson/ne_110m_land.geojson), sampled at pixel centers with an equirectangular projection over the bounds above. The first and last columns are then cleared to water so the wrapped seam cannot connect land. Natural Earth data is [public domain](https://www.naturalearthdata.com/about/terms-of-use/). Land and water are terrain; player-created countries are independent of real political borders.
