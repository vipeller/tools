#!/usr/bin/env bash
#
# bootstrap.sh — one-liner installer for the OPC-Simulator aio-tools.
#
# Use this when you don't want to clone the whole OPC-Simulator
# repository (e.g. inside Azure Cloud Shell):
#
#   curl -sSL https://raw.githubusercontent.com/__GITHUB_ORG__/__GITHUB_REPO__/main/aio-tools/bootstrap.sh \
#        | bash
#   cd aio-tools
#
# What it does:
#   1. Downloads every script in this directory (common.sh,
#      onboard_lib.sh, the eight *.sh tools, and this README) into
#      ./aio-tools (override with TARGET_DIR).
#   2. Downloads the vendored umati helm chart .tgz into
#      ./aio-tools/charts/.
#   3. `chmod +x`'s the .sh files.
#   4. Prints a "next steps" hint.
#
# All assets are pulled by raw.githubusercontent.com from
# $GITHUB_ORG/$GITHUB_REPO @ $GITHUB_BRANCH. The defaults below use
# `vipeller` and `tools`.
# (You can also override at invocation time:
#    GITHUB_ORG=myorg GITHUB_REPO=myrepo curl -sSL .../bootstrap.sh | bash
# but the URL inside the curl pipe must already be valid, so the
# find/replace is the cleaner permanent fix.)

set -euo pipefail

GITHUB_ORG="${GITHUB_ORG:-vipeller}"
GITHUB_REPO="${GITHUB_REPO:-tools}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

# Where to drop the downloaded files.
TARGET_DIR="${TARGET_DIR:-${PWD}/aio-tools}"

# Path of this directory inside the repo. Adjust if you move the
# folder.
REPO_PATH="${REPO_PATH:-aio-tools}"

# -------- assets to pull --------
# Plain scripts + helpers (everything that lives directly under
# aio-tools/).
SCRIPTS=(
  "common.sh"
  "onboard_lib.sh"
  "discover_env.sh"
  "show_simulators.sh"
  "deploy_umati.sh"
  "deploy_opc_simulator.sh"
  "register_device.sh"
  "onboard_bulk.sh"
  "onboard_interactive.sh"
)

# Documentation that's nice-to-have but not strictly required.
DOCS=(
  "README.md"
  "charts/README.md"
)

# Vendored helm chart(s). Add new entries when we vendor more.
CHARTS=(
  "charts/umati-sample-server-1.0-alpha.1-microsoft.1.tgz"
)

# Plain resource files (configs, sample payloads, …) used by the
# scripts. Each entry's path is preserved relative to TARGET_DIR.
RESOURCES=(
  "resources/opc-simulator/simulator.toml"
)

# -------- logging (stderr only) --------
log()  { printf '[%s] [INFO] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
ok()   { printf '[%s] [ OK ] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '[%s] [WARN] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
err()  { printf '[%s] [ERR ] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# -------- helpers --------
raw_url() {
  # $1 = path within repo (e.g., aio-tools/foo.sh)
  printf 'https://raw.githubusercontent.com/%s/%s/%s/%s' \
    "$GITHUB_ORG" "$GITHUB_REPO" "$GITHUB_BRANCH" "$1"
}

fetch() {
  # $1 = remote path (relative to the repo root)
  # $2 = local destination path
  local remote="$1" local_path="$2"
  mkdir -p "$(dirname "$local_path")"
  if curl -fsSL "$(raw_url "$remote")" -o "$local_path"; then
    ok "Fetched $remote"
  else
    err "Failed to fetch $remote"
    return 1
  fi
}

# -------- tool checks --------
command -v curl >/dev/null || { err "'curl' is required"; exit 1; }

# -------- start --------
log "Bootstrap from GitHub: ${GITHUB_ORG}/${GITHUB_REPO}@${GITHUB_BRANCH}"
log "Target directory: $TARGET_DIR"
mkdir -p "$TARGET_DIR" "$TARGET_DIR/charts"

log "Downloading scripts…"
for f in "${SCRIPTS[@]}"; do
  fetch "${REPO_PATH}/${f}" "${TARGET_DIR}/${f}"
done

log "Downloading docs…"
for f in "${DOCS[@]}"; do
  # Docs are best-effort; a missing one shouldn't kill the bootstrap.
  fetch "${REPO_PATH}/${f}" "${TARGET_DIR}/${f}" || \
    warn "Skipping optional doc: $f"
done

log "Downloading vendored helm charts…"
for f in "${CHARTS[@]}"; do
  fetch "${REPO_PATH}/${f}" "${TARGET_DIR}/${f}"
done

log "Downloading resource files…"
for f in "${RESOURCES[@]}"; do
  fetch "${REPO_PATH}/${f}" "${TARGET_DIR}/${f}"
done

log "Marking scripts executable…"
chmod +x "${TARGET_DIR}"/*.sh || true
ok "Tools ready in ${TARGET_DIR}"

cat >&2 <<EOF

Next steps:
  cd "${TARGET_DIR}"

  # Discover your AIO environment and load the resulting env vars:
  eval "\$(./discover_env.sh <subscription-id> <resource-group>)"

  # Then deploy / register / onboard as needed. See README.md for the
  # full quick-start.
EOF
