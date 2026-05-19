# shellcheck shell=bash
#
# common.sh — shared helpers for the OPC-Simulator AIO tools.
#
# This file is sourced by every script in this directory. It is not
# meant to be executed directly. It defines:
#
#   * Pretty stderr logging (`log`, `ok`, `warn`, `err`).
#   * Tool-existence checks (`require_cmd`).
#   * Default API version for the Microsoft.DeviceRegistry / IoT
#     Operations REST surface used here.
#   * Helpers that the deploy / register / onboard scripts repeat:
#       - `azlogin`           — make sure `az` has a current session
#                                and the requested subscription.
#       - `connect_kube`      — best-effort kubectl context wiring
#                                (single AKS in the RG → grab creds;
#                                otherwise just warn).
#       - `validate_adr`      — probe Microsoft.DeviceRegistry namespace.
#       - `get_aio_json` /    — pull AIO instance JSON and the
#         `get_extended_loc`    extendedLocation block from it.
#       - `ensure_iotops_ext` — install/refresh the azure-iot-ops CLI
#                                extension (used by the onboard flow,
#                                which calls `az iot ops show`).
#
# All log lines go to stderr so callers can safely capture stdout
# (e.g. when a script's last line is meant to be a value to eval).

# -------- logging (stderr only) --------
log()  { printf '[%s] [INFO] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
ok()   { printf '[%s] [ OK ] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '[%s] [WARN] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
err()  { printf '[%s] [ERR ] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# -------- defaults --------
# Single source of truth for the management-plane API version. Bump
# here to roll every script forward at once.
API="${API:-2025-10-01}"

# -------- tool checks --------
require_cmd() {
  local missing=0
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      err "Required tool not found on PATH: $c"
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || exit 1
}

# -------- Azure login & subscription --------
# Idempotent: if az already has a session, just `account set`.
azlogin() {
  local sub="${1:-${SUBSCRIPTION_ID:-}}"
  [[ -n "$sub" ]] || { err "azlogin: SUBSCRIPTION_ID is required"; return 1; }
  if ! az account show >/dev/null 2>&1; then
    log "Azure login required…"
    az login --only-show-errors >/dev/null
    ok "Logged in"
  fi
  az account set --subscription "$sub"
  ok "Using subscription $sub"
}

# -------- kubectl context --------
# Best-effort: if the RG has exactly one AKS cluster, fetch creds.
# For Arc-enabled K8s, the user is expected to have run
# `az connectedk8s proxy ...` (or otherwise wired kubectl) before
# invoking the deploy scripts.
connect_kube() {
  local rg="${1:-${RESOURCE_GROUP:-}}"
  [[ -n "$rg" ]] || { err "connect_kube: RESOURCE_GROUP is required"; return 1; }

  log "Checking for AKS clusters in resource group '$rg'…"
  local aks_list aks_count aks_name
  aks_list="$(az aks list -g "$rg" -o json 2>/dev/null || echo '[]')"
  aks_count="$(jq 'length' <<<"$aks_list")"
  if [[ "$aks_count" -eq 1 ]]; then
    aks_name="$(jq -r '.[0].name' <<<"$aks_list")"
    log "Found single AKS cluster: $aks_name — fetching credentials…"
    if az aks get-credentials -g "$rg" -n "$aks_name" --overwrite-existing \
        >/dev/null 2>&1; then
      ok "kubectl context configured for AKS cluster '$aks_name'"
    else
      warn "Failed to get AKS credentials automatically. Configure kubectl manually."
    fi
  elif [[ "$aks_count" -gt 1 ]]; then
    warn "Multiple AKS clusters found in RG '$rg'."
    warn "Run: az aks get-credentials -g \"$rg\" -n <cluster-name>"
  else
    warn "No AKS clusters found in RG '$rg' (Arc-enabled cluster? Make sure"
    warn "your kubectl context already points at it)."
  fi
}

# -------- ADR namespace probe --------
# Echoes the ADR namespace resource id on success; exits non-zero
# (and logs an error) if the namespace doesn't exist.
validate_adr() {
  local sub="${1:-${SUBSCRIPTION_ID:-}}"
  local rg="${2:-${RESOURCE_GROUP:-}}"
  local ns="${3:-${ADR_NAMESPACE_NAME:-}}"
  : "${sub:?validate_adr: subscription id is required}"
  : "${rg:?validate_adr: resource group is required}"
  : "${ns:?validate_adr: ADR namespace name is required}"

  local url json id
  url="https://management.azure.com/subscriptions/${sub}/resourceGroups/${rg}/providers/Microsoft.DeviceRegistry/namespaces/${ns}?api-version=${API}"
  json="$(az rest --method get --url "$url" --only-show-errors 2>/dev/null || true)"
  id="$(jq -r '.id // empty' <<<"${json:-}")"
  if [[ -z "$id" ]]; then
    err "ADR namespace not found: $ns (RG: $rg)"
    return 1
  fi
  ok "ADR namespace id: $id"
  printf '%s' "$id"
}

# -------- AIO instance JSON --------
# Pulls the AIO instance JSON via `az iot ops show`. Echoes JSON on
# stdout; logs progress to stderr.
get_aio_json() {
  local rg="${1:-${RESOURCE_GROUP:-}}"
  local name="${2:-${INSTANCE_NAME:-}}"
  : "${rg:?get_aio_json: resource group is required}"
  : "${name:?get_aio_json: AIO instance name is required}"

  # Prevent az CLI from prompting to install the azure-iot-ops extension
  # interactively (the prompt is invisible in non-interactive/piped contexts
  # and causes the script to hang).
  az config set extension.use_dynamic_install=yes_without_prompt 2>/dev/null || true

  local json aio_name
  json="$(az iot ops show -g "$rg" -n "$name" --only-show-errors -o json \
            2>/dev/null || true)"
  aio_name="$(jq -r '.name // empty' <<<"${json:-}")"
  if [[ -z "$aio_name" || "$aio_name" == "null" ]]; then
    err "AIO instance not found: $name"
    return 1
  fi
  printf '%s' "$json"
}

# Compact `{name, type}` extendedLocation block, ready to embed in
# ADR / asset payloads. Reads AIO JSON from stdin.
extract_extended_location() {
  local ext_name ext_type
  local json
  json="$(cat)"
  ext_name="$(jq -r '.extendedLocation.name // empty' <<<"$json")"
  ext_type="$(jq -r '.extendedLocation.type // "CustomLocation"' <<<"$json")"
  [[ -n "$ext_name" ]] || { err "AIO instance missing extendedLocation.name"; return 1; }
  jq -c -n --arg n "$ext_name" --arg t "$ext_type" '{name:$n,type:$t}'
}

# -------- IoT Ops CLI extension --------
ensure_iotops_ext() {
  az config set extension.use_dynamic_install=yes_without_prompt >/dev/null
  if ! az extension show -n azure-iot-ops >/dev/null 2>&1; then
    log "Installing Azure IoT Operations CLI extension…"
    az extension add -n azure-iot-ops -y --only-show-errors >/dev/null
  else
    az extension update -n azure-iot-ops --only-show-errors >/dev/null || true
  fi
  ok "IoT Ops CLI extension ready"
}
