# Cordon Off on FreeBSD with Cloudflare

Use one browser-facing origin, `https://game.example.com`. Replace that hostname, the VM IPv6 address, and `/home/freebsd` below with your values.

| Request | Destination |
| --- | --- |
| `/`, `/client.js`, `/style.css` | Cloudflare Workers Static Assets |
| `/session`, `/health` | Bun on the VM, HTTPS port 8444 |
| `/auth/ticket`, `/ws?ticket=...` | ZyncBase on the VM, HTTPS/WSS port 8443 |

Cloudflare terminates browser TLS and verifies a separate TLS connection to each VM listener. WebSockets bypass both the asset Worker and Bun. The Bun process remains the token issuer and authoritative simulation. Browser URLs stay relative, so no CORS configuration is needed.

## 1. Build the VM executable and the browser assets

On the FreeBSD VM, from the repository root:

```sh
bun install --frozen-lockfile
bun run --filter @zyncbase/client build
zig build -Doptimize=ReleaseFast
bun run demo:game:build
```

`demo:game:build` writes `examples/cordon-off/dist/` with the HTML, CSS, browser JavaScript, asset headers, and the static history viewer. At runtime the game adds generated round results under `dist/history/`, which are part of the deployed assets: keep that directory when rebuilding. Server code, signing secrets, certificates, and Cloudflare credentials are not part of the build.

## 2. Create the origin certificate

In your Cloudflare zone, open **SSL/TLS → Origin Server → Create Certificate**. Generate an **RSA** key and a certificate covering `game.example.com`. Save the certificate and private key in **PEM** format on the VM:

- `/home/freebsd/.config/cordon-off/origin.pem`
- `/home/freebsd/.config/cordon-off/origin.key`

Create the directory first and make it private:

```sh
mkdir -p /home/freebsd/.config/cordon-off
chmod 700 /home/freebsd/.config/cordon-off
```

After saving the files:

```sh
chmod 600 /home/freebsd/.config/cordon-off/origin.pem /home/freebsd/.config/cordon-off/origin.key
fetch -o /home/freebsd/.config/cordon-off/origin-ca.pem https://developers.cloudflare.com/ssl/static/origin_ca_rsa_root.pem
```

The CA file is public. It lets the simulation verify ZyncBase's certificate locally. If you chose an ECC certificate, download `origin_ca_ecc_root.pem` instead. Keep the private key on the VM and record the certificate's expiry; restart the game after replacing certificates. [Origin CA instructions](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/)

## 3. Keep the simulation's database traffic local

Add this line to **the VM's** `/etc/hosts` as root:

```text
::1 game.example.com
```

The simulator uses `wss://game.example.com:8443/ws`. This entry keeps it on loopback while preserving the hostname needed for certificate verification. It does not change Cloudflare DNS or your friends' DNS. Do not disable TLS verification.

## 4. Start the VM services

Create `/home/freebsd/.config/cordon-off/run.sh` with:

```sh
#!/bin/sh
set -eu
cd /home/freebsd/zyncbase
export GAME_ORIGIN=https://game.example.com
export GAME_HOST=::
export GAME_PORT=8444
export GAME_DB_PORT=8443
export GAME_DATA_DIR=/home/freebsd/zyncbase/data/cordon-off
export GAME_TLS_CERT=/home/freebsd/.config/cordon-off/origin.pem
export GAME_TLS_KEY=/home/freebsd/.config/cordon-off/origin.key
export NODE_EXTRA_CA_CERTS=/home/freebsd/.config/cordon-off/origin-ca.pem
# Optional: deploy changed assets (including round history) at boot.
# export CLOUDFLARE_API_TOKEN=...
# export CLOUDFLARE_ACCOUNT_ID=...
exec /home/freebsd/.bun/bin/bun examples/cordon-off/server.ts
```

If you enable the deploy, create the API token with only **Account → Workers Scripts → Edit** and keep it outside the checkout, for example in `/home/freebsd/.config/cordon-off/deploy.env` (mode `600`) sourced by `run.sh`. Deploys run at boot, in the background, and only when the asset content hash changed; a failure is logged, retried, and never stops the game.

Adjust the Bun executable path to the result of `command -v bun`. Then:

```sh
chmod 700 /home/freebsd/.config/cordon-off/run.sh
/home/freebsd/.config/cordon-off/run.sh
```

The launcher starts ZyncBase and the simulation together. Keep this running during the remaining setup. From a second VM session, check:

```sh
sockstat -6 -l
curl --cacert /home/freebsd/.config/cordon-off/origin-ca.pem https://game.example.com:8444/health
```

Expect listeners on 8443 and 8444 and a health response with `"ready":true`. These ports do not require root. If startup reports certificate errors, check the PEM pair, CA file and `/etc/hosts` entry.

Allow inbound **IPv6 TCP 8443 and 8444** in both the provider firewall and the VM firewall. The address must be a publicly routed IPv6 address, not `fe80::` or a private address. Port 8080 is only used by the local development router.

## 5. Point the public hostname at the VM

In **Cloudflare DNS**, create:

| Field | Value |
| --- | --- |
| Type | `AAAA` |
| Name | `game` |
| IPv6 address | Your VM's public IPv6, without brackets or a `/prefix` |
| Proxy status | **Proxied** (orange cloud) |
| TTL | Auto |

