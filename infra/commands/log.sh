#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/core.sh"

load_host_env

AELAB_ROOT="${AELAB_ROOT:-$(aelab_root)}"
TAIL_LINES=50

usage() {
  cat <<'EOF'
Usage:
  log.sh [--short|-s] [--lines N|-n N] [service-or-agent...]
EOF
}

log_tail() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    echo "-- $label: $path"
    tail -n "$TAIL_LINES" "$path" || true
  else
    echo "-- $label: $path (missing)"
  fi
}

print_logs_for_item() {
  local item="$1"
  if is_agent_id "$item"; then
    log_tail "$(agent_stdout_log_path "$item")" "stdout"
    log_tail "$(agent_stderr_log_path "$item")" "stderr"
  elif service_definition_exists "$item"; then
    load_service_definition "$item"
    log_tail "$(service_stdout_log_path)" "stdout"
    log_tail "$(service_stderr_log_path)" "stderr"
  else
    echo "unknown service or agent id: $item"
    exit 1
  fi
}

main() {
  local -a requested=()
  local arg

  while (($#)); do
    arg="$1"
    shift
    case "$arg" in
      -s|--short)
        TAIL_LINES=4
        ;;
      -n|--lines)
        if (($# == 0)); then
          usage
          echo "missing value for $arg"
          exit 1
        fi
        TAIL_LINES="$1"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        requested+=("$arg")
        ;;
    esac
  done

  if ((${#requested[@]} == 0)); then
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      requested+=("$item")
    done < <(resolve_requested_items)
  else
    local -a expanded_requested=()
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      expanded_requested+=("$item")
    done < <(resolve_requested_items "${requested[@]}")
    requested=("${expanded_requested[@]}")
  fi

  if ((${#requested[@]} == 0)); then
    print_no_requested_items_hint
    exit 0
  fi

  local item
  local first=1
  for item in "${requested[@]}"; do
    if ((first == 0)); then
      echo
      echo "------------------------------------------------------------"
      echo
    fi
    echo "== $item =="
    print_logs_for_item "$item"
    first=0
  done
}

main "$@"
