#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/core.sh"

load_host_env

AELAB_ROOT="${AELAB_ROOT:-$(aelab_root)}"

usage() {
  cat <<'EOF'
Usage:
  status.sh [--details] [service-or-agent...]
EOF
}

SUMMARY_AGENT_CONFIGURED=0
SUMMARY_SERVICE_CONFIGURED=0
SUMMARY_RUNNING_AGENTS=()
SUMMARY_INTERACTIVE_AGENTS=()
SUMMARY_RUNNING_SERVICES=()
STATUS_MODE="compact"

local_port_listening() {
  local port="$1"

  [[ -n "$port" ]] || return 1

  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$port" >/dev/null 2>&1
    return $?
  fi

  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi

  return 1
}

service_manager_name_for_item() {
  local item="$1"

  if is_agent_id "$item"; then
    if ! agent_is_managed "$item"; then
      printf '%s' "interactive"
      return 0
    fi
    if is_linux; then
      printf 'systemd/agent@%s' "$item"
    else
      printf 'launchd/%s' "$(service_label_for_agent "$item")"
    fi
    return 0
  fi

  load_service_definition "$item"
  if is_linux; then
    printf 'systemd/%s' "$(service_systemd_name)"
  else
    printf 'launchd/%s' "$(service_launchd_label)"
  fi
}

item_state() {
  local item="$1"

  if is_agent_id "$item"; then
    if ! agent_is_managed "$item"; then
      printf '%s' "interactive"
      return 0
    fi
    if is_linux; then
      systemd_service_state "agent@${item}"
    else
      launchd_service_state "$(service_label_for_agent "$item")"
    fi
    return 0
  fi

  load_service_definition "$item"
  if is_linux; then
    systemd_service_state "$(service_systemd_name)"
  else
    launchd_service_state "$(service_launchd_label)"
  fi
}

item_pid() {
  local item="$1"

  if is_agent_id "$item"; then
    if ! agent_is_managed "$item"; then
      printf '%s' "-"
      return 0
    fi
    if is_linux; then
      systemd_service_pid "agent@${item}"
    else
      launchd_service_pid "$(service_label_for_agent "$item")"
    fi
    return 0
  fi

  load_service_definition "$item"
  if is_linux; then
    systemd_service_pid "$(service_systemd_name)"
  else
    launchd_service_pid "$(service_launchd_label)"
  fi
}

item_port() {
  local item="$1"

  if is_agent_id "$item"; then
    printf '%s' "$(repo_cfg_value "agent-ports" "$item")"
  else
    load_service_definition "$item"
    printf '%s' "${AELAB_SERVICE_PORT:-}"
  fi
}

