#!/usr/bin/env bash
#
# register_device.sh — register an ADR (Microsoft.DeviceRegistry)
# namespaced device pointing at an OPC UA endpoint that lives inside
# the cluster (a Kubernetes Service, default port 4840). Once the device is
# created with `runAssetDiscovery: true`, the OPC UA connector picks
# it up and starts populating discoveredAssets in the same ADR
# namespace.
#
# Usage:
#   ./register_device.sh --service <svc-name> [--device <device-name>]
#                        [--asset-type <type>]... [--port 4840]
#                        [--endpoint-path <path>] [--namespace <k8s-ns>]
#                        [--security-mode <None|Sign|SignAndEncrypt>]
#                        [--security-policy <URI>]
#
# Required (env or flag):
#   SUBSCRIPTION_ID, RESOURCE_GROUP, INSTANCE_NAME, LOCATION,
#   ADR_NAMESPACE_NAME    — populated by `eval "$(./discover_env.sh ...)"`.
#   --service <name>      — the Kubernetes Service name of the OPC UA
#                            simulator. Use `./show_simulators.sh` to
#                            list candidates.
#
# Optional:
#   --device <name>       — ADR device name. Default: same as --service.
#   --asset-type <t>      — Repeatable. Each value is added to the
#                            additionalConfiguration.assetTypes array.
#                            Pass nothing to leave the array empty
#                            (i.e. discover everything).
#   --port <n>            — OPC UA port (default: 4840).
#   --endpoint-path <p>   — Optional URL path (default: empty). A leading
#                            slash is added if omitted.
#   --namespace <k8s-ns>  — Kubernetes namespace the service lives in.
#                            Default: $NAMESPACE or azure-iot-operations.
#   --endpoint-name <n>   — Key under endpoints.inbound (default: "default").
#   --security-mode <m>   — None, Sign or SignAndEncrypt (default: None).
#   --security-policy <u> — OPC UA security policy URI (default:
#                            http://opcfoundation.org/UA/SecurityPolicy#None).
#                            No policy or simulator auto-detection is performed.
#
# Idempotency: if the ADR device already exists, the script reports
# it and does nothing.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

SERVICE=""
DEVICE=""
PORT="4840"
ENDPOINT_PATH=""
NS_K8S="${NAMESPACE:-azure-iot-operations}"
ENDPOINT_NAME="default"
SECURITY_MODE="None"
SECURITY_POLICY="http://opcfoundation.org/UA/SecurityPolicy#None"
ASSET_TYPES=()

usage() {
  cat <<'EOF' >&2
Usage: register_device.sh --service <svc> [options]

Required:
  -s, --service <name>      Kubernetes Service name of the OPC UA endpoint.

Options:
  -d, --device <name>       ADR device name (default: same as --service).
  -a, --asset-type <type>   AssetType string (repeatable). Empty by default.
  -p, --port <n>            OPC UA port (default: 4840).
      --endpoint-path <p>   URL path (default: empty; leading slash optional).
  -n, --namespace <ns>      K8s namespace (default: $NAMESPACE or
                            azure-iot-operations).
      --endpoint-name <n>   endpoints.inbound key (default: "default").
      --security-mode <m>   None, Sign or SignAndEncrypt (default: None).
      --security-policy <URI>
                            OPC UA security policy URI (default:
                            http://opcfoundation.org/UA/SecurityPolicy#None).
  -h, --help                Show this help.

Required environment (run `eval "$(./discover_env.sh ...)"` first):
  SUBSCRIPTION_ID, RESOURCE_GROUP, INSTANCE_NAME, LOCATION,
  ADR_NAMESPACE_NAME

Examples:
  # Register our OPC simulator, no asset-type filter (discover everything):
  ./register_device.sh --service opc-simulator

  # Register umati with a MachineTool asset-type filter:
  ./register_device.sh --service umati-umati-000000 \
      --asset-type 'nsu=http://opcfoundation.org/UA/MachineTool/;i=13'

  # Register the pump server (requires signing/encryption) with a PumpType filter:
  ./register_device.sh --service pump-pump-device-integration-server \
      --port 62542 --endpoint-path /PumpDeviceIntegrationServer \
      --security-mode SignAndEncrypt \
      --security-policy 'http://opcfoundation.org/UA/SecurityPolicy#Basic256Sha256' \
      --asset-type 'nsu=http://opcfoundation.org/UA/Pumps/;i=1052'
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--service)        SERVICE="$2"; shift 2 ;;
    -d|--device)         DEVICE="$2"; shift 2 ;;
    -a|--asset-type)     ASSET_TYPES+=("$2"); shift 2 ;;
    -p|--port)           PORT="$2"; shift 2 ;;
       --endpoint-path)  ENDPOINT_PATH="$2"; shift 2 ;;
    -n|--namespace)      NS_K8S="$2"; shift 2 ;;
       --endpoint-name)  ENDPOINT_NAME="$2"; shift 2 ;;
       --security-mode)  SECURITY_MODE="$2"; shift 2 ;;
       --security-policy) SECURITY_POLICY="$2"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *) err "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

