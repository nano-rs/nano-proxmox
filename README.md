# nano SIEM — Proxmox VE installer

One command stands up a complete, self-contained [nano](https://nano.rs) SIEM in a
Proxmox VE LXC container: ClickHouse + PostgreSQL + Dragonfly + the nano
API / search / jobs services + a Vector ingestion pipeline + the web UI, all behind
a single nginx reverse proxy on port 80.

This is the **SIEM-only** deployment — a running nano instance ready to receive
logs. It does **not** provision endpoints, agents, Sysmon, or any Windows/AD lab
plumbing. For a full lab (AD + Windows + Sysmon + Vector agents + Conduit MITM) use
[nano-ludus](https://github.com/nano-rs/nano-ludus) instead.

It runs the public open-core images from `ghcr.io/nano-rs` — no registry auth,
nothing to build.

## Install

Run this in the **Proxmox VE host** shell:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/nano-rs/nano-proxmox/main/scripts/install.sh)"
```

It creates an unprivileged Debian 12 LXC (Docker-capable: nesting + keyctl),
installs Docker, pulls the open-core stack, and waits for the API to come up (first
boot runs the ClickHouse migrations, so give it a few minutes).

Tunables — export before running:

```bash
CORES=8 RAM=16384 DISK=100 \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/nano-rs/nano-proxmox/main/scripts/install.sh)"
```

| Var | Default | |
|---|---|---|
| `CTID` | next free id | container id |
| `NANO_HOSTNAME` | `nano-siem` | hostname |
| `CORES` | `4` | vCPUs |
| `RAM` | `8192` | memory (MB) |
| `DISK` | `40` | rootfs (GB) |
| `BRIDGE` | `vmbr0` | network bridge |
| `STORAGE` | `local-lvm` | rootfs storage |
| `TEMPLATE_STORAGE` | `local` | storage for the LXC template |
| `NANO_BRANCH` | `main` | `nano-rs/nano` branch to deploy |

## Tested on

Validated end-to-end (install → all services healthy → log ingest lands in ClickHouse)
on:

| | |
|---|---|
| Proxmox VE | **9.2.3** (kernel `7.0.2-6-pve`) |
| Architecture | amd64 |
| Container | unprivileged Debian 12 LXC, nesting + keyctl |
| Storage / bridge | `local-lvm` / `vmbr0` (defaults) |
| Date | 2026-06-06 |

Other configurations (PVE 8.x, arm64, non-default storage/bridge) are parameterized
and expected to work but have not yet been exercised.

## Resources

The full open-core stack is real software — these are the defaults:

| Resource | Default | Notes |
|---|---|---|
| CPU | 4 cores | practical floor |
| RAM | 8 GB | the stack fits in 8 GB (ClickHouse capped at 2 GB in the compose); **12–16 GB recommended** for real volume — raise `RAM` and the ClickHouse memory limit together |
| Disk | 40 GB | log storage grows with ingestion + retention (90-day hot default) |

## Access

| Service | URL |
|---|---|
| **nano UI / API** | `http://<container-ip>` (nginx :80) |

On first visit you're redirected to **`/setup`** to create the admin account — it's
open until claimed, so do it promptly.

> Over plain `http://<ip>` some browser security gates apply (e.g. `crypto.randomUUID`
> needs a secure context). For anything beyond a quick trial, front the container with
> **HTTPS**.

## Sending logs

The Vector pipeline accepts logs on several protocols (published on the container IP).
Authenticate with the bearer token generated at install time — saved inside the
container at `/root/nano.creds` and in `/opt/nano/.env` (`VECTOR_AUTH_TOKEN`).

| Protocol | Endpoint |
|---|---|
| HTTP (auto-detects format) | `http://<container-ip>:8080` |
| Splunk HEC | `http://<container-ip>:8088` |
| Vector native protocol | `<container-ip>:6000` |
| OpenTelemetry | `:4317` (gRPC) / `:4318` (HTTP) |
| Fluent Forward | `:24224` |

```bash
curl -H "Authorization: Bearer <token>" \
     -H "Content-Type: application/json" \
     -d '{"message":"hello from my host","source_type":"test"}' \
     http://<container-ip>:8080
```

Events are searchable immediately as raw `message` + `source_type`. To extract
structured fields (`process_name`, `src_ip`, …) deploy the relevant parsers from the
in-app **Parser Repository** — open-core ships with none deployed.

## Updating

Inside the container (`pct enter <ctid>`):

```bash
cd /opt/nano && docker compose pull && docker compose up -d --remove-orphans
```

Your data volumes and the secrets in `/opt/nano/.env` are preserved. To pin a release
instead of tracking `latest`, edit `NANO_VERSION` in `/opt/nano/.env` first.

## What's under the hood

The installer is two small scripts:

- **`scripts/install.sh`** — runs on the Proxmox host: creates the LXC and kicks off
  the deploy. No dependency on community-scripts `build.func`.
- **`scripts/deploy.sh`** — runs inside the container: installs Docker, pulls the
  compose + ClickHouse/Vector/nginx configs straight from
  [`nano-rs/nano`](https://github.com/nano-rs/nano) (so this never drifts from
  upstream), and brings the stack up.

Everything lives in `/opt/nano` inside the container:

```
/opt/nano/
  docker-compose.yml          # upstream docker-compose.opensource.yml (renamed),
                              #   with two unprivileged-LXC adaptations applied
  images.lock                 # CI-vouched first-party image digests
  .env                        # generated secrets + config (chmod 600)
  clickhouse/{config.d,users.d}
  config/vector/
  config/nginx/nginx.opensource.conf
```

The deploy applies exactly two adaptations to the upstream compose, both required to
run in an **unprivileged** LXC:

1. **Drops `dragonfly.ulimits.memlock`** — unlimited memlock can't be set in an
   unprivileged LXC (`error setting rlimit type 8: operation not permitted`), which
   otherwise stops the container from starting. Dragonfly runs fine without it.
2. **Swaps the Dragonfly image to the GHCR mirror** — `docker.dragonflydb.io`
   intermittently times out; GHCR resolves reliably (NAN-1217).

## community-scripts catalog

The `ct/`, `install/`, and `json/` files are a [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE)
submission, kept ready for the day nano meets that catalog's new-script eligibility
bar (≥6 months old, 600+ stars, published release tarballs). Until then, use the
standalone installer above.

## License

This repo is [Apache-2.0](LICENSE). The `ct/` and `install/` scripts carry an MIT
header per community-scripts convention. The nano application it installs is AGPL-3.0.

> Internal config keeps a `nanosiem` / `nanosiem_*` naming (it maps to the database,
> users, and env vars the images expect) — that's intentional, not a typo.
