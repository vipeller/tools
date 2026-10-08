#!/usr/bin/env python3
"""Upload WoT Thing Models from a Git repository to Azure Device Registry."""

from __future__ import annotations

import argparse
import base64
import concurrent.futures
import fnmatch
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

API_VERSION = "2026-11-01"
DEFAULT_REPOSITORY = "https://github.com/Azure/smd.git"
DEFAULT_REPOSITORY_REF = "main"
DEFAULT_MODELS_SUBDIRECTORY = "models"
DEFAULT_SCHEMA_VERSION = "1"
SCHEMA_FORMAT = "JsonLD/1.1"
SCHEMA_TYPE = "ThingModel"
SYSTEM_TAG_PREFIX = "__SYSTEM"
ARM_MAX_TAGS = 50
ARM_MAX_TAG_KEY_LENGTH = 512
ARM_MAX_TAG_VALUE_LENGTH = 256
TAG_INDEX_WIDTH = 3
SCHEMA_NAME_MAX_LENGTH = 64
SCHEMA_NAME_HASH_LENGTH = 10
RETRIABLE_STATUS_CODES = {408, 409, 429, 500, 502, 503, 504}


class UploaderError(RuntimeError):
    """Base error for actionable uploader failures."""


class ModelError(UploaderError):
    """Raised when a source model cannot be loaded safely."""


class UploadError(UploaderError):
    """Raised when an ARM request fails."""


@dataclass(frozen=True)
class ThingModel:
    path: Path
    relative_path: str
    original_id: str
    schema_name: str
    content: str


@dataclass(frozen=True)
class UploadResult:
    model: ThingModel
    schema_status: int
    version_status: int


class ArmRestClient:
    def __init__(
        self,
        *,
        bearer_token: str,
        management_endpoint: str,
        api_version: str,
        request_timeout: float,
        lro_timeout: float,
        retries: int,
    ) -> None:
        self._bearer_token = normalize_bearer_token(bearer_token)
        self._management_endpoint = management_endpoint.rstrip("/")
        self._api_version = api_version
        self._request_timeout = request_timeout
        self._lro_timeout = lro_timeout
        self._retries = retries

    def resource_url(self, resource_path: str) -> str:
        query = urllib.parse.urlencode({"api-version": self._api_version})
        return f"{self._management_endpoint}/{resource_path.lstrip('/')}?{query}"

    def put(self, resource_path: str, body: Mapping[str, Any]) -> int:
        url = self.resource_url(resource_path)
        status, headers, response_body = self._request("PUT", url, body)
        operation_url = headers.get("Azure-AsyncOperation") or headers.get(
            "Operation-Location"
        )
        if operation_url:
            self._poll_operation(operation_url, headers)
        elif status == 202:
            location = headers.get("Location")
            if not location:
                raise UploadError(
                    f"PUT {url} returned 202 without an ARM operation URL"
                )
            self._poll_operation(location, headers)
        elif response_body:
            # Parse successful JSON when present so malformed proxy responses are visible.
            try:
                json.loads(response_body)
            except json.JSONDecodeError as error:
                raise UploadError(
                    f"PUT {url} returned invalid JSON: {error}"
                ) from error
        return status

    def _poll_operation(
        self, operation_url: str, initial_headers: Mapping[str, str]
    ) -> None:
        deadline = time.monotonic() + self._lro_timeout
        delay = retry_after_seconds(initial_headers, default=2.0)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise UploadError(
                    f"ARM operation did not finish within {self._lro_timeout:g} seconds: "
                    f"{operation_url}"
                )
            time.sleep(min(delay, remaining))
            _, headers, response_body = self._request("GET", operation_url, None)
            try:
                operation = json.loads(response_body) if response_body else {}
            except json.JSONDecodeError as error:
                raise UploadError(
                    f"ARM operation returned invalid JSON from {operation_url}: {error}"
                ) from error
            status = str(operation.get("status", "")).lower()
            if status == "succeeded":
                return
            if status in {"failed", "canceled", "cancelled"}:
                detail = operation.get("error", operation)
                raise UploadError(
                    f"ARM operation {status}: {json.dumps(detail, ensure_ascii=False)}"
                )
            delay = retry_after_seconds(headers, default=2.0)

    def _request(
        self,
        method: str,
        url: str,
        body: Mapping[str, Any] | None,
    ) -> tuple[int, Mapping[str, str], str]:
        data = None
        if body is not None:
            data = json.dumps(
                body, ensure_ascii=False, separators=(",", ":")
            ).encode("utf-8")
        headers = {
            "Accept": "application/json",
            "Authorization": f"Bearer {self._bearer_token}",
            "User-Agent": "wot-tm-schema-uploader/1.0",
        }
        if data is not None:
            headers["Content-Type"] = "application/json"

        for attempt in range(self._retries + 1):
            request = urllib.request.Request(
                url, data=data, headers=headers, method=method
            )
            try:
                with urllib.request.urlopen(
                    request, timeout=self._request_timeout
                ) as response:
                    response_body = response.read().decode("utf-8")
                    return response.status, response.headers, response_body
            except urllib.error.HTTPError as error:
                error_body = error.read().decode("utf-8", errors="replace")
                if error.code in RETRIABLE_STATUS_CODES and attempt < self._retries:
                    time.sleep(
                        retry_after_seconds(
                            error.headers, default=min(2**attempt, 30)
                        )
                    )
                    continue
                detail = format_http_error(error_body)
                raise UploadError(
                    f"{method} {url} failed with HTTP {error.code}: {detail}"
                ) from error
            except (urllib.error.URLError, TimeoutError, OSError) as error:
                if attempt < self._retries:
                    time.sleep(min(2**attempt, 30))
                    continue
                raise UploadError(f"{method} {url} failed: {error}") from error

        raise AssertionError("request retry loop exited unexpectedly")


