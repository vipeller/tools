#!/usr/bin/env bash
#
# show_simulators.sh — list the OPC UA simulators currently running
# in the cluster.
#
# Heuristic: any Service whose `spec.ports[].port == 4840` is an OPC
# UA endpoint we care about. Also include pump services identified by
# `app.kubernetes.io/name` or `app` labels/selectors with the value
# `pump-device-integration-server`. Pump ports prefer the named
# `opc-tcp` service port, falling back to 62542 or 4840.
# Kinds are "umati", "opc-simulator", "pump" or "unknown"; DNS addresses
# use the service port and include /PumpDeviceIntegrationServer for pumps.
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

Lists services on port 4840 and known pump-device-integration-server services.
Pump DNS addresses use the OPC UA service port and /PumpDeviceIntegrationServer.
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
  log "Listing OPC UA services (port 4840 or known pump services) across all namespaces…"
  RAW="$(kubectl get svc --all-namespaces -o json)"
else
  log "Listing OPC UA services (port 4840 or known pump services) in namespace '$NAMESPACE'…"
  RAW="$(kubectl get svc -n "$NAMESPACE" -o json)"
fi

# Filter & shape into tab-separated rows the consumer can easily eat.
# Recognize pump names in either labels or selectors, including `app`.
# Other kinds retain the standard name-label/selector precedence.
# Choose one OPC UA service port, not targetPort or unrelated ports,
# so multi-port services produce a single row.
ROWS="$(jq -r '
  .items[]
  | select(.spec.ports != null)
  | . as $svc
  | ([
      $svc.metadata.labels["app.kubernetes.io/name"],
      $svc.spec.selector["app.kubernetes.io/name"],
      $svc.metadata.labels.app,
      $svc.spec.selector.app
    ] | any(. == "pump-device-integration-server")) as $pump
  | select($pump or any($svc.spec.ports[]; .port == 4840))
  | (
      ($svc.metadata.labels["app.kubernetes.io/name"]
       // $svc.spec.selector["app.kubernetes.io/name"]
       // $svc.metadata.labels.app
       // $svc.spec.selector.app
       // "unknown") as $appname
      | (if   $pump                              then "pump"
         elif $appname == "umati-sample-server" then "umati"
         elif $appname == "opc-simulator"      then "opc-simulator"
         else "unknown" end) as $kind
      | (if $pump then
           ([$svc.spec.ports[] | select(.name == "opc-tcp")][0]
            // [$svc.spec.ports[] | select(.port == 62542)][0]
            // [$svc.spec.ports[] | select(.port == 4840)][0])
         else
           [$svc.spec.ports[] | select(.port == 4840)][0]
         end) as $opcport
      | select($opcport != null)
      | ($svc.metadata.labels["app.kubernetes.io/instance"]
         // $svc.spec.selector["app.kubernetes.io/instance"] // "") as $release
      | [
          $svc.metadata.namespace,
          $svc.metadata.name,
          $kind,
          $release,
          ($svc.spec.clusterIP // ""),
          ($svc.metadata.name + "." + $svc.metadata.namespace
           + ".svc.cluster.local:" + ($opcport.port | tostring)
           + (if $pump then "/PumpDeviceIntegrationServer" else "" end))
        ]
      | @tsv
    )
' <<<"$RAW")"

if [[ -z "$ROWS" ]]; then
  warn "No OPC UA services (port 4840 or known pump services) found."
  exit 0
fi

# Pretty print. The header row pretends to be tab-separated too so
# the same `column` invocation handles both halves.
{
  printf 'NAMESPACE\tNAME\tKIND\tRELEASE\tCLUSTER-IP\tDNS-ADDRESS\n'
  printf '%s\n' "$ROWS"
} | column -t -s $'\t'
