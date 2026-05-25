#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/core.sh"

AELAB_LOG_PREFIX="stop"
load_host_env

AELAB_ROOT="${AELAB_ROOT:-$(aelab_root)}"

stop_systemd_service() {
  local service="$1"
  if verbose_enabled; then
    sudo systemctl disable --now "$service"
  else
    sudo systemctl disable --now "$service" >/dev/null
  fi
}

stop_launchd_service() {
  local label="$1"
  local plist="$2"
  sudo launchctl bootout system "$plist" >/dev/null 2>&1 || true
  sudo launchctl disable "system/$label" || true
}

stop_launchd_agent() {
  local agent_id="$1"
  local label
  label="$(service_label_for_agent "$agent_id")"
  stop_launchd_service "$label" "/Library/LaunchDaemons/${label}.plist"
}

main() {
  local -a requested=()
  local item

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    requested+=("$item")
  done < <(resolve_requested_items "$@")

  if ((${#requested[@]} == 0)); then
    print_no_requested_items_hint
    exit 0
  fi

  local total="${#requested[@]}"
  local index=0
  for item in "${requested[@]}"; do
    index=$((index + 1))
    log --verbose "[$index/$total] stopping $item"
    if is_agent_id "$item"; then
      known_agent_kind_for_id "$item" >/dev/null || continue
      if ! agent_is_managed "$item"; then
        log --verbose "[$index/$total] skipped $item [interactive]"
        log "skipped agent $item [interactive]"
        continue
      fi
      if is_linux; then
        stop_systemd_service "agent@${item}"
      elif is_macos; then
        stop_launchd_agent "$item"
      else
        echo "unsupported platform: $(uname -s)"
        exit 1
      fi
    elif service_definition_exists "$item"; then
      load_service_definition "$item"
      if is_linux; then
        stop_systemd_service "$(service_systemd_name)"
      elif is_macos; then
        stop_launchd_service "$(service_launchd_label)" "$(service_launchd_plist_path)"
      else
        echo "unsupported platform: $(uname -s)"
        exit 1
      fi
    else
      echo "unknown service or agent id: $item"
      exit 1
    fi
    if is_agent_id "$item"; then
      log "stopped agent $item"
    else
      log "stopped service $item"
    fi
    log --verbose "[$index/$total] finished $item"
  done

  log --verbose "completed"
}

main "$@"
