#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")/../.." && pwd)/commands/core.sh"

load_host_env

output_path="$(repo_root)/infra/generated/bin/aelab-tty"
source_path="$(repo_root)/infra/core/tty-server.swift"
module_cache_root="${TMPDIR:-/tmp}/aelab-swift-module-cache"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc is required to build the TTY server"
  exit 1
fi

mkdir -p "$(dirname "$output_path")" "$module_cache_root"

SWIFT_MODULECACHE_PATH="$module_cache_root" \
CLANG_MODULE_CACHE_PATH="$module_cache_root" \
swiftc -O -o "$output_path" "$source_path"

chmod +x "$output_path"

log --verbose "[built] $output_path"
