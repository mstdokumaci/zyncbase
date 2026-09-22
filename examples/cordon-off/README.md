# Cordon Off

A small multiplayer territory game using ZyncBase's real presence → store path. The browser sends direction input; a Bun simulation determines movement and ownership. Browsers receive territory and player coordinates through two independently sized chunk-table subscriptions.

## Rounds and history

Rounds end on absolute two-hour boundaries at even UTC hours. A round is archived when it produced claimed land: the winner, final standings, and a full-map PNG are written to `dist/history/`, then the whole stack (simulation and ZyncBase) restarts. A human disconnect does not immediately remove claimed territory; if the scheduled boundary occurs before an idle reset, the round is archived, while a quiet-world reset fires first and discards the round without history. Boot wipes the world and starts the next round, so process memory is recycled every round. A boundary on a never-played (empty) world writes nothing either. Round numbers advance only when a round is archived, and the last **20** rounds are kept.

During play the header shows a countdown. At the deadline each client navigates to `/history.html?round=N`; the viewer polls until the round's data has been deployed. Results are Cloudflare Worker static assets, so they load while the simulation restarts. When `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` are set, boot publishes the assets through the Cloudflare Workers API only when their content hash changed; the game never waits on a publish and a failed publish retries in the background. Wrangler and Node are not needed on the VM (wrangler's `workerd` has no FreeBSD build); the Worker name and compatibility date are read from `wrangler.jsonc`.

## Run locally

From the repository root, with Zig 0.16, Bun, OpenSSL, and the repository's native build prerequisites installed:

```sh
bun install
bun run demo:game
```

Open **http://localhost:8080**. Enter a player name (1–16 characters), then choose an existing country to team up or select **Create a country** while slots remain. Anyone with the URL can join; no invite code or account is needed. The picker previews the selected country's color and territory; the slot count refreshes every five seconds. Each human's name appears above their dot: yours is bold gold, others are muted off-white, with dark outlines for readability. Bots have no name labels. WASD, arrow keys, or the on-screen buttons move in four directions. Releasing keys or switching away stops input. The world wraps horizontally: walking off one side continues on the other, so the Pacific seam connects Russia and Canada. Players can pass through one another; spawning avoids occupied cells.

Each spawn point has its own bot country, named after where it spawns. The point's first human is joined by **two bots**; a second or third human leaves one bot, and a fourth retires them. A point without humans has no bots. Squares are bots; circles are people. Retiring a bot does not erase its land: territory stays with its country and can be conquered normally. Bots resume after a restart.

The launch command builds the SDK and a ReleaseFast ZyncBase executable, then starts both the database and game. For subsequent starts without rebuilding:

```sh
bun run demo:game:dev
```

Stop with Ctrl+C. Territory is stored in `data/cordon-off/`; generated history and assets live in `examples/cordon-off/dist/history/`. The world resets on its own every round; to force a fresh world at the next start, run `bun run demo:game:dev --reset`. The reset removes game chunks and countries and starts a fresh round. It does not touch other ZyncBase data directories or the history archive. Schema 0.7.0 splits the former `chunks` table into `country_chunks` and `user_chunks`; a data directory written by an earlier version must be discarded (or started once with `--reset`) before 0.7.0 can run.

## Cloudflare and VPS

Follow [the FreeBSD + Cloudflare setup](./DEPLOYMENT.md). One public origin serves browser assets from Cloudflare, sends `/session` and `/health` to Bun, and sends `/auth/ticket` and `/ws` directly to ZyncBase over IPv6/TLS. The production Bun process runs the simulation and token issuer; it does not relay database connections or serve browser files.

Build an uploadable browser directory with `bun run demo:game:build`. Its output is `examples/cordon-off/dist/`. Start the VM processes with `bun run demo:game:start`. The development command `demo:game:dev` supplies local routing on port 8080 and is not used on the VM.

| Variable | Default | Purpose |
| --- | --- | --- |
| `GAME_ORIGIN` | `http://localhost:8080` | Exact browser origin; use `https://game.example.com` in deployment. |
| `GAME_HOST` | `127.0.0.1` | Bind address for both VM listeners. Use `::` for IPv6 deployment. |
| `GAME_PORT` | `8081` | Bun login/health port. Deployment example: `8444`. |
| `GAME_DB_PORT` | `3001` | ZyncBase ticket/WebSocket port. Deployment example: `8443`. |
| `GAME_TLS_CERT`, `GAME_TLS_KEY` | Unset | PEM certificate and key for both listeners. Set both to enable TLS. |
| `NODE_EXTRA_CA_CERTS` | Unset | CA PEM trusted by the simulation's HTTPS/WSS client. |
| `GAME_DATA_DIR` | `<repo>/data/cordon-off` | Persistent game data. Run one simulation against a data directory. |
| `GAME_SERVER_BIN` | `<repo>/zig-out/bin/zyncbase` | Prebuilt ZyncBase executable. |
| `GAME_ROUND_MS` | `7200000` | Round boundary period; the default aligns with even UTC hours. |
| `GAME_IDLE_WIPE_MS` | `600000` | Restart a quiet world after this long with no players; `0` disables. |
| `GAME_ASSETS_DIR` | `examples/cordon-off/dist` | Browser assets plus generated history; the Worker publish directory. |
| `GAME_DEPLOY` | Unset | `0` disables the hash-gated Worker publish. |
| `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` | Unset | Set both to deploy changed assets at boot (see below). |
| `GAME_DEV_PORT` | `8080` | Development router port, used only by `demo:game:dev`. |

