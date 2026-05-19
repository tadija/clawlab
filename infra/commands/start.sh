#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")/.." && pwd)/commands/core.sh"

CLAWLAB_LOG_PREFIX="start"
load_host_env

CLAWLAB_ROOT="${CLAWLAB_ROOT:-$(clawlab_root)}"
CLAWLAB_USER="${CLAWLAB_USER:-}"

if [[ -z "$CLAWLAB_USER" ]]; then
  echo "CLAWLAB_USER is not set; set it in config/custom/host/.env"
  exit 1
fi

usage() {
  cat <<'EOF'
Usage:
  start.sh [service-or-agent...]

Examples:
  ./commands/start.sh tailscale caddy 000 004 007
  CLAWLAB_SERVICES="tailscale caddy" CLAWLAB_AGENTS="000 004 007" ./commands/start.sh
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
  log_verbose "refreshing agent service-manager artifact for $agent_id"
  plist="$(install_launchd_agent_plist "$agent_id" "$CLAWLAB_ROOT" "$CLAWLAB_USER")"
  sudo launchctl bootout system "$plist" >/dev/null 2>&1 || true
  sudo launchctl enable "system/$label"
  sudo launchctl bootstrap system "$plist"
  sudo launchctl kickstart -k "system/$label"
}

start_service() {
  local service_id="$1"

  load_service_definition "$service_id"
  repair_clawlab_service_permissions
  log_verbose "refreshing service-manager artifact for $service_id"
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
  if [[ "$service_id" == "dash-http" ]]; then
    bash "$(repo_root)/infra/commands/render.sh" dash
  elif [[ "$service_id" == "caddy" ]]; then
    bash "$(repo_root)/infra/commands/render.sh" caddy
  fi
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
    usage
    echo "No services requested."
    echo "Set CLAWLAB_SERVICES or CLAWLAB_AGENTS to use env defaults."
    exit 0
  fi

  local total="${#requested[@]}"
  local index=0
  local agent_template_installed=0
  for item in "${requested[@]}"; do
    index=$((index + 1))
    log_verbose "[$index/$total] starting $item"
    if is_agent_id "$item"; then
      known_agent_kind_for_id "$item" >/dev/null || continue
      if ! agent_is_managed "$item"; then
        log_verbose "[$index/$total] skipped $item [interactive]"
        continue
      fi
      repair_clawlab_agent_permissions "$item" "$CLAWLAB_USER"
      if is_linux; then
        if ((agent_template_installed == 0)); then
          log_verbose "refreshing agent service-manager artifact"
          install_systemd_agent_unit_template "$CLAWLAB_ROOT" "$CLAWLAB_USER" >/dev/null
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
      if [[ "$item" == "caddy" ]]; then
        while IFS= read -r managed_service_id; do
          [[ -n "$managed_service_id" ]] || continue
          prepare_service_start "$managed_service_id"
          start_service "$managed_service_id"
        done < <(caddy_managed_service_ids)
      fi

      prepare_service_start "$item"
      start_service "$item"
    else
      echo "unknown service or agent id: $item"
      exit 1
    fi
    log_verbose "[$index/$total] finished $item"
  done

  log_verbose "completed"
}

main "$@"
