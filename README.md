# nano SIEM — Proxmox VE install script

One command stands up a complete, self-contained [nano](https://nano.rs) SIEM in a
Proxmox VE LXC container: ClickHouse + PostgreSQL + the nano API / search / jobs
services + a Vector ingestion pipeline + the web UI, all behind a single nginx
reverse proxy on port 80.

This is the **SIEM-only** deployment — just a running nano instance ready to receive
logs. It does **not** provision endpoints, agents, Sysmon, or any Windows/AD lab
plumbing. If you want a full lab (AD domain + Windows boxes + Sysmon + Vector agents
+ Conduit MITM), use [nano-ludus](https://github.com/nano-rs/nano-ludus) instead.

It follows the [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE)
convention, and runs the public open-core images from `ghcr.io/nano-rs` — no registry
auth, nothing to build.

## Install

Run this in the **Proxmox VE host** shell:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/nano-rs/nano-proxmox/main/ct/nano.sh)"
```

It creates a Debian 12 LXC, installs Docker, deploys the stack, and waits for the API
to come up (first boot runs the ClickHouse migrations, so give it a few minutes).

## Resources

The full open-core stack is real software — these are the defaults the script uses:

| Resource | Default | Notes |
|---|---|---|
| CPU | 4 cores | practical floor |
| RAM | 8 GB | ClickHouse alone is capped at 6 GB; **12–16 GB recommended** for real volume |
| Disk | 40 GB | log storage grows with ingestion + retention (90-day hot default) |

Override before/at creation, e.g.:

```bash
var_cpu=8 var_ram=16384 var_disk=100 bash -c "$(curl -fsSL https://raw.githubusercontent.com/nano-rs/nano-proxmox/main/ct/nano.sh)"
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
| HTTP (auto-detects format) | `http://<container-ip>:8080` (or `/ingest` via :80) |
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

## Testing before the repo is public

The one-line installer fetches `ct/nano.sh` and the config bundle from
`raw.githubusercontent.com`, which **only works once this repo is public**. While it's
private, validate on a Proxmox host one of two ways:

1. **Flip it public briefly** for the test, then run the one-liner above.
2. **Run it locally on the host** — clone with credentials and point the scripts at a
   local/branch copy:

   ```bash
   git clone https://github.com/nano-rs/nano-proxmox && cd nano-proxmox
   # ct/ still sources the upstream build.func (public); the installer can be
   # pointed at any branch:
   REPO_BRANCH=main bash ct/nano.sh
   ```

The installer honours `REPO_OWNER` and `REPO_BRANCH` env vars so you can test an
unmerged branch (e.g. `REPO_BRANCH=feat/foo`).

## Updating

Re-run the script on the Proxmox host and pick **Update** — it pulls the latest
`ghcr.io/nano-rs` images and recreates the stack (your data volumes and secrets in
`/opt/nano/.env` are preserved).

To pin a release instead of tracking `latest`, edit `NANOSIEM_VERSION` in
`/opt/nano/.env` and run `docker compose up -d` from `/opt/nano`.

## What's under the hood

Everything lives in `/opt/nano` inside the container:

```
/opt/nano/
  docker-compose.yml          # the SIEM-only stack
  .env                        # generated secrets + config (chmod 600)
  clickhouse/{config.d,users.d}
  config/vector/              # static Vector bundle (+ dynamic/ for api-delivered parsers)
  config/nginx/nginx.conf
```

The compose contract mirrors the validated open-core quickstart: a one-shot
`clickhouse-migrate` seeds the schema before the services boot, `nano-jobs` runs the
schedulers, and `nano-api` delivers per-source parser configs into the shared
`nano-vector-dynamic` volume that Vector reads from `/etc/vector/dynamic`.

## License

[Apache-2.0](LICENSE).

> Internal config keeps a `nanosiem` / `nanosiem_*` naming (it maps to the database,
> users, and env vars the images expect) — that's intentional, not a typo.
