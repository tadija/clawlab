#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")/.." && pwd)/commands/core.sh"

load_host_env

CLAWLAB_ROOT="${CLAWLAB_ROOT:-$(clawlab_root)}"

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

  for item in "${requested[@]}"; do
    if is_agent_id "$item"; then
      if is_linux; then
        printf 'agent %s: %s (systemd/agent@%s, pid=%s)\n' "$item" "$(systemd_service_state "agent@${item}")" "$item" "$(systemd_service_pid "agent@${item}")"
      elif is_macos; then
        printf 'agent %s: %s (launchd/%s, pid=%s)\n' "$item" "$(launchd_service_state "$(service_label_for_agent "$item")")" "$(service_label_for_agent "$item")" "$(launchd_service_pid "$(service_label_for_agent "$item")")"
      else
        echo "unsupported platform: $(uname -s)"
        exit 1
      fi
    elif service_definition_exists "$item"; then
      load_service_definition "$item"
      if is_linux; then
        printf '%s: %s (systemd/%s, pid=%s)\n' "$item" "$(systemd_service_state "$(service_systemd_name)")" "$(service_systemd_name)" "$(systemd_service_pid "$(service_systemd_name)")"
        if [[ "$item" == "caddy" ]]; then
          while IFS= read -r managed_service_id; do
            [[ -n "$managed_service_id" ]] || continue
            load_service_definition "$managed_service_id"
            printf '%s: %s (systemd/%s, pid=%s)\n' "$managed_service_id" "$(systemd_service_state "$(service_systemd_name)")" "$(service_systemd_name)" "$(systemd_service_pid "$(service_systemd_name)")"
          done < <(caddy_managed_service_ids)
        fi
      elif is_macos; then
        printf '%s: %s (launchd/%s, pid=%s)\n' "$item" "$(launchd_service_state "$(service_launchd_label)")" "$(service_launchd_label)" "$(launchd_service_pid "$(service_launchd_label)")"
        if [[ "$item" == "caddy" ]]; then
          while IFS= read -r managed_service_id; do
            [[ -n "$managed_service_id" ]] || continue
            load_service_definition "$managed_service_id"
            printf '%s: %s (launchd/%s, pid=%s)\n' "$managed_service_id" "$(launchd_service_state "$(service_launchd_label)")" "$(service_launchd_label)" "$(launchd_service_pid "$(service_launchd_label)")"
          done < <(caddy_managed_service_ids)
        fi
      else
        echo "unsupported platform: $(uname -s)"
        exit 1
      fi
    else
      echo "unknown service or agent id: $item"
      exit 1
    fi
  done
}

main "$@"
