## Prerequisites

You need an existing Azure IoT Operations (AIO) instance, an Azure Device Registry
(ADR) namespace, and an OPC UA connector in the cluster to discover assets.
Sign in to the Azure CLI with access to the subscription and resource group
containing the AIO instance. The scripts used below require:

| Tool       | Used for |
| ---------- | -------- |
| `bash` 4.x | Running the scripts (`mapfile` and associative arrays require Bash 4 or later). |
| `az`       | Discovering AIO resources, registering the device, and onboarding assets. |
| `jq`       | Processing JSON in the scripts. |
| `kubectl`  | Checking deployment readiness and listing simulator services. |
| `helm`     | Deploying the OPC UA simulator. |
| `column`   | Formatting the output of `show_simulators.sh`. |

Option A below also requires `curl`; Option B requires `git`. The onboarding
script installs the `azure-iot-ops` Azure CLI extension if it is missing and
attempts to update it if it is already installed.

For Arc-enabled Kubernetes clusters, configure `kubectl` access before deploying
or listing services (for example, with `az connectedk8s proxy -g <resource-group>
-n <cluster-name>`). If the resource group contains exactly one AKS cluster, the
deploy script attempts to fetch its credentials automatically; otherwise,
configure your `kubectl` context yourself.

---

## Quick start

### Option A — Download the tools without cloning

Download the helper scripts, configuration, and vendored Helm charts into
`aio-tools/`:

```bash
curl -sSL https://raw.githubusercontent.com/vipeller/tools/main/aio-tools/bootstrap.sh \
    | bash
cd aio-tools
```

### Option B — Clone the repo

```bash
git clone https://github.com/vipeller/tools.git
cd tools/aio-tools
```

### With either option

Replace `YOUR_SUBSCRIPTION_ID` and `YOUR_RESOURCE_GROUP` with your Azure values:

```bash
# 1. Discover the AIO environment and load the resulting variables.
eval "$(./discover_env.sh YOUR_SUBSCRIPTION_ID YOUR_RESOURCE_GROUP)"

# 2. Deploy the OPC UA simulator using its default image.
./deploy_opc_simulator.sh

# 3. Check the simulator's Kubernetes Service name.
./show_simulators.sh

# 4. Register the simulator as an ADR device and discover MachineTool assets.
./register_device.sh --service opc-simulator \
    --asset-type 'nsu=http://opcfoundation.org/UA/MachineTool/;i=13'

# 5. Choose which discovered assets to onboard (answer y, n, or q).
./onboard_interactive.sh --show-details
```

Discovery may take a minute or two after registration.

The validation pipeline results in multiple test assets - those will not produce the proper output
for the current test - only assets handled by the OPC UA Connector work.
When onboarding, skip every asset that does not start with a name `opc-simulator`.

Double check that the assets are onboarded by:
```bash
kubectl get assets.namespace -n azure-iot-operations
```

[Back](README.md)
