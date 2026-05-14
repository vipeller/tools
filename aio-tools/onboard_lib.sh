# shellcheck shell=bash
#
# onboard_lib.sh — shared helpers for the two onboard_* scripts.
#
# Splitting this out keeps the bulk and interactive flows from
# duplicating the (long) "fetch discovered asset → strip
# unsupported fields → PUT under /assets" payload-shaping code.
#
# Functions defined:
#   * onboard_init           — common environment validation, az
#                                login, ADR + AIO probes; populates
#                                the globals ADR_RESOURCE, ADR_URL,
#                                EXT_LOC.
#   * list_discovered_names  — echo (newline-separated) the .name
#                                fields of every discoveredAsset
#                                whose name starts with $1 (empty
#                                = match all). Suitable for
#                                `mapfile -t array < <(...)`.
#   * onboard_one_asset      — given an ADR discoveredAsset name,
#                                fetch its details and PUT the
#                                onboarded asset. Returns 0/!=0.
#
# IMPORTANT: this file expects common.sh to already be sourced.

# Globals filled by onboard_init.
ADR_RESOURCE=""
ADR_URL=""
EXT_LOC=""

onboard_init() {
  : "${SUBSCRIPTION_ID:?set SUBSCRIPTION_ID (run discover_env.sh first)}"
  : "${RESOURCE_GROUP:?set RESOURCE_GROUP (run discover_env.sh first)}"
  : "${INSTANCE_NAME:?set INSTANCE_NAME (run discover_env.sh first)}"
  : "${LOCATION:?set LOCATION (run discover_env.sh first)}"
  : "${ADR_NAMESPACE_NAME:?set ADR_NAMESPACE_NAME (run discover_env.sh first)}"

  require_cmd az jq
  ensure_iotops_ext
  azlogin "$SUBSCRIPTION_ID"

  ADR_RESOURCE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.DeviceRegistry/namespaces/${ADR_NAMESPACE_NAME}"
  ADR_URL="https://management.azure.com${ADR_RESOURCE}"

  # Sanity probe.
  az rest --method get --url "${ADR_URL}?api-version=${API}" \
      --only-show-errors >/dev/null
  ok "ADR namespace found: $ADR_NAMESPACE_NAME"

  local aio_json
  aio_json="$(get_aio_json "$RESOURCE_GROUP" "$INSTANCE_NAME")"
  EXT_LOC="$(printf '%s' "$aio_json" | extract_extended_location)"
  ok "extendedLocation: $EXT_LOC"
}

# list_discovered_names <prefix>
# Prints (newline-separated) discovered asset names. Empty prefix
# matches all. Always exits 0; the caller decides what "no results"
# means.
list_discovered_names() {
  local prefix="${1-}"
  local json
  json="$(az rest --method get \
    --url "${ADR_URL}/discoveredAssets?api-version=${API}" \
    --only-show-errors)"
  jq -r --arg p "$prefix" '
    .value[]?
    | select((.name // "") | startswith($p))
    | .name
  ' <<<"$json"
}

# onboard_one_asset <discoveredAssetName>
# Fetches the discovered asset, builds the onboarding payload (same
# field-mapping as the upstream onboard_all_discovered.sh), and
# PUTs it as a regular Asset under the same ADR namespace.
onboard_one_asset() {
  local asset_name="$1"
  [[ -n "$asset_name" ]] || { err "onboard_one_asset: name required"; return 2; }

  log "Fetching discovered asset details for '$asset_name'…"
  local dasset
  dasset="$(az rest --method get \
    --url "${ADR_URL}/discoveredAssets/${asset_name}?api-version=${API}" \
    --only-show-errors)" || {
      err "Failed to GET discoveredAsset '$asset_name'"; return 1;
    }

  # Strip server-managed fields the PUT contract rejects.
  local props display_name desc_val
  props="$(jq 'del(.properties.lastUpdatedOn)' <<<"$dasset" | jq -c '.properties')"
  display_name="$(jq -r '.properties.displayName // .properties.model // "Asset"' <<<"$dasset")"
  desc_val="$(jq -r '.properties.description // ""' <<<"$dasset")"

  log "Building onboarding payload for '$asset_name'…"
  local body
  body="$(jq -c -n \
    --argjson ext "$EXT_LOC" \
    --arg     loc "$LOCATION" \
    --arg     dn  "$display_name" \
    --arg     desc "$desc_val" \
    --argjson props "$props" '
    {
      extendedLocation: $ext,
      location: $loc,
      properties: {
        externalAssetId: $props.externalAssetId,
        enabled: true,
        displayName: $dn,
        description: $desc,
        manufacturer: $props.manufacturer,
        model: $props.model,
        productCode: $props.productCode,
        hardwareRevision: $props.hardwareRevision,
        softwareRevision: $props.softwareRevision,
        documentationUri: $props.documentationUri,
        serialNumber: $props.serialNumber,
        defaultDatasetsDestinations: $props.defaultDatasetsDestinations,
        defaultEventsDestinations: $props.defaultEventsDestinations,
        defaultStreamsDestinations: $props.defaultStreamsDestinations,
        defaultDatasetsConfiguration: $props.defaultDatasetsConfiguration,
        defaultEventsConfiguration: $props.defaultEventsConfiguration,
        defaultStreamsConfiguration: $props.defaultStreamsConfiguration,
        defaultManagementGroupsConfiguration: $props.defaultManagementGroupsConfiguration,
        deviceRef: $props.deviceRef,
        discoveredAssetRefs: [$props.discoveryId],
        assetTypeRefs: $props.assetTypeRefs,
        datasets: $props.datasets,
        eventGroups: $props.eventGroups,
        streams: $props.streams,
        managementGroups: $props.managementGroups
      }
    }')"

  # PUT idempotently — same URL serves create and update.
  local put_url="${ADR_URL}/assets/${asset_name}?api-version=${API}"
  log "Onboarding asset '$asset_name'…"
  if ! az rest --method put --url "$put_url" --body "$body" \
        --only-show-errors >/dev/null; then
    err "PUT failed for asset '$asset_name'"
    return 1
  fi
  ok "Asset '$asset_name' onboarded."
}

# already_onboarded <assetName>
# Returns 0 if /assets/<name> already exists, !=0 otherwise.
already_onboarded() {
  local asset_name="$1"
  local url="${ADR_URL}/assets/${asset_name}?api-version=${API}"
  local json id
  json="$(az rest --method get --url "$url" --only-show-errors 2>/dev/null || true)"
  id="$(jq -r '.id // empty' <<<"${json:-}")"
  [[ -n "$id" ]]
}