join_by_comma() {
  local -a values=("$@")
  local first=1
  local value

  if ((${#values[@]} == 0)); then
    printf '%s' "-"
    return 0
  fi

  for value in "${values[@]}"; do
    if ((first)); then
      printf '%s' "$value"
      first=0
    else
      printf ', %s' "$value"
    fi
  done
}

print_item_status() {
  local item="$1"
  local label="$item"
  local item_type="service"
  local kind="-"
  local manager
  local state
  local pid
  local port
  local port_detail="-"

  if is_agent_id "$item"; then
    item_type="agent"
    kind="$(agent_kind_for_id "$item" 2>/dev/null || printf '%s' "unknown")"
    label="${item} (${kind})"
    SUMMARY_AGENT_CONFIGURED=$((SUMMARY_AGENT_CONFIGURED + 1))
  else
    SUMMARY_SERVICE_CONFIGURED=$((SUMMARY_SERVICE_CONFIGURED + 1))
  fi

  manager="$(service_manager_name_for_item "$item")"
  state="$(item_state "$item")"
  pid="$(item_pid "$item")"
  port="$(item_port "$item")"

  case "$state" in
    active|running|waiting)
      if [[ "$item_type" == "agent" ]]; then
        SUMMARY_RUNNING_AGENTS+=("$label")
      else
        SUMMARY_RUNNING_SERVICES+=("$item")
      fi
      ;;
    interactive)
      if [[ "$item_type" == "agent" ]]; then
        SUMMARY_INTERACTIVE_AGENTS+=("$label")
      fi
      ;;
  esac

  if [[ -n "$port" ]]; then
    if local_port_listening "$port"; then
      port_detail="${port} (listening)"
    else
      port_detail="${port} (closed)"
    fi
  fi

  printf '%s %s\n' "$item_type:" "$label"
  printf '  manager:    %s\n' "$manager"
  printf '  state:      %s\n' "$state"
  printf '  pid:        %s\n' "$pid"
  printf '  port:       %s\n' "$port_detail"
}

print_item_status_compact() {
  local item="$1"

  if is_agent_id "$item"; then
    local agent_name
    local agent_kind
    agent_name="$(printf '%s' "$item")"
    if ! agent_kind="$(agent_kind_for_id "$item" 2>/dev/null)"; then
      printf 'agent %s: unknown (unable to determine kind)\n' "$agent_name" >&2
      return 1
    fi
    if [[ ! -f "$(agent_kind_manifest_path "$agent_kind")" && ! -f "$(custom_agent_kind_manifest_path "$agent_kind")" ]]; then
      printf 'agent %s (%s): unknown kind manifest\n' "$agent_name" "$agent_kind" >&2
      return 1
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
    return 0
  fi

  if service_definition_exists "$item"; then
    load_service_definition "$item"
    if is_linux; then
      printf '%s: %s (systemd/%s, pid=%s)\n' "$item" "$(systemd_service_state "$(service_systemd_name)")" "$(service_systemd_name)" "$(systemd_service_pid "$(service_systemd_name)")"
    elif is_macos; then
      printf '%s: %s (launchd/%s, pid=%s)\n' "$item" "$(launchd_service_state "$(service_launchd_label)")" "$(service_launchd_label)" "$(launchd_service_pid "$(service_launchd_label)")"
    else
      echo "unsupported platform: $(uname -s)"
      exit 1
    fi
    return 0
  fi

  echo "unknown service or agent id: $item" >&2
  return 1
}

main() {
  local -a requested=()
  local item
  local had_error=0

  while (($#)); do
    case "$1" in
      --details)
        STATUS_MODE="details"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        break
        ;;
    esac
  done

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
      if ! agent_kind_for_id "$item" >/dev/null 2>&1; then
        echo "unknown agent id: $item" >&2
        had_error=1
        continue
      fi
    elif ! service_definition_exists "$item"; then
      echo "unknown service id: $item" >&2
      had_error=1
      continue
    fi

    if [[ "$STATUS_MODE" == "details" ]]; then
      print_item_status "$item"
      echo
    else
      if ! print_item_status_compact "$item"; then
        had_error=1
      fi
    fi
  done

  if [[ "$STATUS_MODE" == "details" ]]; then
    echo "summary:"
    echo "  agents:"
    printf '    configured:  %d\n' "$SUMMARY_AGENT_CONFIGURED"
    printf '    running:     %d (%s)\n' \
      "${#SUMMARY_RUNNING_AGENTS[@]}" \
      "$(join_by_comma "${SUMMARY_RUNNING_AGENTS[@]}")"
    printf '    interactive: %d (%s)\n' \
      "${#SUMMARY_INTERACTIVE_AGENTS[@]}" \
      "$(join_by_comma "${SUMMARY_INTERACTIVE_AGENTS[@]}")"
    echo "  services:"
    printf '    configured:  %d\n' "$SUMMARY_SERVICE_CONFIGURED"
    printf '    running:     %d (%s)\n' \
      "${#SUMMARY_RUNNING_SERVICES[@]}" \
      "$(join_by_comma "${SUMMARY_RUNNING_SERVICES[@]}")"
  fi

  exit "$had_error"
}

main "$@"
