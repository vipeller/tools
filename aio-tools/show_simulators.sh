#!/usr/bin/env bash
#
# show_simulators.sh — list the OPC UA simulators currently running
# in the cluster.
#
# Heuristic: any Service whose `spec.ports[].port == 4840` is an OPC
# UA endpoint we care about. The script then tries to label each one
# as either "umati", "opc-simulator" or "unknown" by inspecting the
# `app.kubernetes.io/name` selector — the umati helm chart uses
# `umati-sample-server`, our chart uses `opc-simulator`.
#
# Usage:
#   ./show_simulators.sh                       # uses $NAMESPACE (default: azure-iot-operations)
#   ./show_simulators.sh -n my-ns
#   ./show_simulators.sh --all-namespaces
#
# The output is a fixed-column table on stdout; logs go to stderr.
# Suitable for piping into `awk` if you want just one column.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

NAMESPACE="${NAMESPACE:-azure-iot-operations}"
ALL_NS=0

usage() {
  cat <<'EOF' >&2
Usage: show_simulators.sh [options]

Options:
  -n, --namespace <ns>    Kubernetes namespace to list (default: $NAMESPACE
                          or azure-iot-operations).
  -A, --all-namespaces    Search every namespace.
  -h, --help              Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)      NAMESPACE="$2"; shift 2 ;;
    -A|--all-namespaces) ALL_NS=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) err "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

require_cmd kubectl jq

if [[ "$ALL_NS" -eq 1 ]]; then
  log "Listing OPC UA services (port 4840) across all namespaces…"
  RAW="$(kubectl get svc --all-namespaces -o json)"
else
  log "Listing OPC UA services (port 4840) in namespace '$NAMESPACE'…"
  RAW="$(kubectl get svc -n "$NAMESPACE" -o json)"
fi

# Filter & shape into tab-separated rows the consumer can easily eat.
# The label heuristic looks at:
#   1. metadata.labels["app.kubernetes.io/name"]  (helm convention)
#   2. spec.selector["app.kubernetes.io/name"]    (fallback)
# and maps known values to a canonical "kind".
ROWS="$(jq -r '
  .items[]
  | select(.spec.ports != null)
  | select(any(.spec.ports[]; .port == 4840))
  | . as $svc
  | (
      ($svc.metadata.labels["app.kubernetes.io/name"]
       // $svc.spec.selector["app.kubernetes.io/name"]
       // "unknown") as $appname
      | (if   $appname == "umati-sample-server" then "umati"
         elif $appname == "opc-simulator"      then "opc-simulator"
         else "unknown" end) as $kind
      | (($svc.metadata.labels["app.kubernetes.io/instance"]) // "") as $release
      | [
          $svc.metadata.namespace,
          $svc.metadata.name,
          $kind,
          $release,
          ($svc.spec.clusterIP // ""),
          ($svc.metadata.name + "." + $svc.metadata.namespace + ".svc.cluster.local:4840")
        ]
      | @tsv
    )
' <<<"$RAW")"

if [[ -z "$ROWS" ]]; then
  warn "No OPC UA services (port 4840) found."
  exit 0
fi

# Pretty print. The header row pretends to be tab-separated too so
# the same `column` invocation handles both halves.
{
  printf 'NAMESPACE\tNAME\tKIND\tRELEASE\tCLUSTER-IP\tDNS-ADDRESS\n'
  printf '%s\n' "$ROWS"
} | column -t -s $'\t'
