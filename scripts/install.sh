#!/usr/bin/env bash
#
# nano SIEM — standalone Proxmox VE installer.
#
# Run this on a Proxmox VE host shell:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/nano-rs/nano-proxmox/main/scripts/install.sh)"
#
# It creates an unprivileged Debian 12 LXC (Docker-capable: nesting + keyctl),
# then deploys the nano open-core SIEM stack inside it via scripts/deploy.sh.
#
# Tunables (export before running):
#   CTID            container id           (default: next free id)
#   NANO_HOSTNAME   container hostname     (default: nano-siem)
#   CORES           vCPUs                  (default: 4)
#   RAM             memory MB              (default: 8192)
#   DISK            rootfs GB              (default: 40)
#   BRIDGE          network bridge        (default: vmbr0)
#   STORAGE         rootfs storage        (default: local-lvm)
#   TEMPLATE_STORAGE storage for template (default: local)
#   NANO_BRANCH     nano-rs/nano branch   (default: main)
#
# This installer does NOT depend on community-scripts/build.func.

set -o pipefail

REPO_RAW="https://raw.githubusercontent.com/nano-rs/nano-proxmox/main"

CTID="${CTID:-}"
NANO_HOSTNAME="${NANO_HOSTNAME:-nano-siem}"
CORES="${CORES:-4}"
RAM="${RAM:-8192}"
DISK="${DISK:-40}"
BRIDGE="${BRIDGE:-vmbr0}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
NANO_BRANCH="${NANO_BRANCH:-main}"

msg() { echo -e "\e[1;34m==>\e[0m $*"; }
ok()  { echo -e "\e[1;32m ✓\e[0m $*"; }
die() { echo -e "\e[1;31m ✗ $*\e[0m" >&2; exit 1; }

# --- preflight ---
command -v pct >/dev/null 2>&1 || die "This must be run on a Proxmox VE host (pct not found)."
[ "$(id -u)" -eq 0 ] || die "Run as root on the Proxmox VE host."

[ -n "$CTID" ] || CTID="$(pvesh get /cluster/nextid 2>/dev/null)" || die "could not determine next container id"
if pct status "$CTID" >/dev/null 2>&1; then die "CTID $CTID already exists — set CTID=<free id> and retry."; fi

# --- template ---
msg "Ensuring Debian 12 template is available"
TMPL="$(pveam available --section system 2>/dev/null | awk '/debian-12-standard/{print $2}' | sort -V | tail -1)"
[ -n "$TMPL" ] || die "no debian-12-standard template found in pveam catalog"
if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TMPL"; then
  pveam update >/dev/null 2>&1
  pveam download "$TEMPLATE_STORAGE" "$TMPL" || die "template download failed"
fi
ok "Template ready: $TMPL"

# --- create + start ---
msg "Creating LXC $CTID ($NANO_HOSTNAME): ${CORES} vCPU / ${RAM} MB / ${DISK} GB"
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TMPL}" \
  --hostname "$NANO_HOSTNAME" \
  --cores "$CORES" --memory "$RAM" --swap 512 \
  --rootfs "${STORAGE}:${DISK}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --ostype debian \
  --onboot 1 \
  --start 1 >/dev/null || die "pct create failed"
ok "Container created and started"

# --- wait for network ---
msg "Waiting for container network"
IP=""
for _ in $(seq 1 30); do
  IP="$(pct exec "$CTID" -- ip -4 addr show eth0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)"
  [ -n "$IP" ] && pct exec "$CTID" -- getent hosts github.com >/dev/null 2>&1 && break
  sleep 2
done
[ -n "$IP" ] || die "container did not get an IP (check bridge=${BRIDGE} / DHCP)"
ok "Container IP: $IP"

# --- deploy ---
msg "Deploying nano SIEM stack inside the container"
DEPLOY="$(curl -fsSL "${REPO_RAW}/scripts/deploy.sh")" || die "could not fetch deploy.sh"
pct exec "$CTID" -- env NANO_BRANCH="$NANO_BRANCH" bash -c "$DEPLOY" || die "in-container deploy failed"

echo
ok "nano SIEM is up!"
echo -e "   UI / API : \e[1mhttp://${IP}\e[0m   (first visit -> /setup to create the admin account)"
echo -e "   Ingest   : http://${IP}:8080  (Authorization: Bearer <token>)"
echo -e "   Token    : in the container at /root/nano.creds and /opt/nano/.env (VECTOR_AUTH_TOKEN)"
echo -e "   Shell    : pct enter ${CTID}"
