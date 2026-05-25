#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/core.sh"

AELAB_LOG_PREFIX="uninstall"
load_host_env

AELAB_ROOT="${AELAB_ROOT:-$(aelab_root)}"

remove_systemd_unit() {
  local unit_name="$1"
  local unit_path="$2"

  sudo systemctl disable --now "$unit_name" >/dev/null 2>&1 || true
  if [[ -f "$unit_path" ]]; then
    sudo rm -f "$unit_path"
    return 0
  fi
  return 1
}

remove_systemd_agent_instance() {
  local agent_id="$1"

  sudo systemctl disable --now "agent@${agent_id}" >/dev/null 2>&1 || true
}

has_agent_dirs_besides() {
  local removed_agent_ids=" $* "
  local dir
  local name
  local id

  for dir in "$(repo_root)/agents"/*-*; do
    [[ -d "$dir" ]] || continue
    name="$(basename "$dir")"
    id="${name%%-*}"
    [[ "$removed_agent_ids" == *" $id "* ]] || return 0
  done

  return 1
}

remove_systemd_agent_template() {
  local -a removed_agent_ids=("$@")

  if has_agent_dirs_besides "${removed_agent_ids[@]}"; then
    return 1
  fi

  if [[ -f "$(agent_systemd_unit_path)" ]]; then
    sudo rm -f "$(agent_systemd_unit_path)"
    return 0
  fi

  return 1
}

remove_launchd_plist() {
  local label="$1"
  local plist="$2"

  sudo launchctl bootout system "$plist" >/dev/null 2>&1 || true
  sudo launchctl disable "system/$label" >/dev/null 2>&1 || true
  if [[ -f "$plist" ]]; then
    sudo rm -f "$plist"
    return 0
  fi
  return 1
}

main() {
  local explicit_args=$#
  local -a requested=()
  local item
  local total
  local index=0
  local removed_any=0
  local systemd_reload=0

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    requested+=("$item")
  done < <(resolve_requested_items "$@")

  if ((${#requested[@]} == 0)); then
    print_no_requested_items_hint
    exit 0
  fi

  total="${#requested[@]}"

  for item in "${requested[@]}"; do
    index=$((index + 1))
    log "[$index/$total] starting $item"

    if [[ "$item" == "sudoers" ]]; then
      if uninstall_sudoers_aelab; then
        removed_any=1
      fi
      log "[$index/$total] finished $item"
      continue
    fi

    if is_agent_id "$item"; then
      known_agent_kind_for_id "$item" >/dev/null || continue
      if ! agent_is_managed "$item"; then
        log "[$index/$total] skipped $item [interactive]"
      elif is_linux; then
        remove_systemd_agent_instance "$item"
      elif is_macos; then
        if remove_launchd_plist "$(service_label_for_agent "$item")" "$(agent_launchd_plist_path "$item")"; then
          removed_any=1
        fi
      else
        echo "unsupported platform: $(uname -s)"
        exit 1
      fi
    elif service_definition_exists "$item"; then
      load_service_definition "$item"
      if is_linux; then
        if remove_systemd_unit "$(service_systemd_name)" "$(service_systemd_unit_path)"; then
          removed_any=1
          systemd_reload=1
        fi
      elif is_macos; then
        if remove_launchd_plist "$(service_launchd_label)" "$(service_launchd_plist_path)"; then
          removed_any=1
        fi
      else
        echo "unsupported platform: $(uname -s)"
        exit 1
      fi
    else
      echo "unknown service or agent id: $item"
      exit 1
    fi

    log "[$index/$total] finished $item"
  done

  if is_linux; then
    local -a requested_agent_ids=()
    for item in "${requested[@]}"; do
      if is_agent_id "$item" && known_agent_kind_for_id "$item" >/dev/null && agent_is_managed "$item"; then
        requested_agent_ids+=("$item")
      fi
    done
    if ((${#requested_agent_ids[@]} > 0)); then
      if remove_systemd_agent_template "${requested_agent_ids[@]}"; then
        removed_any=1
        systemd_reload=1
      fi
    fi
  fi

  if is_linux && ((systemd_reload == 1)); then
    sudo systemctl daemon-reload
  fi

  if ((explicit_args == 0)); then
    if uninstall_sudoers_aelab; then
      removed_any=1
    fi
  fi

  if ((removed_any == 0)); then
    echo "No installed unit files or plists were removed."
  fi

  log "completed"
}

main "$@"