def normalize_bearer_token(token: str) -> str:
    token = token.strip()
    if token.lower().startswith("bearer "):
        token = token[7:].strip()
    if not token:
        raise UploaderError("the bearer token is empty")
    return token


def retry_after_seconds(headers: Any | None, *, default: float) -> float:
    if headers:
        value = headers.get("Retry-After")
        if value:
            try:
                return max(0.0, float(value))
            except ValueError:
                pass
    return default


def format_http_error(body: str) -> str:
    if not body:
        return "no response body"
    try:
        parsed = json.loads(body)
    except json.JSONDecodeError:
        return body[:2000]
    error = parsed.get("error", parsed) if isinstance(parsed, dict) else parsed
    return json.dumps(error, ensure_ascii=False)[:4000]


def encode_metadata_tags(original_id: str) -> dict[str, str]:
    """Mirror ArmSchemaMetadataV1::to_tags and SystemTagCodec::encode."""
    metadata = {
        "v": "1",
        "read_only": False,
        "labels": [["originalid", original_id]],
        "meta_extensions": {},
        "extensions": {},
        "versions": {},
    }
    metadata_bytes = json.dumps(
        metadata, ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8")
    encoded = base64.urlsafe_b64encode(metadata_bytes).decode("ascii").rstrip("=")

    marker_length = len(SYSTEM_TAG_PREFIX) + TAG_INDEX_WIDTH
    key_chunk_length = ARM_MAX_TAG_KEY_LENGTH - marker_length
    per_tag = key_chunk_length + ARM_MAX_TAG_VALUE_LENGTH
    needed = (len(encoded) + per_tag - 1) // per_tag
    if needed > ARM_MAX_TAGS:
        raise ModelError(
            f"metadata for id {original_id!r} requires {needed} tags; "
            f"ARM permits only {ARM_MAX_TAGS}"
        )

    tags: dict[str, str] = {}
    position = 0
    index = 0
    while position < len(encoded):
        key_end = min(position + key_chunk_length, len(encoded))
        value_end = min(key_end + ARM_MAX_TAG_VALUE_LENGTH, len(encoded))
        key_chunk = encoded[position:key_end]
        value_chunk = encoded[key_end:value_end]
        tags[f"{SYSTEM_TAG_PREFIX}{index:03d}{key_chunk}"] = value_chunk
        position = value_end
        index += 1
    return tags


def schema_name_for(original_id: str) -> str:
    """Create a stable ARM-safe schema name while retaining a readable prefix."""
    slug = re.sub(r"[^a-z0-9]+", "-", original_id.lower()).strip("-")
    if not slug:
        slug = "thing-model"
    if len(slug) < 3:
        slug = f"tm-{slug}"
    digest = hashlib.sha256(original_id.encode("utf-8")).hexdigest()[
        :SCHEMA_NAME_HASH_LENGTH
    ]
    prefix_length = SCHEMA_NAME_MAX_LENGTH - SCHEMA_NAME_HASH_LENGTH - 1
    prefix = slug[:prefix_length].rstrip("-")
    if len(prefix) < 3:
        prefix = "thing-model"
    return f"{prefix}-{digest}"


def clone_models_repository(
    repository_url: str,
    repository_ref: str,
    models_subdirectory: str,
    destination: Path,
) -> Path:
    clone_command = [
        "git",
        "clone",
        "--depth",
        "1",
        "--filter=blob:none",
        "--sparse",
        "--single-branch",
        "--branch",
        repository_ref,
        repository_url,
        str(destination),
    ]
    run_git(clone_command)
    run_git(
        [
            "git",
            "-C",
            str(destination),
            "sparse-checkout",
            "set",
            models_subdirectory,
        ]
    )
    models_directory = destination / models_subdirectory
    if not models_directory.is_dir():
        raise ModelError(
            f"models directory {models_subdirectory!r} was not found in "
            f"{repository_url!r} at ref {repository_ref!r}"
        )
    return models_directory


def run_git(command: list[str]) -> None:
    try:
        subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as error:
        raise UploaderError(
            "git is required when --models-dir is not supplied"
        ) from error
    except subprocess.CalledProcessError as error:
        detail = error.stderr.strip() or error.stdout.strip() or str(error)
        raise UploaderError(f"git command failed: {detail}") from error


def discover_models(
    models_directory: Path,
    include_patterns: Iterable[str],
    limit: int | None,
) -> list[ThingModel]:
    if not models_directory.is_dir():
        raise ModelError(f"models directory does not exist: {models_directory}")

    patterns = tuple(include_patterns)
    candidates = sorted(
        path for path in models_directory.rglob("*.json") if path.is_file()
    )
    models: list[ThingModel] = []
    seen_ids: dict[str, str] = {}
    seen_names: dict[str, str] = {}
    for path in candidates:
        relative_path = path.relative_to(models_directory).as_posix()
        if patterns and not any(
            fnmatch.fnmatch(relative_path, pattern)
            or fnmatch.fnmatch(path.name, pattern)
            for pattern in patterns
        ):
            continue
        model = load_model(path, relative_path)
        previous_path = seen_ids.get(model.original_id)
        if previous_path is not None:
            raise ModelError(
                f"duplicate WoT id {model.original_id!r} in {previous_path!r} "
                f"and {relative_path!r}"
            )
        previous_id = seen_names.get(model.schema_name)
        if previous_id is not None:
            raise ModelError(
                f"schema-name collision {model.schema_name!r} for ids "
                f"{previous_id!r} and {model.original_id!r}"
            )
        seen_ids[model.original_id] = relative_path
        seen_names[model.schema_name] = model.original_id
        models.append(model)
        if limit is not None and len(models) >= limit:
            break

    if not models:
        suffix = f" matching {patterns!r}" if patterns else ""
        raise ModelError(f"no JSON models found in {models_directory}{suffix}")
    return models


def load_model(path: Path, relative_path: str) -> ThingModel:
    try:
        content = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise ModelError(f"cannot read {relative_path}: {error}") from error
    try:
        document = json.loads(content)
    except json.JSONDecodeError as error:
        raise ModelError(f"invalid JSON in {relative_path}: {error}") from error
    if not isinstance(document, dict):
        raise ModelError(f"{relative_path} must contain a JSON object")
    original_id = document.get("id")
    if not isinstance(original_id, str) or not original_id.strip():
        raise ModelError(f"{relative_path} has no non-empty string 'id'")
    original_id = original_id.strip()
    return ThingModel(
        path=path,
        relative_path=relative_path,
        original_id=original_id,
        schema_name=schema_name_for(original_id),
        content=content,
    )


def quote_segment(value: str) -> str:
    return urllib.parse.quote(value, safe="")


def schema_resource_path(
    subscription_id: str,
    resource_group: str,
    registry_name: str,
    schema_name: str,
) -> str:
    return (
        f"subscriptions/{quote_segment(subscription_id)}"
        f"/resourceGroups/{quote_segment(resource_group)}"
        "/providers/Microsoft.DeviceRegistry"
        f"/schemaRegistries/{quote_segment(registry_name)}"
        f"/schemas/{quote_segment(schema_name)}"
    )


def upload_model(
    client: ArmRestClient,
    model: ThingModel,
    *,
    subscription_id: str,
    resource_group: str,
    registry_name: str,
    schema_version: str,
) -> UploadResult:
    schema_path = schema_resource_path(
        subscription_id, resource_group, registry_name, model.schema_name
    )
    schema_body = {
        "properties": {
            "format": SCHEMA_FORMAT,
            "schemaType": SCHEMA_TYPE,
            "tags": encode_metadata_tags(model.original_id),
        }
    }
    schema_status = client.put(schema_path, schema_body)
    version_body = {"properties": {"schemaContent": model.content}}
    version_status = client.put(
        f"{schema_path}/schemaVersions/{quote_segment(schema_version)}",
        version_body,
    )
    return UploadResult(model, schema_status, version_status)


def resolve_token(arguments: argparse.Namespace) -> str:
    if arguments.bearer_token:
        return arguments.bearer_token
    if arguments.bearer_token_file:
        try:
            return arguments.bearer_token_file.read_text(encoding="utf-8")
        except OSError as error:
            raise UploaderError(
                f"cannot read bearer token file {arguments.bearer_token_file}: {error}"
            ) from error
    raise UploaderError(
        "provide --bearer-token, --bearer-token-file, or AZURE_ACCESS_TOKEN"
    )


def validate_arguments(parser: argparse.ArgumentParser, args: argparse.Namespace) -> None:
    required = {
        "--subscription-id or AZURE_SUBSCRIPTION_ID": args.subscription_id,
        "--resource-group or AZURE_RESOURCE_GROUP": args.resource_group,
        "--registry-name or AZURE_SCHEMA_REGISTRY_NAME": args.registry_name,
    }
    missing = [name for name, value in required.items() if not value]
    if missing:
        parser.error("missing " + ", ".join(missing))
    if not re.fullmatch(r"[0-9]{1,10}", args.schema_version):
        parser.error("--schema-version must contain 1 to 10 digits")
    if args.workers < 1:
        parser.error("--workers must be at least 1")
    if args.limit is not None and args.limit < 1:
        parser.error("--limit must be at least 1")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Upload WoT Thing Models from a Git repository or local directory "
            "to an Azure Device Registry schema registry."
        )
    )
    parser.add_argument(
        "--subscription-id", default=os.environ.get("AZURE_SUBSCRIPTION_ID")
    )
    parser.add_argument(
        "--resource-group", default=os.environ.get("AZURE_RESOURCE_GROUP")
    )
    parser.add_argument(
        "--registry-name", default=os.environ.get("AZURE_SCHEMA_REGISTRY_NAME")
    )
    parser.add_argument(
        "--bearer-token",
        default=os.environ.get("AZURE_ACCESS_TOKEN"),
        help="ARM bearer token; prefer AZURE_ACCESS_TOKEN to avoid shell history",
    )
    parser.add_argument(
        "--bearer-token-file",
        type=Path,
        help="file containing the ARM bearer token",
    )
    parser.add_argument("--repo-url", default=DEFAULT_REPOSITORY)
    parser.add_argument("--repo-ref", default=DEFAULT_REPOSITORY_REF)
    parser.add_argument(
        "--models-subdirectory", default=DEFAULT_MODELS_SUBDIRECTORY
    )
    parser.add_argument(
        "--models-dir",
        type=Path,
        help="use an existing models directory instead of cloning the repository",
    )
    parser.add_argument(
        "--include",
        action="append",
        default=[],
        metavar="GLOB",
        help="upload only matching relative paths or filenames; repeatable",
    )
    parser.add_argument(
        "--limit", type=int, help="process only the first N selected models"
    )
    parser.add_argument("--schema-version", default=DEFAULT_SCHEMA_VERSION)
    parser.add_argument("--api-version", default=API_VERSION)
    parser.add_argument(
        "--management-endpoint", default="https://management.azure.com"
    )
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--request-timeout", type=float, default=60.0)
    parser.add_argument("--lro-timeout", type=float, default=600.0)
    parser.add_argument("--retries", type=int, default=5)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="validate and print the upload plan without making ARM requests",
    )
    return parser