With TLS, the simulation connects to the hostname from `GAME_ORIGIN` on `GAME_DB_PORT`. Map that hostname to `::1` in the VM's `/etc/hosts` so simulation traffic stays local while certificate verification stays enabled. Without TLS it connects to `127.0.0.1`.

Changing the hostname requires restarting with the matching origin. Player tokens last 24 hours; a server restart or expired token requires rejoining. The round rollover restarts the server by design, so players rejoin through the lobby for the next round.

Once history lives in the Worker assets, the VM is the only publish source: a `wrangler deploy` from your Mac uploads a `dist/` without `history/` and drops published results from the edge. Build on the VM (or copy `dist/` over intact) and restart; the server publishes on the next boot when the asset hash changed.

## Prototype choices

- One 2000 × 1000 world, cropped to longitude −135°…180°, latitude −60°…85°, with **661,453 land pixels**. The world wraps horizontally; the first and last map columns are water, so no owned wall can cross the seam and enclosure scans stay planar. New players and their bots spread over nine named spawn points in three waves: **Warsaw, Zurich and Moscow** first, **Ulaanbaatar, Riyadh and Bangui** once those are all in use, and **Yulara, Brasília and Denver** once the first six points each hold four humans. Per-player spacing is unchanged. Joiners of an existing country spawn on its territory when it has room, otherwise beside a live teammate.
- Ownership and player coordinates live in two tables with independent grids. `country_chunks` tiles the map in 50 × 25-cell chunks (40 × 40); each row's `color_indexes` is a run-length encoded palette bitmap (0 unowned, 1–64 = `COUNTRY_COLORS[code - 1]`), published only when a claim changes it. Chunks that are entirely water have no row and no subscription, because they can never change owner. `user_chunks` tiles the map in 200 × 100-cell chunks (10 × 10); each row's `coordinates` is a JSON list of slim player dots (`player_id`, `x`, `y` only) for the live players inside it, published when one of them moves. Clients subscribe to both grids around the viewport, paint color indexes straight from the shared palette, and join dots to the `users` roster (`name`, `country_id`, `is_bot`, last-known `last_x`/`last_y`, keyed by the session identity) client-side at render. Water remains unowned. Arrays are not used as positional store data.
- `RULES` in `shared.ts` sets the 50 ms tick and own/neutral/enemy movement costs of 1/2/4 ticks. Entering or leaving water adds 6 ticks. All movers paint first, then affected countries resolve enclosures in first-change order. Safe gates skip changes that cannot enclose anything; bounded local searches handle small cases, with at most one whole-country scan per country per tick as fallback. Captures can add other affected countries to that pass, but no country runs twice. Enclosures capture land and let defenders reclaim severed extensions. Water remains unowned and gaps through water keep an area open. A closure breached later in the same tick does not capture its interior.
- Flushes wait for **committed** acknowledgment. Ticks pause while a commit is pending, so slow storage slows the game without accumulating writes or producing catch-up bursts. A write or database connection failure stops the game; restart restores committed territory and reconciles dots. A commit acknowledgment does not measure browser delivery.
- Country creation sends `countryName` once to `/session`, which returns the assigned `country_id`. Presence identifies countries only by `country_id`. A newly allocated country with no land or players is removed after ten seconds if its creator never connects.
- Input heartbeats renew a two-second movement lease; silent players stop, and their dots expire after ten seconds. Normal disconnects remove dots sooner. Rejoining preserves country territory, not the old player position.
- Player names are validated on admission, normalized, and fixed for that connection. Names are separate from country membership and need not be unique. Departed players keep their roster row for ten seconds so a same-id reconnect resumes in place; dots vanish immediately and never pin countries. Labels stay within 120 screen pixels, and your dot and name draw last to remain visible in a crowd.
- Players cannot write country chunks, user chunks, countries, or shared presence. Browser code does not subscribe to presence. ZyncBase currently uses the same read gate for joining a presence namespace and subscribing to it, so authorized players could inspect input presence with a custom client; there is no hidden game information there.
- The browser draws at up to 30 FPS and animates the local dot and camera through fractional positions using elapsed time and the existing terrain costs. It anticipates at most one unconfirmed cell, waits there if updates stall, and eases stops, turns, and server corrections over 100 ms. Unknown destination chunks wait for confirmation. Territory, scores, and coordinates remain server-confirmed; other players still display their confirmed cells.
- Admission is capped at 1024 humans and 64 live countries for this demo, with bots yielding space as humans join. These are product limits, **not a measured server capacity**. Newcomers join an existing country once 64 exist; a country with no land and no live players is deleted, freeing its slot and name, while a landless country with live players survives. The lobby polls `/health` for the country roster and disables creation at 64 countries; it disables joining and reports `The world is offline` when the simulation is down. The simulation rechecks admission if the roster changes while joining. No rounds, victory rules, body-blocking, or minimap yet.
- Countries receive an unused color from a fixed 64-color palette, sampled for separation in OKLab with varied hues and lightness. Colors persist across restarts and become reusable only when their country is deleted. Names in the picker and scoreboard supplement colors; 64 colors alone cannot provide reliable identification for every viewer.
- Admission is open. `/session` issues player tokens without credentials, while the existing origin check, shared 120-session-per-minute budget, player cap, and store-write permissions remain enforced.
- Rounds are wall-clock anchored: boundaries are absolute multiples of `GAME_ROUND_MS` (2 h → even UTC hours), so restarts resume the same deadline. A round is archived when it has claimed land, even if every human left before the boundary, provided the boundary arrives before an idle reset; at most 20 results are kept, and every round end or idle reset exits the process so the supervisor starts a clean simulation and ZyncBase pair. `dist/history/` is the archive and the Worker publish source; the view is `history.html`, a static page that polls for results while they publish.
- Bots prefer nearby unclaimed or enemy land, avoid water, and stay near human activity. They use the same movement costs and authoritative store updates as people. This is a simple gameplay opponent, not a simulation of browser connections or network load.

