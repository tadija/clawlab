#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/core.sh"

AELAB_LOG_PREFIX="start"
load_host_env

AELAB_ROOT="${AELAB_ROOT:-$(aelab_root)}"
AELAB_USER="${AELAB_USER:-}"

if [[ -z "$AELAB_USER" ]]; then
  echo "AELAB_USER is not set; set it in config/host.toml"
  exit 1
fi

usage() {
  cat <<'EOF'
Usage:
  start.sh [service-or-agent...]

Examples:
  ./commands/start.sh core 000 004 007
  AELAB_SERVICES="core" AELAB_AGENTS="000 004 007" ./commands/start.sh
EOF
}

start_systemd_service() {
  local service="$1"
  if verbose_enabled; then
    sudo systemctl enable --now "$service"
  else
    sudo systemctl enable --now "$service" >/dev/null
  fi
}

start_launchd_service() {
  local label="$1"
  local plist="$2"
  sudo launchctl bootout system "$plist" >/dev/null 2>&1 || true
  sudo launchctl enable "system/$label"
  sudo launchctl bootstrap system "$plist"
  sudo launchctl kickstart -k "system/$label"
}

start_launchd_agent() {
  local agent_id="$1"
  local label
  local plist
  label="$(service_label_for_agent "$agent_id")"
  log --verbose "refreshing agent service-manager artifact for $agent_id"
  plist="$(install_launchd_agent_plist "$agent_id" "$AELAB_ROOT" "$AELAB_USER")"
  sudo launchctl bootout system "$plist" >/dev/null 2>&1 || true
  sudo launchctl enable "system/$label"
  sudo launchctl bootstrap system "$plist"
  sudo launchctl kickstart -k "system/$label"
}

start_service() {
  local service_id="$1"

  load_service_definition "$service_id"
  repair_aelab_service_permissions
  log --verbose "refreshing service-manager artifact for $service_id"
  if is_linux; then
    install_systemd_service_unit "$service_id" >/dev/null
    sudo systemctl daemon-reload
    start_systemd_service "$(service_systemd_name)"
  elif is_macos; then
    start_launchd_service "$(service_launchd_label)" "$(install_service_launchd_plist "$service_id")"
  else
    echo "unsupported platform: $(uname -s)"
    exit 1
  fi
}

prepare_service_start() {
  local service_id="$1"
  run_service_installer "$service_id"
  if [[ "$service_id" == "core-http" ]]; then
    bash "$(repo_root)/infra/commands/render.sh" front
  elif [[ "$service_id" == "caddy" ]]; then
    bash "$(repo_root)/infra/commands/render.sh" caddy
  fi
}

main() {
  local -a requested=()
  local item

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    requested+=("$item")
  done < <(resolve_requested_items "$@")

  if ((${#requested[@]} == 0)); then
    usage
    print_no_requested_items_hint
    exit 0
  fi

  local total="${#requested[@]}"
  local index=0
  local agent_template_installed=0
  for item in "${requested[@]}"; do
    index=$((index + 1))
    log --verbose "[$index/$total] starting $item"
    if is_agent_id "$item"; then
      known_agent_kind_for_id "$item" >/dev/null || continue
      if ! agent_is_managed "$item"; then
        log --verbose "[$index/$total] skipped $item [interactive]"
        log "skipped agent $item [interactive]"
        continue
      fi
      repair_aelab_agent_permissions "$item" "$AELAB_USER"
      if is_linux; then
        if ((agent_template_installed == 0)); then
          log --verbose "refreshing agent service-manager artifact"
          install_systemd_agent_unit_template "$AELAB_ROOT" "$AELAB_USER" >/dev/null
          sudo systemctl daemon-reload
          agent_template_installed=1
        fi
        start_systemd_service "agent@${item}"
      elif is_macos; then
        start_launchd_agent "$item"
      else
        echo "unsupported platform: $(uname -s)"
        exit 1
      fi
    elif service_definition_exists "$item"; then
      prepare_service_start "$item"
      start_service "$item"
    else
      echo "unknown service or agent id: $item"
      exit 1
    fi
    if is_agent_id "$item"; then
      log "started agent $item"
    else
      log "started service $item"
    fi
    log --verbose "[$index/$total] finished $item"
  done

  log --verbose "completed"
}

main "$@"
