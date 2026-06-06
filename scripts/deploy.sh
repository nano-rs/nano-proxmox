#!/usr/bin/env bash
#
# nano SIEM — in-container deploy.
#
# Runs INSIDE the Debian 12 LXC created by scripts/install.sh. Installs Docker,
# pulls the open-core stack from nano-rs/nano, adapts the compose for an
# unprivileged LXC, and brings it up. Safe to re-run.
#
# Not meant to be run directly on a Proxmox host — use scripts/install.sh.

set -o pipefail

NANO_BRANCH="${NANO_BRANCH:-main}"
DEPLOY_DIR="/opt/nano"

msg() { echo -e "\e[1;34m==>\e[0m $*"; }
ok()  { echo -e "\e[1;32m ✓\e[0m $*"; }
die() { echo -e "\e[1;31m ✗ $*\e[0m" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive

msg "Installing dependencies"
apt-get update -qq || die "apt-get update failed"
apt-get install -y -qq curl ca-certificates gnupg openssl >/dev/null || die "dependency install failed"
# yq applies the two unprivileged-LXC compose adaptations below.
curl -fsSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /usr/bin/yq || die "yq download failed"
chmod +x /usr/bin/yq
ok "Dependencies installed"

msg "Installing Docker"
mkdir -p /etc/docker
# journald log driver keeps the LXC disk from filling with json-file logs.
printf '{\n  "log-driver": "journald"\n}\n' >/etc/docker/daemon.json
curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || die "Docker install failed"
ok "Docker installed"

msg "Fetching nano (open-core) from nano-rs/nano"
mkdir -p "$DEPLOY_DIR"
# Pull only what the compose mounts: the opensource compose, the digest lockfile,
# and the ClickHouse / Vector / nginx config trees.
curl -fsSL "https://github.com/nano-rs/nano/archive/refs/heads/${NANO_BRANCH}.tar.gz" |
  tar -xz -C "$DEPLOY_DIR" --strip-components=1 \
    "nano-${NANO_BRANCH}/docker-compose.opensource.yml" \
    "nano-${NANO_BRANCH}/images.lock" \
    "nano-${NANO_BRANCH}/config/vector" \
    "nano-${NANO_BRANCH}/config/nginx/nginx.opensource.conf" \
    "nano-${NANO_BRANCH}/clickhouse/config.d" \
    "nano-${NANO_BRANCH}/clickhouse/users.d" || die "failed to fetch nano from nano-rs/nano"
mv "${DEPLOY_DIR}/docker-compose.opensource.yml" "${DEPLOY_DIR}/docker-compose.yml"
ok "Fetched nano"

msg "Adapting compose for unprivileged LXC"
cd "$DEPLOY_DIR" || die "cannot cd to $DEPLOY_DIR"
# 1) Drop dragonfly's `ulimits: memlock: -1`: unlimited memlock can't be set in
#    an unprivileged LXC (-> "error setting rlimit type 8: operation not
#    permitted", container never starts). Dragonfly runs fine without it.
yq -i 'del(.services.dragonfly.ulimits)' docker-compose.yml || die "yq memlock patch failed"
# 2) docker.dragonflydb.io intermittently times out; use the GHCR mirror.
yq -i '.services.dragonfly.image = "ghcr.io/dragonflydb/dragonfly:latest"' docker-compose.yml || die "yq image patch failed"
grep -q 'memlock' docker-compose.yml && die "compose adaptation failed (memlock still present)"
grep -q 'docker.dragonflydb.io' docker-compose.yml && die "compose adaptation failed (old dragonfly image)"
ok "Compose adapted"

msg "Generating secrets and environment"
# Persisted to .env so a restart reuses the SAME keys; rotating would orphan
# secret-at-rest data and log everyone out. Mirrors upstream .env.opensource.example.
LOCAL_IP="$(hostname -I | awk '{print $1}')"
cat >"${DEPLOY_DIR}/.env" <<EOF
NANO_VERSION=latest
BASE_URL=http://${LOCAL_IP}
NANOSIEM_DEV_MODE=true
POSTGRES_PASSWORD=$(openssl rand -hex 32)
CLICKHOUSE_PASSWORD=$(openssl rand -hex 32)
CLICKHOUSE_ADMIN_PASSWORD=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
NANOSIEM_ENCRYPTION_KEY=$(openssl rand -hex 32)
VECTOR_AUTH_TOKEN=$(openssl rand -hex 24)
RUST_LOG=info
EOF
chmod 600 "${DEPLOY_DIR}/.env"
ok "Environment generated"

msg "Pulling images (first run downloads ~12 images — be patient)"
# Serialize the pull to avoid overwhelming a small resolver; retry to ride out
# transient registry hiccups.
export COMPOSE_PARALLEL_LIMIT=1
pulled=0
for _ in 1 2 3 4 5; do
  if docker compose pull; then pulled=1; break; fi
  sleep 15
done
[ "$pulled" -eq 1 ] || die "image pull failed after 5 attempts (check network/DNS)"
ok "Images pulled"

# Supply-chain check: confirm first-party image digests against images.lock.
# Non-fatal — images.lock tracks the latest release, so a freshly-pushed :latest
# can briefly differ.
mismatch=0
while read -r repo expected; do
  [[ -z "$repo" || "$repo" == \#* ]] && continue
  actual="$(docker image inspect "${repo}:latest" \
    --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null |
    grep -F "${repo}@" | head -1)"
  [[ "${actual##*@}" != "$expected" ]] && mismatch=1
done <images.lock
if [ "$mismatch" -eq 0 ]; then
  ok "Image digests verified against images.lock"
else
  echo "    (note: image digest(s) differ from images.lock — tracking latest release)"
fi

msg "Starting nano SIEM stack"
docker compose up -d --remove-orphans || die "docker compose up failed"
ok "Stack started"

msg "Waiting for nano API (first boot runs ClickHouse migrations)"
healthy=0
for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:80/api/health >/dev/null 2>&1; then healthy=1; break; fi
  sleep 5
done
if [ "$healthy" -eq 1 ]; then
  ok "nano API is healthy"
else
  echo "    (API not healthy yet after 5 min — check 'docker compose logs' in ${DEPLOY_DIR})"
fi

# Surface the ingest token (also in .env) for log-shipper setup.
TOKEN="$(awk -F= '/^VECTOR_AUTH_TOKEN=/{print $2}' "${DEPLOY_DIR}/.env")"
{
  echo "nano SIEM ingest token (Authorization: Bearer <token>):"
  echo "  ${TOKEN}"
} >/root/nano.creds
ok "Deploy complete — ingest token saved to /root/nano.creds"
