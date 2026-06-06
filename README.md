# nano SIEM — Proxmox VE helper script

One command stands up a complete, self-contained [nano](https://nano.rs) SIEM in a
Proxmox VE LXC container: ClickHouse + PostgreSQL + Dragonfly + the nano
API / search / jobs services + a Vector ingestion pipeline + the web UI, all behind
a single nginx reverse proxy on port 80.

This is the **SIEM-only** deployment — a running nano instance ready to receive
logs. It does **not** provision endpoints, agents, Sysmon, or any Windows/AD lab
plumbing. For a full lab (AD domain + Windows boxes + Sysmon + Vector agents +
Conduit MITM) use [nano-ludus](https://github.com/nano-rs/nano-ludus) instead.

It follows the [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE)
convention and runs the public open-core images from `ghcr.io/nano-rs` — no registry
auth, nothing to build.

## What this repo is

The three files here (`ct/nano.sh`, `install/nano-install.sh`, `json/nano.json`)
are nano's submission to the community-scripts catalog. They are designed to be run
by the community-scripts `build.func` (which fetches them from the
community-scripts repo, not this one), so the **install path is the
community-scripts one-liner below**, not a clone of this repo.

The compose file and the ClickHouse / Vector / nginx configs are **not** vendored
here — `nano-install.sh` pulls them straight from the upstream project repo
([`nano-rs/nano`](https://github.com/nano-rs/nano)), the same source nano's own
`install.sh` uses, so this deployment never drifts from upstream.

## Install

Run this in the **Proxmox VE host** shell (available once merged into
community-scripts/ProxmoxVE):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/nano.sh)"
```

It creates a Debian 12 LXC, installs Docker, pulls the open-core stack, and waits
for the API to come up (first boot runs the ClickHouse migrations, so give it a few
minutes).

> **Before it's merged:** new community-scripts apps land in the development repo
> [`ProxmoxVED`](https://github.com/community-scripts/ProxmoxVED) first. During
> review, test via the ProxmoxVED dev one-liner for this script.

## Resources

The full open-core stack is real software — these are the defaults the script uses:

| Resource | Default | Notes |
|---|---|---|
| CPU | 4 cores | practical floor |
| RAM | 8 GB | the stack fits in 8 GB (ClickHouse is capped at 2 GB in the compose); **12–16 GB recommended** for real volume — raise the container RAM and the ClickHouse memory limit together |
| Disk | 40 GB | log storage grows with ingestion + retention (90-day hot default) |

Override before/at creation, e.g.:

```bash
var_cpu=8 var_ram=16384 var_disk=100 bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/nano.sh)"
```

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
Authenticate with the bearer token generated at install time — it's saved inside the
container at `~/nano.creds` and in `/opt/nano/.env` (`VECTOR_AUTH_TOKEN`).

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

Re-run the script on the Proxmox host and pick **Update** — it pulls the latest
`ghcr.io/nano-rs` images and recreates the stack (your data volumes and secrets in
`/opt/nano/.env` are preserved).

To pin a release instead of tracking `latest`, edit `NANO_VERSION` in
`/opt/nano/.env` and run `docker compose up -d` from `/opt/nano`.

## What's under the hood

Everything lives in `/opt/nano` inside the container:

```
/opt/nano/
  docker-compose.yml          # upstream docker-compose.opensource.yml (renamed),
                              #   with two unprivileged-LXC adaptations applied
  images.lock                 # CI-vouched first-party image digests
  .env                        # generated secrets + config (chmod 600)
  clickhouse/{config.d,users.d}
  config/vector/              # static Vector bundle (+ dynamic/ for api-delivered parsers)
  config/nginx/nginx.opensource.conf
```

The install applies exactly two adaptations to the upstream compose, both required
to run in an **unprivileged** LXC:

1. **Drops `dragonfly.ulimits.memlock`** — unlimited memlock can't be set in an
   unprivileged LXC (`error setting rlimit type 8: operation not permitted`), which
   otherwise stops the container from starting. Dragonfly runs fine without it.
2. **Swaps the Dragonfly image to the GHCR mirror** — `docker.dragonflydb.io`
   intermittently times out; GHCR resolves reliably (NAN-1217).

The compose contract mirrors the validated open-core quickstart: a one-shot
`clickhouse-migrate` seeds the schema before the services boot, `nano-jobs` runs the
schedulers, and `nano-api` delivers per-source parser configs into the shared
`nano-vector-dynamic` volume that Vector reads from `/etc/vector/dynamic`.

## License

This repo is [Apache-2.0](LICENSE). The `ct/` and `install/` scripts carry an MIT
header per community-scripts convention (they're contributed to that catalog under
its MIT license). The nano application they install is AGPL-3.0.

> Internal config keeps a `nanosiem` / `nanosiem_*` naming (it maps to the database,
> users, and env vars the images expect) — that's intentional, not a typo.