[[ -n "$SERVICE" ]] || { err "Service name required (--service)"; usage; exit 2; }
case "$SECURITY_MODE" in
  None|Sign|SignAndEncrypt) ;;
  *) err "Invalid security mode '$SECURITY_MODE' (expected None, Sign or SignAndEncrypt)"; usage; exit 2 ;;
esac
DEVICE="${DEVICE:-$SERVICE}"

: "${SUBSCRIPTION_ID:?set SUBSCRIPTION_ID (run discover_env.sh first)}"
: "${RESOURCE_GROUP:?set RESOURCE_GROUP (run discover_env.sh first)}"
: "${INSTANCE_NAME:?set INSTANCE_NAME (run discover_env.sh first)}"
: "${LOCATION:?set LOCATION (run discover_env.sh first)}"
: "${ADR_NAMESPACE_NAME:?set ADR_NAMESPACE_NAME (run discover_env.sh first)}"

require_cmd az jq

azlogin "$SUBSCRIPTION_ID"
validate_adr "$SUBSCRIPTION_ID" "$RESOURCE_GROUP" "$ADR_NAMESPACE_NAME" >/dev/null

AIO_JSON="$(get_aio_json "$RESOURCE_GROUP" "$INSTANCE_NAME")"
EXT_LOC="$(printf '%s' "$AIO_JSON" | extract_extended_location)"
ok "AIO extendedLocation: $EXT_LOC"

ADR_RESOURCE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.DeviceRegistry/namespaces/${ADR_NAMESPACE_NAME}"
DEVICE_RESOURCE="${ADR_RESOURCE}/devices/${DEVICE}"

# -------- Idempotency check --------
log "Checking if device '$DEVICE' exists…"
EXIST_JSON="$(az rest --method get \
    --url "${DEVICE_RESOURCE}?api-version=${API}" \
    --headers "Content-Type=application/json" \
    --only-show-errors 2>/dev/null || true)"
EXIST_ID="$(jq -r '.id // empty' <<<"${EXIST_JSON:-}")"
if [[ -n "$EXIST_ID" ]]; then
  ok "Device $EXIST_ID already exists — nothing to do."
  exit 0
fi

# -------- Build the OPC UA endpoint address --------
if [[ -n "$ENDPOINT_PATH" ]]; then
  ENDPOINT_PATH="/${ENDPOINT_PATH#/}"
fi
ADDRESS="opc.tcp://${SERVICE}.${NS_K8S}.svc.cluster.local:${PORT}${ENDPOINT_PATH}"
log "Endpoint address: $ADDRESS"

# -------- Compose request body --------
# additionalConfiguration is sent as a STRINGIFIED json (per the
# Microsoft.DeviceRegistry contract). The shape below matches the
# 2025-10-01 API surface for the Microsoft.OpcUa endpoint type:
#
#   security: { securityMode, securityPolicy,
#               autoAcceptUntrustedServerCertificates }
#   runAssetDiscovery: bool
#   assetTypes: [ string ]
#
# When --asset-type is not given the assetTypes array is empty,
# which the connector treats as "discover everything I can".
if [[ ${#ASSET_TYPES[@]} -gt 0 ]]; then
  ATS_JSON="$(printf '%s\n' "${ASSET_TYPES[@]}" | jq -R . | jq -s .)"
else
  ATS_JSON='[]'
fi
log "AssetTypes: $ATS_JSON"

BODY="$(jq -n \
  --argjson ext  "$EXT_LOC" \
  --arg     loc  "$LOCATION" \
  --arg     addr "$ADDRESS" \
  --arg     ep   "$ENDPOINT_NAME" \
  --arg     dev  "$DEVICE" \
  --arg     security_mode   "$SECURITY_MODE" \
  --arg     security_policy "$SECURITY_POLICY" \
  --argjson ats  "$ATS_JSON" '
{
  extendedLocation: $ext,
  location: $loc,
  properties: {
    enabled: true,
    externalDeviceId: $dev,
    attributes: { deviceType: "LDS" },
    endpoints: {
      inbound: (
        { ($ep): {
            address: $addr,
            endpointType: "Microsoft.OpcUa",
            authentication: { method: "Anonymous" },
            additionalConfiguration: ({
              security: {
                securityMode: $security_mode,
                securityPolicy: $security_policy,
                autoAcceptUntrustedServerCertificates: true
              },
              runAssetDiscovery: true,
              assetTypes: $ats
            } | tostring)
          }
        }
      )
    }
  }
}')"

# -------- Create --------
log "Creating ADR namespaced device '$DEVICE'…"
NEW_DEVICE="$(az rest --method put \
  --url "${DEVICE_RESOURCE}?api-version=${API}" \
  --headers "Content-Type=application/json" \
  --body "$BODY" --only-show-errors)"
ok "ADR device created: $(jq -r '.id' <<<"$NEW_DEVICE")"
log "Discovered assets will start appearing under:"
log "  ${ADR_RESOURCE}/discoveredAssets"
log "Use ./onboard_bulk.sh or ./onboard_interactive.sh to onboard them."
