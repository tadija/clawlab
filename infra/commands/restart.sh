#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/core.sh"

AELAB_LOG_PREFIX="restart"
load_host_env

main() {
  local -a requested=()
  local item
  local script_dir
  script_dir="$(cd "$(dirname "$0")" && pwd)"

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    requested+=("$item")
  done < <(resolve_requested_items "$@")

  for item in "${requested[@]}"; do
    if is_agent_id "$item"; then
      known_agent_kind_for_id "$item" >/dev/null || true
    fi
  done

  log "stopping requested services"
  bash "$script_dir/stop.sh" "$@"
  log "starting requested services"
  bash "$script_dir/start.sh" "$@"
  log "completed"
}

main "$@"
