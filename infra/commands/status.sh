#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/core.sh"

load_host_env

AELAB_ROOT="${AELAB_ROOT:-$(aelab_root)}"

main() {
  local -a requested=()
  local item
  local had_error=0

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    requested+=("$item")
  done < <(resolve_requested_items "$@")

  if ((${#requested[@]} == 0)); then
    print_no_requested_items_hint
    exit 0
  fi

  for item in "${requested[@]}"; do
    if is_agent_id "$item"; then
      local agent_name
      local agent_kind
      agent_name="$(printf '%s' "$item")"
      if ! agent_kind="$(agent_kind_for_id "$item" 2>/dev/null)"; then
        printf 'agent %s: unknown (unable to determine kind)\n' "$agent_name" >&2
        had_error=1
        continue
      fi
      if [[ ! -f "$(agent_kind_manifest_path "$agent_kind")" && ! -f "$(custom_agent_kind_manifest_path "$agent_kind")" ]]; then
        printf 'agent %s (%s): unknown kind manifest\n' "$agent_name" "$agent_kind" >&2
        had_error=1
        continue
      fi
      if ! agent_is_managed "$item"; then
        printf 'agent %s (%s): interactive\n' "$agent_name" "$agent_kind"
      elif is_linux; then
        printf 'agent %s (%s): %s (systemd/agent@%s, pid=%s)\n' "$agent_name" "$agent_kind" "$(systemd_service_state "agent@${item}")" "$item" "$(systemd_service_pid "agent@${item}")"
      elif is_macos; then
        printf 'agent %s (%s): %s (launchd/%s, pid=%s)\n' "$agent_name" "$agent_kind" "$(launchd_service_state "$(service_label_for_agent "$item")")" "$(service_label_for_agent "$item")" "$(launchd_service_pid "$(service_label_for_agent "$item")")"
      else
        echo "unsupported platform: $(uname -s)"
        exit 1
      fi
    elif service_definition_exists "$item"; then
      load_service_definition "$item"
      if is_linux; then
        printf '%s: %s (systemd/%s, pid=%s)\n' "$item" "$(systemd_service_state "$(service_systemd_name)")" "$(service_systemd_name)" "$(systemd_service_pid "$(service_systemd_name)")"
      elif is_macos; then
        printf '%s: %s (launchd/%s, pid=%s)\n' "$item" "$(launchd_service_state "$(service_launchd_label)")" "$(service_launchd_label)" "$(launchd_service_pid "$(service_launchd_label)")"
      else
        echo "unsupported platform: $(uname -s)"
        exit 1
      fi
    else
      echo "unknown service or agent id: $item"
      had_error=1
      continue
    fi
  done

  exit "$had_error"
}

main "$@"
