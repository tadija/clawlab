#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")/.." && pwd)/commands/core.sh"

load_host_env

INFRA_DIR="$(infra_root)"
CLAWLAB_ROOT="${CLAWLAB_ROOT:-$(clawlab_root)}"

progress() {
  printf '[bootstrap] %s\n' "$1"
}

run_agent_kind_installers() {
  local kind
  local script_path

  while IFS= read -r kind; do
    [[ -n "$kind" ]] || continue
    load_agent_kind_definition "$kind"
    case "${CLAWLAB_AGENT_INSTALL_KIND:-}" in
      "")
        ;;
      script)
        script_path="$(repo_root)/${CLAWLAB_AGENT_INSTALL_SCRIPT:-}"
        if [[ -z "${CLAWLAB_AGENT_INSTALL_SCRIPT:-}" || ! -f "$script_path" ]]; then
          echo "agent kind ${kind} is missing a valid CLAWLAB_AGENT_INSTALL_SCRIPT"
          exit 1
        fi
        progress "installing agent runtime for ${kind}"
        bash "$script_path"
        ;;
      *)
        echo "unsupported CLAWLAB_AGENT_INSTALL_KIND for ${kind}: ${CLAWLAB_AGENT_INSTALL_KIND}"
        exit 1
        ;;
    esac
  done < <(requested_agent_kinds_from_env)
}

run_service_installers() {
  local service_id
  local managed_service_id

  while IFS= read -r service_id; do
    [[ -n "$service_id" ]] || continue
    if [[ "$service_id" == "caddy" ]]; then
      while IFS= read -r managed_service_id; do
        [[ -n "$managed_service_id" ]] || continue
        progress "installing service runtime for ${managed_service_id}"
        run_service_installer "$managed_service_id"
      done < <(caddy_managed_service_ids)
    fi
    load_service_definition "$service_id"
    case "${CLAWLAB_SERVICE_INSTALL_KIND:-}" in
      "")
        ;;
      *)
        progress "installing service runtime for ${service_id}"
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
  local managed_by_caddy
  local managed_service_id

  while IFS= read -r service_id; do
    [[ -n "$service_id" ]] || continue
    managed_by_caddy=0
    if service_requested_from_env "caddy"; then
      while IFS= read -r managed_service_id; do
        if [[ "$managed_service_id" == "$service_id" ]]; then
          managed_by_caddy=1
          break
        fi
      done < <(caddy_managed_service_ids)
    fi
    if ((managed_by_caddy == 1)); then
      continue
    elif service_requested_from_env "$service_id"; then
      continue
    fi
    load_service_definition "$service_id"
    unit_path="$(service_systemd_unit_path)"
    if [[ -f "$unit_path" ]]; then
      progress "removing leftover $(service_systemd_name)"
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
    progress "removing leftover agent@ template"
    sudo systemctl disable --now "agent@" >/dev/null 2>&1 || true
    sudo rm -f "$(agent_systemd_unit_path)"
    removed_any=1
    systemd_reload=1
  fi

  if ((systemd_reload == 1)); then
    sudo systemctl daemon-reload
  fi

  if ((removed_any == 0)); then
    progress "no leftover systemd units found"
  fi
}

cleanup_macos() {
  local removed_any=0
  local service_id
  local plist
  local label
  local requested_agents=""
  local agent_id
  local current_id
  local managed_by_caddy
  local managed_service_id

  while IFS= read -r agent_id; do
    [[ -n "$agent_id" ]] || continue
    requested_agents+=" $agent_id"
  done < <(requested_agent_ids_from_env)

  while IFS= read -r service_id; do
    [[ -n "$service_id" ]] || continue
    managed_by_caddy=0
    if service_requested_from_env "caddy"; then
      while IFS= read -r managed_service_id; do
        if [[ "$managed_service_id" == "$service_id" ]]; then
          managed_by_caddy=1
          break
        fi
      done < <(caddy_managed_service_ids)
    fi
    if ((managed_by_caddy == 1)); then
      continue
    elif service_requested_from_env "$service_id"; then
      continue
    fi
    load_service_definition "$service_id"
    plist="$(service_launchd_plist_path)"
    label="$(service_launchd_label)"
    if [[ -f "$plist" ]]; then
      progress "removing leftover $label"
      sudo launchctl bootout system "$plist" >/dev/null 2>&1 || true
      sudo launchctl disable "system/$label" >/dev/null 2>&1 || true
      sudo rm -f "$plist"
      removed_any=1
    fi
  done < <(service_definition_ids)

  for plist in /Library/LaunchDaemons/"$(launchd_label_prefix)".*.plist; do
    [[ -e "$plist" ]] || continue
    current_id="${plist##*.clawlab.}"
    current_id="${current_id%.plist}"
    case " $requested_agents " in
      *" $current_id "*) ;;
      *)
        label="$(launchd_label_prefix).${current_id}"
        progress "removing leftover $label"
        sudo launchctl bootout system "$plist" >/dev/null 2>&1 || true
        sudo launchctl disable "system/$label" >/dev/null 2>&1 || true
        sudo rm -f "$plist"
        removed_any=1
        ;;
    esac
  done

  if ((removed_any == 0)); then
    progress "no leftover launchd plists found"
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

if ! command -v brew >/dev/null 2>&1; then
  echo "brew not found in PATH"
  exit 1
fi

progress "rendering Brewfile"
bash "$(repo_root)/infra/commands/render.sh" brew
progress "installing Homebrew dependencies"
brew bundle --file "$INFRA_DIR/generated/Brewfile"
run_agent_kind_installers
run_service_installers

ensure_clawlab_state_root
cleanup_service_manager_artifacts

progress "installing service-manager artifacts"
bash "$(repo_root)/infra/commands/install.sh" "$@"

echo "bootstrap complete"
