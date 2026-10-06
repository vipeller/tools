# charts/

Vendored Helm chart packages that the `aio-tools` scripts depend on,
plus tracked source for the local pump chart.

## `opc-simulator-0.1.0.tgz`

A `helm package` of the OPC-Simulator chart at
`OPC-Simulator/deploy/helm/opc-simulator`. We vendor it here so the
`deploy_opc_simulator.sh` script works in any environment that has
run `bootstrap.sh`, without requiring the consumer to clone the
full OPC-Simulator repository.

To refresh after a chart change:

```bash
helm package deploy/helm/opc-simulator \
    --destination aio-tools/charts/
```

Bump `aio-tools/charts/`'s entry in `bootstrap.sh` and the
`DEFAULT_CHART_FILE` constant in `deploy_opc_simulator.sh` to match
the new file name (the chart's `Chart.yaml` `version` is the source
of truth for the file name).

## `pump-device-integration-server-0.1.1.tgz`

A package of our **local** chart in `pump-device-integration-server/`,
used by `deploy_pump.sh` and downloaded by `bootstrap.sh`. The source
is tracked here so the package can be reproduced and chart changes
reviewed. This is not an upstream OPC Foundation Helm chart.

The server sample is
[`samples/DI/PumpDeviceIntegrationServer`](https://github.com/OPCFoundation/UA-.NETStandard/tree/7212607f1652f37ca90b342ec9afa864f328850e/samples/DI/PumpDeviceIntegrationServer)
in `OPCFoundation/UA-.NETStandard`, reviewed at commit
`7212607f1652f37ca90b342ec9afa864f328850e`. Upstream provides a
`kubernetes.yaml`, not a pump Helm chart. That commit records sample
provenance; it does not pin the container image.

The default image is
`ghcr.io/opcfoundation/uanetstandard/pumpserver:latest-master`, a
publicly pullable upstream **development tag** for Linux amd64 and
arm64. It can change; use `deploy_pump.sh --image <full-ref>` (or
`IMAGE`) to pin a chosen tag or digest for repeatable deployments.

One server runs per release, with two pumps by default (`--pumps`
accepts 1–100). Its OPC UA endpoint is port `62542` with path
`/PumpDeviceIntegrationServer`. Upstream enables encrypted endpoints
only by default. Register it with `--port 62542`,
`--endpoint-path /PumpDeviceIntegrationServer`,
`--security-mode SignAndEncrypt`,
`--security-policy 'http://opcfoundation.org/UA/SecurityPolicy#Basic256Sha256'`,
and `--asset-type 'nsu=http://opcfoundation.org/UA/Pumps/;i=1052'`;
see the full command in [`../README.md`](../README.md).

Persistence is disabled by default: `/app/pki` uses `emptyDir`, so
certificates and trust state do not survive Pod replacement. For
persistent PKI, supply a values file with `persistence.enabled: true`;
`persistence.existingClaim`, `persistence.storageClass`, and
`persistence.size` are supported. There is no diagnostic sidecar.
Certificate auto-acceptance in the sample and registration workflow
is for testing, not production trust management. Upstream generates
certificates with `O=OPC Foundation`; this chart does not rewrite the
subject to `O=Microsoft` as the umati fork does. If your connector
enforces that organization policy, compatible PKI configuration is
required separately.

### AIO connector trust

Version `0.1.1` fixes pump rejection of AIO's CA-issued client certificate
with `BadCertificateRevocationUnknown` when no CRL is available. By default
it mounts only the public `tls.crt` key from `aio-opc-ua-gds-ca-cert`
as `/app/pki/trusted/certs/aio-gds-ca.pem`, and the DER
`aio-opc-ua-gds-ca.crl` key from `aio-opc-ua-gds-ca-crl` as
`/app/pki/trusted/crl/aio-gds-ca.crl`. It never mounts `tls.key`.
The Secrets must exist in the release namespace. Both directories are
read-only Secret mounts without `subPath`, so Kubernetes Secret refreshes
are visible to the upstream certificate store rather than being copied
only at startup. Revocation checking remains enabled.

The `connectorTrust` values allow changing the Secret names and data keys.
The certificate must be PEM and the CRL must be DER, matching the standard
AIO Secrets. Set `connectorTrust.enabled: false` only when using a
separately managed trust store, such as a standalone simulator setup.
See the upgrade command and diagnosis in [`../README.md`](../README.md).

### Reproducing the package

From the repository root:

```bash
helm package aio-tools/charts/pump-device-integration-server \
    --destination aio-tools/charts
```

The chart's `Chart.yaml` `version` determines the package filename.
If it changes, update the package entry in `bootstrap.sh` and the
default package filename in `deploy_pump.sh` together.

## `umati-sample-server-1.0-alpha.1-microsoft.1.tgz`

A `helm package` of the umati sample server.

### Versioning

The chart version is bumped from `1.0-alpha.1` to
`1.0-alpha.1-microsoft.1` to make the provenance unambiguous when
inspecting `helm list -A` or chart caches.

### Reproducing the package

If you ever need to regenerate the `.tgz`:

```bash
# Pull the upstream tarball.
curl -sLO https://raw.githubusercontent.com/vipeller/aio_gp_test/main/aio-tools/charts/umati-sample-server-1.0-alpha.1.tgz
tar -xzf umati-sample-server-1.0-alpha.1.tgz

# Apply the two edits.
sed -i 's/^version: 1.0-alpha.1$/version: 1.0-alpha.1-microsoft.1/' \
    umati-sample-server/Chart.yaml

# In templates/umati_default_application_certificate.yaml, replace
# the commented-out `# organizations: \n #  - Microsoft` lines with:
#     organizations:
#       - Microsoft
# (see the chart's template for the exact context).

# Repackage.
helm package umati-sample-server
```
