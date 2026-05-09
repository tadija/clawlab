#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")/.." && pwd)/commands/core.sh"

load_host_env

CLAWLAB_ROOT="${CLAWLAB_ROOT:-$(clawlab_root)}"
CLAWLAB_USER="${CLAWLAB_USER:-}"

if [[ -z "$CLAWLAB_USER" ]]; then
  echo "CLAWLAB_USER is not set; set it in config/custom/host/.env"
  exit 1
fi

progress() {
  printf '[install] %s\n' "$1"
}

prepare_service_install() {
  local service_id="$1"
  load_service_definition "$service_id"
  case "${CLAWLAB_SERVICE_INSTALL_OPTIONAL:-}" in
    1|true|yes|on)
      return 0
      ;;
  esac
  run_service_installer "$service_id"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

install_service_unit() {
  local service_id="$1"
  local dest

  prepare_service_install "$service_id"

  if is_linux; then
    dest="$(install_systemd_service_unit "$service_id")"
    INSTALLED_PATHS+=("$dest")
    SYSTEMD_RELOAD=1
  elif is_macos; then
    INSTALLED_PATHS+=("$(install_service_launchd_plist "$service_id")")
  else
    echo "unsupported platform: $(uname -s)"
    exit 1
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
    echo "No services requested."
    exit 0
  fi

  ensure_clawlab_state_root

  INSTALLED_PATHS=()
  local index=0
  SYSTEMD_RELOAD=0
  local agent_template_installed=0
  local total="${#requested[@]}"

  for item in "${requested[@]}"; do
    index=$((index + 1))
    progress "[$index/$total] installing $item"

    if is_agent_id "$item"; then
      if is_linux; then
        if ((agent_template_installed == 0)); then
          local dest
          dest="$(install_systemd_agent_unit_template "$CLAWLAB_ROOT" "$CLAWLAB_USER")"
          INSTALLED_PATHS+=("$dest")
          SYSTEMD_RELOAD=1
          agent_template_installed=1
        fi
      elif is_macos; then
        INSTALLED_PATHS+=("$(install_launchd_agent_plist "$item" "$CLAWLAB_ROOT" "$CLAWLAB_USER")")
      else
        echo "unsupported platform: $(uname -s)"
        exit 1
      fi
    elif service_definition_exists "$item"; then
      if [[ "$item" == "caddy" ]]; then
        while IFS= read -r managed_service_id; do
          [[ -n "$managed_service_id" ]] || continue
          install_service_unit "$managed_service_id"
        done < <(caddy_managed_service_ids)
        bash "$(repo_root)/infra/commands/render.sh" caddy >/dev/null
      fi
      install_service_unit "$item"
    else
      echo "unknown service or agent id: $item"
      exit 1
    fi

    progress "[$index/$total] finished $item"
  done

  if is_linux && ((SYSTEMD_RELOAD == 1)); then
    sudo systemctl daemon-reload
    printf 'installed systemd units:\n'
  elif is_macos; then
    printf 'installed launchd plists:\n'
  fi
  printf '  %s\n' "${INSTALLED_PATHS[@]}"
  progress "completed"
}

main "$@"
