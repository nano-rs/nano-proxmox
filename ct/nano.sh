#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2024-2026 nano-rs
# Author: nano-rs (https://nano.rs)
# License: Apache-2.0
# Source: https://github.com/nano-rs/nano-proxmox

APP="nano"
var_tags="${var_tags:-siem;security;logs}"
# The full open-core stack runs ClickHouse + PostgreSQL + Dragonfly + four Rust
# services + Vector + nginx. ClickHouse alone is capped at 6 GB, so 8 GB / 4 CPU
# is the practical floor; 12-16 GB is recommended for real ingestion volume.
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-8192}"
var_disk="${var_disk:-40}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
# Unprivileged + nesting (build.func enables nesting/keyctl) is enough to run
# Docker inside the LXC.
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -d /opt/nano ]]; then
    msg_error "No ${APP} installation found in /opt/nano!"
    exit
  fi
  msg_info "Updating ${APP} (pulling latest images)"
  cd /opt/nano || exit
  export COMPOSE_PARALLEL_LIMIT=1
  $STD docker compose pull
  $STD docker compose up -d --remove-orphans
  msg_ok "Updated ${APP}"
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access the nano UI / API at:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}${CL}"
echo -e "${INFO}${YW} First visit redirects to /setup to create the admin account.${CL}"
echo -e "${INFO}${YW} The log-ingestion token is saved in the container at ~/nano.creds${CL}"