The terminal logs cumulative inputs, ticks, committed flushes, country-chunk and user-chunk writes and bytes (before subscriber fan-out), and the latest commit duration. The browser displays input-to-view time measured against its own change clock. These are diagnostic observations, not a throughput benchmark. Measure the complete workload on the VPS, including actual outgoing traffic and overlapping visible-chunk subscriptions, before drawing performance conclusions; FortiEDR makes this development machine unsuitable for that comparison.

## Checks

Build once with `bun run demo:game`, then stop it. Run:

```sh
bun run test:game
bunx biome check --write --error-on-warnings
bun run lint
```

`test:game` checks movement costs, visual sub-steps and corrections, stop/resume behavior, chunk boundaries, input expiry, map data, player-name validation, bot teams and replacement counts, restart reconciliation, round-boundary math, snapshot PNG encoding, archive pruning, and the deploy hash gate. Its real-server smoke checks use isolated temporary databases and a development router mirroring Cloudflare. They exercise plaintext and IPv6/TLS origins (with a temporary trusted certificate generated by OpenSSL), and SDK clients to check open admission, named dots, subscriptions, write restrictions, disconnect cleanup, bot retirement and return, persistence, and manual reset. The plaintext run also drives the round lifecycle: a scheduled boundary with a human archives a round and wipes on boot, a played round still archives after its humans leave, an idle reset restarts without history or a new number, and a quiet boundary writes nothing.

The enclosure tests exhaust all 4 × 4 ownership masks against an independent boundary flood and check capture, defense, water, restart, and tick batching. Performance checks verify that ordinary extensions skip scans, local searches share a 1,024-cell budget per country, and large closures use one fallback scan, independently of publication. To print median step times as well:

```sh
GAME_BENCH=1 bun test examples/cordon-off/enclosure.perf.test.ts
```

Fixtures cover small and large U-shaped countries, a rotated U, a solid square, and a large loop closure. Timings exclude fixture setup and call-count instrumentation, use two warmups and seven samples, and measure simulation only. [PROFILING.md](./PROFILING.md) records the 20-country, 40-mover comparison; full-world scans have predictable linear work but their cost still grows with the number of affected countries.

For a manual browser check, open two windows, join different countries, move across the same area, release the keys, switch tabs while moving, disconnect one player, and restart the server. Test teammates by selecting the same existing country. Repeat at the public Cloudflare hostname before inviting everyone.

## Map source

`land.json` contains run-length encoded land spans derived from [Natural Earth's 1:110m land polygons](https://github.com/nvkelso/natural-earth-vector/blob/master/geojson/ne_110m_land.geojson), sampled at pixel centers with an equirectangular projection over the bounds above. The first and last columns are then cleared to water so the wrapped seam cannot connect land. Natural Earth data is [public domain](https://www.naturalearthdata.com/about/terms-of-use/). Land and water are terrain; player-created countries are independent of real political borders.