For this hostname, replace any old Tunnel CNAME and remove any A record pointing at the shared IPv4. Keep unrelated DNS records. Cloudflare prefers IPv4 when both origin address families are configured. Visitors can use Cloudflare over IPv4 or IPv6. [IPv6 compatibility](https://developers.cloudflare.com/network/ipv6-compatibility/)

In **SSL/TLS**, use **Full (strict)** for this hostname. If the zone has other origins with different requirements, use a hostname-specific Configuration Rule. Enable **Always Use HTTPS**, and ensure **Network → WebSockets** is enabled. [Full (strict)](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/), [WebSockets](https://developers.cloudflare.com/network/websockets/)

## 6. Select the backend ports with Origin Rules

Under **Rules**, create two **Origin Rules**, each with a **Destination port** override. They match the public hostname and path; leave Host, DNS and SNI overrides unset.

**Game login/health → 8444:**

```text
(http.host eq "game.example.com" and http.request.uri.path in {"/session" "/health"})
```

**Database ticket/WebSocket → 8443:**

```text
(http.host eq "game.example.com" and http.request.uri.path in {"/auth/ticket" "/ws"})
```

These overrides affect Cloudflare's connection to the VM. The browser keeps using port 443. Destination-port overrides are available on the Free plan. [Origin Rules](https://developers.cloudflare.com/rules/origin-rules/)

## 7. Publish the frontend from the VM

The game process publishes assets itself through the Cloudflare Workers API, so the VM needs neither wrangler nor Node (wrangler's `workerd` has no FreeBSD build). With `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` set in `run.sh`, every game start compares the content hash of `examples/cordon-off/dist/` with the last successful publish and uploads only when it changed. Round results land in `dist/history/`, so each archived round is published shortly after the game restarts. The log shows `Publishing N assets to Worker "..."` followed by `Cloudflare assets deployed.`; a failed publish is logged and retried every five minutes.

The Worker name and compatibility date are read from `examples/cordon-off/wrangler.jsonc` (`cordon-off` by default); change the name there if it is already in use in your account. [Workers Static Assets](https://developers.cloudflare.com/workers/static-assets/get-started/)

Do not publish the same Worker from another machine with `wrangler` unless it has the VM's `dist/history/`: an upload without those files removes published results from the edge.

## 8. Route assets to the Worker and let backend paths bypass it

Keep the proxied AAAA record from step 5. Configure **Workers Routes**, not a Worker Custom Domain that would replace the origin DNS record. Add these routes in the zone's Workers Routes settings:

| Route pattern | Worker |
| --- | --- |
| `game.example.com/*` | `cordon-off` |
| `game.example.com/session*` | None |
| `game.example.com/health*` | None |
| `game.example.com/auth/ticket*` | None |
| `game.example.com/ws*` | None |

The more specific routes with **no Worker** bypass Workers and reach the IPv6 origin through Cloudflare's normal proxy. Origin Rules then select 8443 or 8444. The trailing `*` is required to cover query strings, especially `/ws?ticket=...`. The checked-in configuration omits routes so publishes never touch this dashboard setup. [Route matching and exclusions](https://developers.cloudflare.com/workers/configuration/routing/routes/#matching-behavior)

## 9. Verify the public deployment

From your Mac (which should not have the VM's hosts-file override):

```sh
curl -I https://game.example.com/
curl https://game.example.com/health
```

Open `https://game.example.com`, enter player names and choose countries in two browser windows. Anyone with the URL can join while player slots remain. In browser developer tools, verify:

- `/session` succeeds on `game.example.com`.
- `/auth/ticket` succeeds on the same hostname.
- `wss://game.example.com/ws?ticket=...` upgrades with status **101**.
- Movement appears in the other window, releasing keys stops movement, and closing a player removes their dot.

If `/session` or `/auth/ticket` returns an asset/404, check the Worker exclusions. A 521/522 usually calls for checking IPv6 reachability, listeners and firewall rules; a 525/526 calls for checking origin TLS. Keep API paths out of any custom cache-everything rules; login/tickets are POST requests and must not be cached.

## 10. Keep it running and update it

After the foreground check, stop it with Ctrl+C. You can use FreeBSD's supervisor as the `freebsd` user:

```sh
daemon -R 1 -P /home/freebsd/.config/cordon-off/supervisor.pid -o /home/freebsd/.config/cordon-off/game.log /home/freebsd/.config/cordon-off/run.sh
```

The game exits and restarts by design at every round boundary (2 h) and after ten quiet minutes, recycling the simulation and ZyncBase processes; `daemon` must be allowed to restart it, and `-R 1` keeps that handoff quick. To stop the supervisor and game, run in `sh`:

```sh
kill -TERM "$(cat /home/freebsd/.config/cordon-off/supervisor.pid)"
```

This survives SSH logout; register the launcher with your existing FreeBSD startup service if it must also start after a VM reboot. [FreeBSD daemon](https://man.freebsd.org/cgi/man.cgi?query=daemon&sektion=8)

For backend updates, stop the game, update the checkout, rebuild the SDK and ReleaseFast executable, then restart. For frontend updates, run `bun run demo:game:build` on the VM and restart; the server deploys the changed assets (including any accumulated `dist/history/`) at boot. Copy `dist/history/` somewhere safe before wiping `dist/`, or published results are lost. The data directory persists across restarts; do not run two simulations against it. Use `bun run demo:game:start --reset` with the deployment environment only when you intentionally want to erase the game world; history is untouched. A release that changes the chunk owner format (schema 0.6.0) cannot restore a world written by an older build: upgrade straight after a round boundary or run once with `--reset`.
