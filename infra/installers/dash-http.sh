#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")/.." && pwd)/commands/core.sh"

load_host_env

http_output_path="$(repo_root)/infra/generated/bin/dash-http-server"
http_source_path="$(repo_root)/infra/utils/dash-http-server.swift"
module_cache_root="${TMPDIR:-/tmp}/clawlab-swift-module-cache"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc is required to build the dash http server"
  exit 1
fi

mkdir -p "$(dirname "$http_output_path")" "$module_cache_root"

SWIFT_MODULECACHE_PATH="$module_cache_root" \
CLANG_MODULE_CACHE_PATH="$module_cache_root" \
swiftc -O -o "$http_output_path" "$http_source_path"

chmod +x "$http_output_path"

log_verbose "[built] $http_output_path"
