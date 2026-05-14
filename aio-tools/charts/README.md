# charts/

Vendored helm charts that the `aio-tools` scripts depend on.

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
