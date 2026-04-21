# WordPress + Docker + Tailscale Serve

## Goal

Self-hosted WordPress in Docker, reachable on the tailnet with **HTTPS** and **MagicDNS**, using **Tailscale Serve** as TLS terminator and reverse proxy to Apache on port 80.

## Architecture pattern (official Tailscale sidecar)

- **Tailscale container** owns the network namespace (`hostname` = MagicDNS machine name).
- **WordPress** uses `network_mode: service:tailscale` so it shares that namespace with Tailscale.
- **Serve** proxies `https://…` (tailnet) → `http://127.0.0.1:80` (Apache). Tailscale docs require proxy backends to use `http://127.0.0.1`, not `localhost`.
- **MySQL** stays on the default Compose bridge; the Tailscale service must remain on that network so Docker DNS resolves `db` from the shared namespace.

## Docker Compose techniques

- **Ports**: Publish `${WEB_PORT}:80` on the **Tailscale** service (not WordPress), because only the namespace owner can publish ports when using `network_mode: service:…`.
- **`extra_hosts`**: Cannot be set on WordPress when it uses `network_mode: service:tailscale` (Docker error: conflicting options). Move `extra_hosts` to the **Tailscale** service so `/etc/hosts` applies to the shared netns.
- **Image pin**: `ghcr.io/tailscale/tailscale:v1.78.3+` — **v1.78.1** panics with `TS_SERVE_CONFIG` off-Kubernetes (`kubeClient` nil deref); fixed in **v1.78.3** (see tailscale/tailscale#14354).
- **`TS_USERSPACE: "false"`** with `/dev/net/tun` + `NET_ADMIN` / `SYS_MODULE` — default userspace networking can be awkward with Serve → loopback; kernel tun is more reliable per Tailscale Docker docs.

## Serve config (`TS_SERVE_CONFIG`)

JSON mounted as a **directory** (e.g. `./tailscale/serve` → `/config`):

- `TCP` `443` → `HTTPS: true`
- `Web` → `"${TS_CERT_DOMAIN}:443"` with `Handlers["/"].Proxy` = `http://127.0.0.1:80`
- `AllowFunnel` false unless you intentionally want Funnel + ACL work

`${TS_CERT_DOMAIN}` substitutes the node’s cert/MagicDNS hostname at runtime.

## Why HTTPS looked “wrong” sometimes

- **`https://machine.tailnet.ts.net`** — TLS terminates at **Serve** (Let’s Encrypt via Tailscale). Valid padlock when opened from a tailnet device.
- **`http://machine…` on port 80** — hits **Apache directly**, bypasses Serve → browser shows HTTP.
- **`http://localhost:WEB_PORT`** — Docker maps **only** host → container **80** → always **HTTP** (expected for local dev).

Mitigation: optional **wp-config** redirect for `Host` containing `.ts.net` when the request is not already HTTPS / forwarded as HTTPS, so `http://*.ts.net` bumps to `https://`.

## WordPress URL / env

- Compose can set **`WORDPRESS_PUBLIC_URL`** to `https://${TAILSCALE_MAGICDNS_HOSTNAME}.${TAILNET_DNS_SUFFIX}` using **`${VAR-default}`** (hyphen only): default when **unset**; if `.env` has **`WORDPRESS_PUBLIC_URL=`** (empty), stay empty for localhost-only (no `:-` or empty would always get default).
- **wp-config**: If `WORDPRESS_PUBLIC_URL` non-empty → `WP_HOME`, `WP_SITEURL`, `FORCE_SSL_ADMIN`; keep **`HTTP_X_FORWARDED_PROTO`** handling for Serve.
- **DB**: `home` / `siteurl` may still hold old `http://` values — use **`wp option update`** or search-replace; nuking `db_data` is optional and destructive.

## MagicDNS / certs

- Not “public DNS propagation”; tailnet updates are usually quick. Enable **MagicDNS** and tailnet **HTTPS** in admin if certs fail.
- **Logs**: `docker compose logs tailscale`, `docker compose exec tailscale tailscale serve status`.

## wp-cli auto-plugins (repo)

- **`bin/wpcli-entrypoint.sh`**: wait for DB + `wp core is-installed`, then install slugs from **`bin/wp-plugins.txt`** (idempotent), then `exec sh` or passed `wp` args.
- **`my-wpcli`** bind-mounts scripts; `depends_on` wordpress + db.

## References

- [Tailscale Docker guide](https://tailscale.com/blog/docker-tailscale-guide) (sidecar + `TS_SERVE_CONFIG`)
- [tailscale/tailscale#14354](https://github.com/tailscale/tailscale/issues/14354) (v1.78.1 container panic)