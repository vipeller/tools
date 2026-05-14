#!/usr/bin/env bash
#
# deploy_umati.sh — install the umati OPC UA sample-server helm chart
# into the cluster. One instance per release, idempotent: if the
# release already exists it is reported and left alone.
#
# Usage:
#   ./deploy_umati.sh [--release <name>] [--namespace <ns>] [--chart <path|url>]
#
# Required environment (or the corresponding flag):
#   SUBSCRIPTION_ID, RESOURCE_GROUP   — used for kubectl context wiring
#                                       and azure-cli login.
#
# Optional environment:
#   NAMESPACE              Kubernetes namespace (default: azure-iot-operations).
#   RELEASE                Helm release name (default: "umati").
#   HELM_CHART             Local chart path; if unset, the vendored
#                            charts/umati-sample-server-*.tgz is used
#                            (or downloaded from GITHUB_ORG/GITHUB_REPO).
#   CHART_URL              Override the default chart URL.
#   GITHUB_ORG, GITHUB_REPO, GITHUB_BRANCH
#                          Used to compose the fallback CHART_URL.
#   TIMEOUT_SECONDS        Helm wait budget (default: 300).
#
# Notes
#   * The umati chart's `simulations=N` value is intentionally NOT
#     surfaced — this script is a "one instance per release" tool, by
#     design. Want more? Run it again with a different --release.
#   * After successful install, the resulting OPC UA service is
#     reachable inside the cluster at:
#         opc.tcp://umati-<release>-000000.<namespace>.svc.cluster.local:4840
#     This is the address you'll feed to register_device.sh.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

DEFAULT_CHART_FILE="umati-sample-server-1.0-alpha.1-microsoft.1.tgz"
DEFAULT_CHART_LOCAL="${SCRIPT_DIR}/charts/${DEFAULT_CHART_FILE}"
# Repo placeholder — find/replace once the GitHub repo URL is final.
# The bootstrap.sh script keeps these variables in sync.
GITHUB_ORG="${GITHUB_ORG:-__GITHUB_ORG__}"
GITHUB_REPO="${GITHUB_REPO:-__GITHUB_REPO__}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
DEFAULT_CHART_URL="https://raw.githubusercontent.com/${GITHUB_ORG}/${GITHUB_REPO}/${GITHUB_BRANCH}/aio-tools/charts/${DEFAULT_CHART_FILE}"

RELEASE="${RELEASE:-umati}"
NAMESPACE="${NAMESPACE:-azure-iot-operations}"
HELM_CHART="${HELM_CHART:-}"
CHART_URL="${CHART_URL:-$DEFAULT_CHART_URL}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"

usage() {
  cat <<'EOF' >&2
Usage: deploy_umati.sh [options]

Options:
  -r, --release <name>    Helm release name (default: umati).
  -n, --namespace <ns>    Kubernetes namespace (default: azure-iot-operations).
  -c, --chart <path|url>  Chart .tgz path or URL (default: GitHub raw URL).
  -t, --timeout <secs>    Helm wait timeout (default: 300).
  -h, --help              Show this help.

Environment (lower precedence than flags):
  SUBSCRIPTION_ID, RESOURCE_GROUP   (required)
  NAMESPACE, RELEASE, HELM_CHART, CHART_URL, TIMEOUT_SECONDS
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--release)   RELEASE="$2"; shift 2 ;;
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -c|--chart)     HELM_CHART="$2"; shift 2 ;;
    -t|--timeout)   TIMEOUT_SECONDS="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) err "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

: "${SUBSCRIPTION_ID:?set SUBSCRIPTION_ID (run discover_env.sh first)}"
: "${RESOURCE_GROUP:?set RESOURCE_GROUP (run discover_env.sh first)}"

require_cmd az jq kubectl helm

azlogin "$SUBSCRIPTION_ID"
connect_kube "$RESOURCE_GROUP"

# -------- Resolve chart source --------
# Resolution order:
#   1. --chart / HELM_CHART                          (local file)
#   2. <script-dir>/charts/<vendored .tgz>           (local file, default)
#   3. CHART_URL (raw.githubusercontent.com fork)    (remote URL)
#
# (1) lets you point at any local tarball or chart directory; (2) is
# the common case once the repo is cloned (or bootstrap.sh has run);
# (3) is the cloud-shell / one-liner fallback used when this folder
# was downloaded without the charts/ subdirectory.
if [[ -n "$HELM_CHART" ]]; then
  [[ -e "$HELM_CHART" ]] || { err "Local chart not found: $HELM_CHART"; exit 1; }
  CHART_SRC="$HELM_CHART"
  log "Using chart (explicit): $CHART_SRC"
elif [[ -f "$DEFAULT_CHART_LOCAL" ]]; then
  CHART_SRC="$DEFAULT_CHART_LOCAL"
  log "Using vendored chart: $CHART_SRC"
else
  CHART_SRC="$CHART_URL"
  log "Using chart URL: $CHART_SRC"
  if [[ "$CHART_URL" == *__GITHUB_ORG__* || "$CHART_URL" == *__GITHUB_REPO__* ]]; then
    err "CHART_URL still contains the placeholder __GITHUB_ORG__/__GITHUB_REPO__."
    err "Either run from a clone (so charts/ is present) or set GITHUB_ORG/GITHUB_REPO,"
    err "or pass --chart <local-path>."
    exit 1
  fi
fi

# -------- Idempotency: is the release already deployed? --------
if helm status -n "$NAMESPACE" "$RELEASE" >/dev/null 2>&1; then
  ok "Helm release '$RELEASE' already exists in namespace '$NAMESPACE' — nothing to do."
  log "  Cluster service: umati-${RELEASE}-000000.${NAMESPACE}.svc.cluster.local:4840"
  exit 0
fi

# -------- Install --------
log "Installing helm release '$RELEASE' into namespace '$NAMESPACE'…"
helm upgrade -i "$RELEASE" "$CHART_SRC" \
  --namespace "$NAMESPACE" --create-namespace \
  --set "simulations=1" \
  --set "deployDefaultIssuerCA=false" \
  --wait --timeout "${TIMEOUT_SECONDS}s"
ok "Helm release applied"

# -------- Wait for readiness --------
# The chart's resources carry app.kubernetes.io/instance=<release>;
# we use that label to enumerate the deployments (most charts
# generate Deployments — fall back to a pod scan if not).
LABEL="app.kubernetes.io/instance=${RELEASE}"
log "Waiting for resources with label '$LABEL' in namespace '$NAMESPACE' to become Ready…"

DEPS="$(kubectl -n "$NAMESPACE" get deploy -l "$LABEL" -o name 2>/dev/null || true)"
if [[ -n "$DEPS" ]]; then
  while read -r d; do
    [[ -z "$d" ]] && continue
    log "  -> rollout $d"
    kubectl -n "$NAMESPACE" rollout status "$d" --timeout="${TIMEOUT_SECONDS}s"
  done <<< "$DEPS"
  ok "All deployments for $RELEASE are ready"
else
  warn "No Deployments found for label $LABEL — skipping rollout wait."
fi

ok "umati simulator '$RELEASE' is up."
log "Cluster service: umati-${RELEASE}-000000.${NAMESPACE}.svc.cluster.local:4840"
log "Next step: ./register_device.sh --service umati-${RELEASE}-000000 --asset-type 'nsu=http://opcfoundation.org/UA/MachineTool/;i=13'"
