# WoT Thing Model uploader

`upload_wot_tm.py` is self-contained: it uses only the Python standard library.
No index generator, watcher, model catalog, or other project files are needed.

## Requirements

- Python 3.10 or newer (use `python3` instead of `python` if needed).
- Git when downloading models; not needed with `--models-dir`.
- An existing Azure Device Registry schema registry and permission to
  create/update its schemas and schema versions.
- An Azure Resource Manager bearer token for uploads. Azure CLI is optional
  and can obtain the token after `az login`.

The script uploads original JSON content as `schemaType=ThingModel` and
`format=JsonLD/1.1`, using ARM API version `2026-11-01` by default. Each document
must be a JSON object with a nonempty top-level `id`. The script derives a
stable ARM-safe schema name and preserves the original ID in encoded tags.
**Re-running replaces the same schema and selected version; it does not delete
other registry entries.**

## Quick start

Run from this directory. Set the following variables, or supply their CLI equivalents:

| Environment variable | CLI parameter | Purpose |
| --- | --- | --- |
| `AZURE_SUBSCRIPTION_ID` | `--subscription-id` | Target subscription ID |
| `AZURE_RESOURCE_GROUP` | `--resource-group` | Target resource group |
| `AZURE_SCHEMA_REGISTRY_NAME` | `--registry-name` | Existing schema registry name |
| `AZURE_ACCESS_TOKEN` | `--bearer-token` | ARM bearer token; prefer the environment to command-line exposure |

For example, in Bash:

```bash
export AZURE_SUBSCRIPTION_ID="<subscription-id>"
export AZURE_RESOURCE_GROUP="<resource-group>"
export AZURE_SCHEMA_REGISTRY_NAME="<registry-name>"
az login
export AZURE_ACCESS_TOKEN="$(az account get-access-token --subscription "$AZURE_SUBSCRIPTION_ID" --resource https://management.azure.com/ --query accessToken -o tsv)"
```

In PowerShell, set variables with `$env:NAME = "value"`; obtain a token with:

```powershell
$env:AZURE_ACCESS_TOKEN = az account get-access-token --subscription $env:AZURE_SUBSCRIPTION_ID --resource https://management.azure.com/ --query accessToken -o tsv
```

Preview selected models, then remove `--dry-run` to upload:

```sh
python upload_wot_tm.py --include "MachineTool_ToolType.TM.json" --include "MachineTool_MachineToolType.TM.json" --dry-run
```

Without `--include`, all JSON documents in the models directory are selected.
Repeated `--include` options select matches to **any** supplied filename/path
pattern; they do not add files to an otherwise full upload. Filtering happens
**after downloading** the repository's models directory. Dependencies such as
parent types are not automatically selected.

For local models, add `--models-dir /path/to/models`. A dry run still requires
the three Azure identifiers but **does not require a token or make ARM requests**.

## Additional parameters

| Parameter | Description / default |
| --- | --- |
| `--bearer-token-file PATH` | Read a token from a UTF-8 file. Unset `AZURE_ACCESS_TOKEN` and omit `--bearer-token` to use this option; either takes precedence over the file. |
| `--models-dir PATH` | Use local models instead of cloning; Git source options are ignored. |
| `--repo-url URL` | Git source; default `https://github.com/Azure/smd.git`. |
| `--repo-ref REF` | Git branch/tag to clone; default `main`. |
| `--models-subdirectory PATH` | Models directory inside the Git repository; default `models`. |
| `--include GLOB` | Repeatable filename or models-relative path filter. Quote wildcards, e.g. `--include "MachineTool_*"`. |
| `--limit N` | Process only the first N selected files, in sorted path order. |
| `--schema-version N` | Numeric target version (1–10 digits); default `1`. |
| `--api-version VERSION` | ARM API version; default `2026-11-01`. |
| `--management-endpoint URL` | ARM endpoint; default `https://management.azure.com`. Token audience must match the endpoint. |
| `--workers N` | Concurrent uploads; default `8`. |
| `--request-timeout SECONDS` | Per-request timeout; default `60`. |
| `--lro-timeout SECONDS` | Long-running-operation wait limit; default `600`. |
| `--retries N` | Retries for transient request failures; default `5`. |
| `--dry-run` | Validate and print the plan without uploading. |
| `--help` | Show command-line usage. |

CLI arguments override their environment-variable defaults. Tokens are not
refreshed automatically: obtain a fresh token before another run if it expires.
Do not share tokens or token files. Uploads send document content to Azure;
cloning uses the configured Git host. Individual upload failures are reported
in the final summary and cause a nonzero exit status.
