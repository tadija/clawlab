#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")/.." && pwd)/commands/core.sh"

CLAWLAB_LOG_PREFIX="stop"
load_host_env

CLAWLAB_ROOT="${CLAWLAB_ROOT:-$(clawlab_root)}"

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
  local managed_service_id

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    requested+=("$item")
  done < <(resolve_requested_items "$@")

  if ((${#requested[@]} == 0)); then
    echo "No services requested."
    exit 0
  fi

  local total="${#requested[@]}"
  local index=0
  for item in "${requested[@]}"; do
    index=$((index + 1))
    log_verbose "[$index/$total] stopping $item"
    if is_agent_id "$item"; then
      known_agent_kind_for_id "$item" >/dev/null || continue
      if ! agent_is_managed "$item"; then
        log_verbose "[$index/$total] skipped $item [interactive]"
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
      if [[ "$item" == "caddy" ]]; then
        while IFS= read -r managed_service_id; do
          [[ -n "$managed_service_id" ]] || continue
          load_service_definition "$managed_service_id"
          if is_linux; then
            stop_systemd_service "$(service_systemd_name)"
          elif is_macos; then
            stop_launchd_service "$(service_launchd_label)" "$(service_launchd_plist_path)"
          else
            echo "unsupported platform: $(uname -s)"
            exit 1
          fi
        done < <(caddy_managed_service_ids)
      fi
    else
      echo "unknown service or agent id: $item"
      exit 1
    fi
    log_verbose "[$index/$total] finished $item"
  done

  log_verbose "completed"
}

main "$@"