def run(args: argparse.Namespace) -> int:
    temporary_directory: tempfile.TemporaryDirectory[str] | None = None
    try:
        if args.models_dir:
            models_directory = args.models_dir.resolve()
        else:
            temporary_directory = tempfile.TemporaryDirectory(
                prefix="wot-tm-uploader-"
            )
            checkout = Path(temporary_directory.name) / "repository"
            print(
                f"Cloning {args.repo_url} ({args.repo_ref})...",
                flush=True,
            )
            models_directory = clone_models_repository(
                args.repo_url,
                args.repo_ref,
                args.models_subdirectory,
                checkout,
            )

        models = discover_models(models_directory, args.include, args.limit)
        print(f"Discovered {len(models)} model(s)", flush=True)
        if args.dry_run:
            for model in models:
                print(
                    f"DRY RUN {model.relative_path} -> {model.schema_name}/"
                    f"{args.schema_version} (originalid={model.original_id})"
                )
            return 0

        token = resolve_token(args)
        client = ArmRestClient(
            bearer_token=token,
            management_endpoint=args.management_endpoint,
            api_version=args.api_version,
            request_timeout=args.request_timeout,
            lro_timeout=args.lro_timeout,
            retries=args.retries,
        )
        print_lock = threading.Lock()
        failures: list[tuple[ThingModel, UploaderError]] = []
        succeeded = 0

        def perform(model: ThingModel) -> UploadResult:
            return upload_model(
                client,
                model,
                subscription_id=args.subscription_id,
                resource_group=args.resource_group,
                registry_name=args.registry_name,
                schema_version=args.schema_version,
            )

        with concurrent.futures.ThreadPoolExecutor(
            max_workers=args.workers
        ) as executor:
            future_to_model = {
                executor.submit(perform, model): model for model in models
            }
            for future in concurrent.futures.as_completed(future_to_model):
                model = future_to_model[future]
                try:
                    result = future.result()
                except UploaderError as error:
                    failures.append((model, error))
                    with print_lock:
                        print(
                            f"FAILED {model.relative_path}: {error}",
                            file=sys.stderr,
                            flush=True,
                        )
                else:
                    succeeded += 1
                    with print_lock:
                        print(
                            f"UPLOADED {model.relative_path} -> "
                            f"{model.schema_name}/{args.schema_version} "
                            f"(HTTP {result.schema_status}, "
                            f"HTTP {result.version_status})",
                            flush=True,
                        )

        print(
            f"Completed: {succeeded} succeeded, {len(failures)} failed",
            flush=True,
        )
        return 1 if failures else 0
    finally:
        if temporary_directory is not None:
            temporary_directory.cleanup()


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    validate_arguments(parser, args)
    try:
        return run(args)
    except UploaderError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("Interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
