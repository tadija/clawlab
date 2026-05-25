#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/core.sh"

AELAB_LOG_PREFIX="install"
load_host_env

AELAB_ROOT="${AELAB_ROOT:-$(aelab_root)}"
AELAB_USER="${AELAB_USER:-}"

if [[ -z "$AELAB_USER" ]]; then
  echo "AELAB_USER is not set; set it in config/custom/host/.env"
  exit 1
fi

prepare_service_install() {
  local service_id="$1"
  load_service_definition "$service_id"
  case "${AELAB_SERVICE_INSTALL_OPTIONAL:-}" in
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

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    requested+=("$item")
  done < <(resolve_requested_items "$@")

  if ((${#requested[@]} == 0)); then
    print_no_requested_items_hint
    exit 0
  fi

  ensure_aelab_state_root
  install_sudoers_aelab

  INSTALLED_PATHS=()
  local index=0
  SYSTEMD_RELOAD=0
  local agent_template_installed=0
  local total="${#requested[@]}"

  for item in "${requested[@]}"; do
    index=$((index + 1))
    log --verbose "[$index/$total] installing $item"

    if [[ "$item" == "sudoers" ]]; then
      log --verbose "[$index/$total] finished $item"
      continue
    fi

    if is_agent_id "$item"; then
      known_agent_kind_for_id "$item" >/dev/null || continue
      if ! agent_is_managed "$item"; then
        log --verbose "[$index/$total] skipped $item [interactive]"
        log "skipped agent $item [interactive]"
      elif is_linux; then
        if ((agent_template_installed == 0)); then
          local dest
          dest="$(install_systemd_agent_unit_template "$AELAB_ROOT" "$AELAB_USER")"
          INSTALLED_PATHS+=("$dest")
          SYSTEMD_RELOAD=1
          agent_template_installed=1
        fi
      elif is_macos; then
        INSTALLED_PATHS+=("$(install_launchd_agent_plist "$item" "$AELAB_ROOT" "$AELAB_USER")")
      else
        echo "unsupported platform: $(uname -s)"
        exit 1
      fi
    elif service_definition_exists "$item"; then
      if [[ "$item" == "caddy" ]]; then
        bash "$(repo_root)/infra/commands/render.sh" caddy >/dev/null
      fi
      install_service_unit "$item"
    else
      echo "unknown service or agent id: $item"
      exit 1
    fi

    log --verbose "[$index/$total] finished $item"
  done

  if ((${#INSTALLED_PATHS[@]} == 0)); then
    log "no service-manager artifacts installed"
  elif is_linux && ((SYSTEMD_RELOAD == 1)); then
    sudo systemctl daemon-reload
    printf 'installed systemd units:\n'
  elif is_macos; then
    printf 'installed launchd plists:\n'
  fi
  if ((${#INSTALLED_PATHS[@]} > 0)); then
    printf '  %s\n' "${INSTALLED_PATHS[@]}"
  fi
  log --verbose "completed"
}

main "$@"
