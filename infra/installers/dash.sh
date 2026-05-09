#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")/.." && pwd)/commands/core.sh"

load_host_env

output_path="$(repo_root)/infra/generated/bin/dash-server"
source_path="$(repo_root)/infra/utils/dash-server.swift"
module_cache_root="${TMPDIR:-/tmp}/clawlab-swift-module-cache"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc is required to build the dash server"
  exit 1
fi

mkdir -p "$(dirname "$output_path")" "$module_cache_root"

SWIFT_MODULECACHE_PATH="$module_cache_root" \
CLANG_MODULE_CACHE_PATH="$module_cache_root" \
swiftc -O -o "$output_path" "$source_path"

chmod +x "$output_path"

echo "[built] $output_path"
