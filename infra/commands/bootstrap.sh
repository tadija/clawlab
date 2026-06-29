#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/core.sh"

AELAB_LOG_PREFIX="bootstrap"
load_host_env

INFRA_DIR="$(infra_root)"
AELAB_ROOT="${AELAB_ROOT:-$(aelab_root)}"

run_agent_kind_installers() {
  local kind
  local script_path

  while IFS= read -r kind; do
    [[ -n "$kind" ]] || continue
    load_agent_kind_definition "$kind"
    case "${AELAB_AGENT_INSTALL_KIND:-}" in
      "")
        ;;
      script)
        script_path="$(repo_root)/${AELAB_AGENT_INSTALL_SCRIPT:-}"
        if [[ -z "${AELAB_AGENT_INSTALL_SCRIPT:-}" || ! -f "$script_path" ]]; then
          echo "agent kind ${kind} is missing a valid AELAB_AGENT_INSTALL_SCRIPT"
          exit 1
        fi
        log "installing agent runtime for ${kind}"
        bash "$script_path"
        ;;
      *)
        echo "unsupported AELAB_AGENT_INSTALL_KIND for ${kind}: ${AELAB_AGENT_INSTALL_KIND}"
        exit 1
        ;;
    esac
  done < <(requested_agent_kinds_from_env)
}

run_service_installers() {
  local service_id

  while IFS= read -r service_id; do
    [[ -n "$service_id" ]] || continue
    load_service_definition "$service_id"
    case "${AELAB_SERVICE_INSTALL_KIND:-}" in
      "")
        ;;
      *)
        log "installing service runtime for ${service_id}"
        run_service_installer "$service_id"
        ;;
    esac
  done < <(requested_service_ids_from_env)
}

cleanup_linux() {
  local removed_any=0
  local systemd_reload=0
  local service_id
  local unit_path
  local agent_id
  local has_agents=0

  while IFS= read -r service_id; do
    [[ -n "$service_id" ]] || continue
    if service_requested_from_env "$service_id"; then
      continue
    fi
    load_service_definition "$service_id"
    unit_path="$(service_systemd_unit_path)"
    if [[ -f "$unit_path" ]]; then
      log "removing leftover $(service_systemd_name)"
      sudo systemctl disable --now "$(service_systemd_name)" >/dev/null 2>&1 || true
      sudo rm -f "$unit_path"
      removed_any=1
      systemd_reload=1
    fi
  done < <(service_definition_ids)

  while IFS= read -r agent_id; do
    [[ -n "$agent_id" ]] || continue
    has_agents=1
    break
  done < <(requested_agent_ids_from_env)

  if ((has_agents == 0)) && [[ -f "$(agent_systemd_unit_path)" ]]; then
    log "removing leftover agent@ template"
    sudo systemctl disable --now "agent@" >/dev/null 2>&1 || true
    sudo rm -f "$(agent_systemd_unit_path)"
    removed_any=1
    systemd_reload=1
  fi

  if ((systemd_reload == 1)); then
    sudo systemctl daemon-reload
  fi

  if ((removed_any == 0)); then
    log "no leftover systemd units found"
  fi
}

cleanup_macos() {
  local removed_any=0
  local service_id
  local plist
  local label
  local preserved_ids=""
  local agent_id
  local current_id

  while IFS= read -r agent_id; do
    [[ -n "$agent_id" ]] || continue
    preserved_ids+=" $agent_id"
  done < <(requested_agent_ids_from_env)

  while IFS= read -r service_id; do
    [[ -n "$service_id" ]] || continue
    preserved_ids+=" $service_id"
  done < <(requested_service_ids_from_env)

  while IFS= read -r service_id; do
    [[ -n "$service_id" ]] || continue
    if service_requested_from_env "$service_id"; then
      continue
    fi
    load_service_definition "$service_id"
    plist="$(service_launchd_plist_path)"
    label="$(service_launchd_label)"
    if [[ -f "$plist" ]]; then
      log "removing leftover $label"
      sudo launchctl bootout system "$plist" >/dev/null 2>&1 || true
      sudo launchctl disable "system/$label" >/dev/null 2>&1 || true
      sudo rm -f "$plist"
      removed_any=1
    fi
  done < <(service_definition_ids)

  for plist in /Library/LaunchDaemons/"$(launchd_label_prefix)".*.plist; do
    [[ -e "$plist" ]] || continue
    current_id="${plist##*.aelab.}"
    current_id="${current_id%.plist}"
    case " $preserved_ids " in
      *" $current_id "*) ;;
      *)
        label="$(launchd_label_prefix).${current_id}"
        log "removing leftover $label"
        sudo launchctl bootout system "$plist" >/dev/null 2>&1 || true
        sudo launchctl disable "system/$label" >/dev/null 2>&1 || true
        sudo rm -f "$plist"
        removed_any=1
        ;;
    esac
  done

  if ((removed_any == 0)); then
    log "no leftover launchd plists found"
  fi
}

cleanup_service_manager_artifacts() {
  if is_linux; then
    cleanup_linux
  elif is_macos; then
    cleanup_macos
  else
    echo "unsupported platform: $(uname -s)"
    exit 1
  fi
}

ensure_homebrew() {
  local candidate

  if command -v brew >/dev/null 2>&1; then
    return 0
  fi

  log "installing Homebrew"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  for candidate in \
    /opt/homebrew/bin/brew \
    /usr/local/bin/brew \
    /home/linuxbrew/.linuxbrew/bin/brew \
    "${HOME}/.linuxbrew/bin/brew"; do
    if [[ -x "$candidate" ]]; then
      eval "$("$candidate" shellenv)"
      break
    fi
  done

  if ! command -v brew >/dev/null 2>&1; then
    echo "brew install completed but brew not found on PATH — open a new shell and re-run" >&2
    exit 1
  fi
}

ensure_homebrew

log "running preflight checks"
bash "$(repo_root)/infra/commands/preflight.sh" "$@"

log "rendering Brewfile"
bash "$(repo_root)/infra/commands/render.sh" brew
ensure_aelab_state_root
cleanup_service_manager_artifacts
log "installing Homebrew dependencies"
brew bundle --file "$INFRA_DIR/generated/Brewfile"
run_agent_kind_installers
run_service_installers

log "installing service-manager artifacts"
bash "$(repo_root)/infra/commands/install.sh" "$@"

log "complete"
