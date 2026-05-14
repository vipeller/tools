# aio-tools — OPC UA simulator helpers for Azure IoT Operations

A small set of bash scripts that automate the common steps for
running and testing OPC UA simulators on top of an existing
[Azure IoT Operations](https://learn.microsoft.com/azure/iot-operations)
(AIO) deployment:

1. **Discover** the AIO instance / ADR namespace in a given
   subscription + resource group.
2. **Deploy** one (or both) of the supported OPC UA simulators
   into the AIO Kubernetes cluster:
   * **opc-simulator** — the simulator that lives in this repository.
   * **umati** — the [umati sample server](https://github.com/umati/Sample-Server),
     packaged as the `umati-sample-server` helm chart. We ship a
     **vendored fork** of the chart under `charts/` (the only change
     vs. upstream is an `organizations: Microsoft` entry added to
     the cert-manager Certificate's subject — required by our
     corporate OPC UA application-instance certificate policy).
     See [`charts/README.md`](charts/README.md).
3. **Register** each simulator as an ADR namespaced device so that
   the OPC UA connector starts running asset discovery against it.
4. **Onboard** the resulting `discoveredAssets` into regular ADR
   `assets` — either in bulk (run-and-forget, with a target count
   and a timeout) or interactively (one y/n prompt per asset).

The scripts are intentionally small, well-commented, and mostly
self-contained. They share a `common.sh` (logging, az login,
kubectl wiring, ADR/AIO probes) and an `onboard_lib.sh` (the
discoveredAsset → asset PUT contract).

> Heritage: this directory is the OPC-Simulator-specific evolution
> of the upstream toolset at
> [`vipeller/aio_gp_test/aio-tools`](https://github.com/vipeller/aio_gp_test/tree/main/aio-tools).
> Only the pieces relevant to OPC UA simulation are kept; everything
> Fabric / dataflow / connector-template-related has been dropped.

---

## Prerequisites

You need an existing AIO instance reachable by your CLI. The scripts
themselves require:

| Tool       | Notes                                                     |
| ---------- | --------------------------------------------------------- |
| `bash` 4.x | Uses arrays, `mapfile`, `${var,,}` lower-casing.          |
| `az`       | Azure CLI; signed in to a subscription that owns the AIO. |
| `jq`       | JSON munging — every script.                              |
| `kubectl`  | Used by the deploy / show scripts.                        |
| `helm`     | Used by the two deploy scripts.                           |
| `column`   | Used by `show_simulators.sh` for table layout.            |

The first time `onboard_*` runs, it ensures the `azure-iot-ops`
Azure CLI extension is present (and refreshes it on subsequent
runs).

For Arc-enabled K8s clusters, configure your kubectl context first
(e.g. `az connectedk8s proxy -g $RESOURCE_GROUP -n <cluster>`). For
single-AKS resource groups the deploy scripts will run
`az aks get-credentials` for you.

---

## Quick start

### Option A — One-liner (no clone needed)

Good for Azure Cloud Shell or a fresh laptop. Pulls every script and
the vendored helm chart from the repo:

```bash
curl -sSL https://raw.githubusercontent.com/__GITHUB_ORG__/__GITHUB_REPO__/main/aio-tools/bootstrap.sh \
     | bash
cd aio-tools
```

> The `__GITHUB_ORG__` / `__GITHUB_REPO__` strings are intentional
> placeholders — replace them with the real repo coordinates once
> the project is published. (They appear in `bootstrap.sh` and
> `deploy_umati.sh`.)

### Option B — Clone the repo

```bash
git clone <repo-url>
cd <repo>/aio-tools
```

### Then in either case:

```bash
# 1. Discover the AIO environment and load the resulting variables.
eval "$(./discover_env.sh <subscription-id> <resource-group>)"

# 2. (Optional) build & push your own opc-simulator image — see
#    OPC-Simulator/deploy/scripts/build-and-push.sh. Capture the
#    final stdout line for the next step. If you skip this, the
#    default vipeller.azurecr.io/opc-simulator:0.1.0 image is used.
IMAGE_REF=$(../deploy/scripts/build-and-push.sh -a myacr | tail -n1)

# 3. Deploy whichever simulator(s) you want.
#    --image is optional; omit it to use the default ACR image.
./deploy_opc_simulator.sh --image "$IMAGE_REF"
./deploy_umati.sh

# 4. See what's actually running on port 4840 in the cluster.
./show_simulators.sh

# 5. Register an ADR device per simulator. The umati sample server
#    needs an asset-type filter; ours is happy without one.
./register_device.sh --service opc-simulator
./register_device.sh --service umati-umati-000000 \
    --asset-type 'nsu=http://opcfoundation.org/UA/MachineTool/;i=13'

# 6a. Bulk onboard: wait up to 10 min for any 5 discovered assets.
./onboard_bulk.sh --count 5 --timeout 600

# 6b. ...or interactive: get y/n prompts as new assets show up.
./onboard_interactive.sh --show-details
```

---

## Script reference

Every script accepts `-h` / `--help` for inline help. The required
environment variables (`SUBSCRIPTION_ID`, `RESOURCE_GROUP`,
`INSTANCE_NAME`, `LOCATION`, `ADR_NAMESPACE_NAME`, `NAMESPACE`) are
all populated by `discover_env.sh`; the simplest workflow is to
`eval "$(./discover_env.sh ...)"` once at the start of each shell
session and then forget about them.

### `discover_env.sh <sub-id> <rg>`

Walks the resource group, picks the most-recently-created
`Microsoft.IoTOperations/instances` and `Microsoft.DeviceRegistry/namespaces`,
and prints a block of `export` lines on stdout (logs go to stderr).

### `show_simulators.sh [-n <ns>] [-A]`

Lists all Kubernetes Services that expose port 4840 and labels each
one as `umati`, `opc-simulator`, or `unknown` based on the
`app.kubernetes.io/name` selector. The `DNS-ADDRESS` column is what
you'd hand to `register_device.sh --service`.

### `deploy_umati.sh [--release <name>] [--namespace <ns>] [--chart <path|url>]`

Idempotent helm install of one umati instance.

* Chart resolution order:
  1. `--chart <path>` (or `HELM_CHART` env), if given.
  2. The vendored fork at `charts/umati-sample-server-1.0-alpha.1-microsoft.1.tgz`.
  3. The remote raw URL composed from `GITHUB_ORG` / `GITHUB_REPO` /
     `GITHUB_BRANCH` (used when this folder was downloaded without
     `charts/`, e.g. via `bootstrap.sh`).
* Always installs with `simulations=1` and `deployDefaultIssuerCA=false`.
  If you need more than one umati simulator, run again with a
  different `--release`.
* The resulting service is `umati-<release>-000000.<namespace>.svc.cluster.local:4840`.

### `deploy_opc_simulator.sh [--image <ref>] [--release <name>] [--config <toml>] [--values <yaml>] [--chart <path>]`

Idempotent helm install of one OPC-Simulator instance using the
vendored chart at `charts/opc-simulator-<version>.tgz` (a packaged
copy of `OPC-Simulator/deploy/helm/opc-simulator`).

* `--image` is **optional**. Defaults to
  `vipeller.azurecr.io/opc-simulator:0.1.0` (the pre-built artifact
  in the shared ACR). Override with the output of
  `OPC-Simulator/deploy/scripts/build-and-push.sh` when iterating on
  a local build.
* The chart resolution order is:
  1. `--chart <path>` / `CHART_PATH` / `OPC_SIMULATOR_CHART_PATH`
     (a chart directory or a `.tgz` both work).
  2. The vendored `charts/opc-simulator-<version>.tgz` next to this
     script (the `bootstrap.sh` default).
  3. `<this-script>/../../deploy/helm/opc-simulator` — only used
     when this folder runs from inside the OPC-Simulator repo and
     you want to test chart edits without repackaging.
* Pass a custom `simulator.toml` with `--config` (renders into the
  chart's `simulatorConfig` value via `--set-file`).
* The resulting service name follows the chart's `fullname` rule:
  if your `--release` already contains the substring `opc-simulator`,
  it's the service name; otherwise it's `<release>-opc-simulator`.

### `register_device.sh --service <svc> [--device <name>] [--asset-type <type>]... [--port 4840] [--namespace <k8s-ns>]`

Creates a `Microsoft.DeviceRegistry/namespaces/devices` resource
that points at a Kubernetes Service inside the cluster. The address
is composed as `opc.tcp://<service>.<k8s-ns>.svc.cluster.local:<port>`.

* `--asset-type` is **repeatable** and **optional**. Pass nothing
  to leave the array empty (the OPC UA connector treats this as
  "discover everything I can reach"). Pass one or more values to
  filter — e.g. for the umati machine-tool sample server:

  ```bash
  ./register_device.sh --service umati-umati-000000 \
      --asset-type 'nsu=http://opcfoundation.org/UA/MachineTool/;i=13'
  ```

* The endpoint type sent to the API is `Microsoft.OpcUa`, with the
  modern (2025-10-01) `additionalConfiguration` shape:

  ```json
  {
    "security": {
      "securityMode": "None",
      "securityPolicy": "http://opcfoundation.org/UA/SecurityPolicy#None",
      "autoAcceptUntrustedServerCertificates": true
    },
    "runAssetDiscovery": true,
    "assetTypes": [ ... ]
  }
  ```

* The script is **idempotent**: an existing device with the same
  name is reported and left alone.

### `onboard_bulk.sh [--count N] [--timeout SEC] [--prefix PFX] [--interval SEC]`

Polls the ADR namespace's `discoveredAssets` collection on a fixed
interval. As soon as `--count` (default 1) assets have been
successfully onboarded **or** the `--timeout` (default 600 s) has
expired, the script returns. Already-onboarded assets count toward
the target, so re-runs are safe.

Use `--prefix` to constrain the run to assets whose names start
with a given string (handy when several simulators are registered
in the same ADR namespace).

Exit code:
* **0** — reached `--count` successful onboardings.
* **1** — timed out before reaching the target.

### `onboard_interactive.sh [--prefix PFX] [--interval SEC] [--show-details] [--max-iterations N]`

Same polling loop as `onboard_bulk.sh`, but for every newly-seen
discovered asset it prompts:

```
Onboard 'asset-name'? [y/N/q]
```

* `y` / `yes` → onboard,
* anything else → skip (won't ask again this run),
* `q` / `quit` → exit cleanly with a summary.

Pass `--show-details` to get a compact JSON dump of each asset
(displayName, manufacturer, dataset/event/stream counts, …) before
the prompt. Pass `--max-iterations` to bound the run length;
otherwise it loops until you quit.

---

## Files

```
bootstrap.sh           # one-liner installer (curl ... | bash)
common.sh              # shared helpers (logging, az login, kube wiring)
onboard_lib.sh         # shared discoveredAsset → asset PUT logic
discover_env.sh        # populate SUBSCRIPTION_ID, INSTANCE_NAME, …
show_simulators.sh     # list k8s services on port 4840
deploy_umati.sh        # helm install of the umati sample server
deploy_opc_simulator.sh# helm install of this repo's opc-simulator chart
register_device.sh     # PUT a Microsoft.DeviceRegistry/.../devices/<name>
onboard_bulk.sh        # bulk onboard with --count + --timeout
onboard_interactive.sh # interactive y/n onboard
charts/                # vendored helm charts (opc-simulator + umati fork)
README.md              # this file
```

---

## Typical end-to-end flow

A full "run" of a fresh AIO cluster, deploying both simulators and
onboarding everything they expose:

```bash
# Set up.
eval "$(./discover_env.sh $MY_SUB $MY_RG)"

# Deploy our simulator (uses the default ACR image; pass --image to
# point at a freshly-built one).
./deploy_opc_simulator.sh

# Deploy umati alongside it.
./deploy_umati.sh

# Sanity check.
./show_simulators.sh

# Register both as ADR devices.
./register_device.sh --service opc-simulator
./register_device.sh --service umati-umati-000000 \
    --asset-type 'nsu=http://opcfoundation.org/UA/MachineTool/;i=13'

# Drain whatever they discover (up to 20 assets / 15 minutes).
./onboard_bulk.sh --count 20 --timeout 900
```

---

## Tips & troubleshooting

* **"No AKS clusters found"** — these are warnings, not errors. If
  you're on Arc-enabled K8s just make sure your `kubectl` context
  is set before running the deploy scripts.
* **Helm release "already exists"** — the deploy scripts are
  idempotent on purpose. Delete the release with
  `helm uninstall -n <ns> <release>` if you really want to redeploy.
* **`az iot ops show` fails** — install/refresh the `azure-iot-ops`
  CLI extension manually:
  `az extension add -n azure-iot-ops -y`.
* **Onboard scripts time out** — the OPC UA connector can take a
  minute or two to start asset discovery after a `register_device`.
  Bump `--timeout` and/or `--interval`; you can also re-run the
  bulk script (already-onboarded assets are counted toward the
  target).
* **Different ADR API version** — every script reads the
  `API` env var (default `2025-10-01`). Override per invocation
  if you need to test against a different surface.

---

## License

Same as the parent OPC-Simulator repository.
