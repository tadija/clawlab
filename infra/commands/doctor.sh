#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")/.." && pwd)/commands/core.sh"

load_host_env

CLAWLAB_ROOT="${CLAWLAB_ROOT:-$(clawlab_root)}"

service_bin() {
  local tool="$1"
  local bin
  bin="$(discover_tool_path "$tool")"
  if [[ -n "$bin" ]]; then
    printf '%s' "$bin"
  else
    printf '%s' "(missing)"
  fi
}

agent_install_method() {
  local kind="$1"
  load_agent_kind_definition "$kind"
  if [[ "${CLAWLAB_AGENT_INSTALL_KIND:-}" == "script" ]]; then
    printf 'script:%s' "${CLAWLAB_AGENT_INSTALL_SCRIPT:-}"
  elif [[ -n "${CLAWLAB_AGENT_INSTALL_KIND:-}" ]]; then
    printf '%s' "$CLAWLAB_AGENT_INSTALL_KIND"
  elif [[ -n "${CLAWLAB_AGENT_BREW_PACKAGES:-}" ]]; then
    printf '%s' "brew"
  else
    printf '%s' "manual"
  fi
}

log_tail() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    echo "-- $label: $path"
    tail -n 20 "$path" || true
  fi
}

service_log_tail() {
  local item="$1"
  if is_agent_id "$item"; then
    log_tail "$(agent_stdout_log_path "$item")" "stdout"
    log_tail "$(agent_stderr_log_path "$item")" "stderr"
  elif service_definition_exists "$item"; then
    load_service_definition "$item"
    log_tail "$(service_stdout_log_path)" "stdout"
    log_tail "$(service_stderr_log_path)" "stderr"
  fi
}

service_state_for_item() {
  local item="$1"
  if is_agent_id "$item"; then
    if is_linux; then
      systemd_service_state "agent@${item}"
    else
      launchd_service_state "$(service_label_for_agent "$item")"
    fi
  elif service_definition_exists "$item"; then
    load_service_definition "$item"
    if is_linux; then
      systemd_service_state "$(service_systemd_name)"
    else
      launchd_service_state "$(service_launchd_label)"
    fi
  fi
}

main() {
  local -a requested=()
  local item

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    requested+=("$item")
  done < <(resolve_requested_items "$@")

  echo "== basics =="
  printf 'CLAWLAB_USER: %s\n' "${CLAWLAB_USER:-unset}"
  printf 'service manager: %s\n' "$(service_manager)"
  printf 'repo root: %s\n' "$CLAWLAB_ROOT"
  printf 'state dir: %s\n' "$CLAWLAB_ROOT/state"

  echo
  echo "== binaries =="
  local tool
  for tool in brew swift uv zeroclaw openclaw picoclaw hermes nanobot nullclaw moltis; do
    printf '%s -> %s\n' "$tool" "$(service_bin "$tool")"
  done

  local seen_services=""
  for item in "${requested[@]}"; do
    if is_agent_id "$item" || ! service_definition_exists "$item"; then
      continue
    fi
    case " $seen_services " in
      *" $item "*) ;;
      *)
        local resolved_bin
        load_service_definition "$item"
        resolved_bin="$(resolve_service_binary)"
        if [[ -n "$resolved_bin" ]]; then
          printf '%s -> %s\n' "$item" "$resolved_bin"
        else
          printf '%s -> %s\n' "$item" "(missing)"
        fi
        seen_services+=" $item"
        ;;
    esac
  done

  echo
  echo "== enabled agent kinds =="
  local kind
  while IFS= read -r kind; do
    [[ -n "$kind" ]] || continue
    printf '%s -> install: %s\n' "$kind" "$(agent_install_method "$kind")"
  done < <(requested_agent_kinds_from_env)

  if ((${#requested[@]} == 0)); then
    echo
    echo "No services requested."
    exit 0
  fi

  local problems=0
  local state

  echo
  echo "== requested =="
  for item in "${requested[@]}"; do
    if is_agent_id "$item" || service_definition_exists "$item"; then
      if is_agent_id "$item"; then
        repair_clawlab_agent_permissions "$item" "$CLAWLAB_USER"
      elif service_definition_exists "$item"; then
        load_service_definition "$item"
        repair_clawlab_service_permissions
      fi
      state="$(service_state_for_item "$item")"
      printf '%s: %s\n' "$item" "$state"
      if [[ "$state" != active && "$state" != running && "$state" != waiting ]]; then
        problems=$((problems + 1))
        service_log_tail "$item"
      fi
    else
      echo "unknown service or agent id: $item"
      exit 1
    fi
  done

  if ((problems > 0)); then
    echo
    printf '%s\n' "doctor: found $problems problem(s)"
    exit 1
  fi

  echo
  echo "doctor: ok"
}

main "$@"
