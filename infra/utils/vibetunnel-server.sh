#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
CLAWLAB_ROOT="${CLAWLAB_ROOT:-$repo_root}"

bin="${CLAWLAB_VIBETUNNEL_BIN:-}"
if [[ -z "$bin" ]]; then
  bin="$(command -v vibetunnel 2>/dev/null || true)"
fi
if [[ -z "$bin" && -x "/Applications/VibeTunnel.app/Contents/Resources/vibetunnel" ]]; then
  bin="/Applications/VibeTunnel.app/Contents/Resources/vibetunnel"
fi
bin="${bin//__CLAWLAB_ROOT__/$CLAWLAB_ROOT}"

if [[ ! -x "$bin" ]]; then
  echo "vibetunnel binary not found or not executable: $bin" >&2
  exit 1
fi

if [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]]; then
  file_info="$(file "$bin" 2>/dev/null || true)"
  if [[ "$file_info" == *"x86_64"* && "$file_info" != *"arm64"* ]]; then
    exec /usr/bin/arch -x86_64 "$bin" "$@"
  fi
fi

exec "$bin" "$@"
