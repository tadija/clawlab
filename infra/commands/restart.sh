#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")/.." && pwd)/commands/core.sh"

load_host_env

progress() {
  printf '[restart] %s\n' "$1"
}

main() {
  local script_dir
  script_dir="$(cd "$(dirname "$0")" && pwd)"

  progress "stopping requested services"
  bash "$script_dir/stop.sh" "$@"
  progress "starting requested services"
  bash "$script_dir/start.sh" "$@"
  progress "completed"
}

main "$@"
