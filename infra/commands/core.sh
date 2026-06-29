#!/usr/bin/env bash

set -euo pipefail

aelab_script_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

infra_root() {
  cd "$(aelab_script_dir)/.." && pwd
}

repo_root() {
  cd "$(infra_root)/.." && pwd
}

aelab_root() {
  repo_root
}

aelab_name() {
  printf '%s' "aelab"
}

aelab_launchd_domain() {
  printf '%s' "net.tadija.$(aelab_name)"
}

aelab_caddy_import_dir() {
  printf '/etc/%s' "$(aelab_name)"
}

is_macos() {
  [[ "$(uname -s)" == "Darwin" ]]
}

is_linux() {
  [[ "$(uname -s)" == "Linux" ]]
}

is_arm64() {
  [[ "$(uname -m)" == "arm64" ]]
}

service_manager() {
  if is_linux; then
    printf '%s' "systemd"
  elif is_macos; then
    printf '%s' "launchd"
  else
    printf '%s' "unknown"
  fi
}

launchd_label_prefix() {
  aelab_launchd_domain
}

render_template() {
  local template="$1"
  local dest="$2"
  shift 2

  cp "$template" "$dest"

  while (($#)); do
    local placeholder="$1"
    local replacement="$2"
    shift 2
    PLACEHOLDER="$placeholder" REPLACEMENT="$replacement" perl -0pi -e 's/\Q$ENV{PLACEHOLDER}\E/$ENV{REPLACEMENT}/g' "$dest"
  done
}

discover_tool_path() {
  local tool="$1"
  command -v "$tool" 2>/dev/null || true
}

trim_commas() {
  local value="$1"
  value="${value//,/ }"
  printf '%s' "$value"
}

trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

strip_env_quotes() {
  local value="$1"
  if [[ ${#value} -ge 2 ]]; then
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
      value="${value:1:${#value}-2}"
    fi
  fi
  printf '%s' "$value"
}

is_agent_id() {
  [[ "$1" =~ ^[0-9][0-9][0-9]$ ]]
}

requested_items_from_env() {
  local -a items=()

  if [[ -n "${AELAB_SERVICES:-}" ]]; then
    local services
    services="$(trim_commas "$AELAB_SERVICES")"
    local name
    for name in $services; do
      [[ -n "$name" ]] || continue
      items+=("$name")
    done
  fi

  if [[ -n "${AELAB_AGENTS:-}" ]]; then
    local agents
    agents="$(trim_commas "$AELAB_AGENTS")"
    local id
    for id in $agents; do
      [[ -n "$id" ]] || continue
      items+=("$id")
    done
  fi

  if ((${#items[@]} == 0)); then
    return 0
  fi

  printf '%s\n' "${items[@]}"
}

requested_agent_ids_from_env() {
  local agents
  local agent_id

  agents="$(trim_commas "${AELAB_AGENTS:-}")"
  for agent_id in $agents; do
    [[ -n "$agent_id" ]] || continue
    if is_agent_id "$agent_id"; then
      printf '%s\n' "$agent_id"
    fi
  done
}

requested_service_ids_from_env() {
  local services
  local service_id
  local member

  services="$(trim_commas "${AELAB_SERVICES:-}")"
  for service_id in $services; do
    [[ -n "$service_id" ]] || continue
    if service_definition_exists "$service_id" && service_is_group "$service_id"; then
      while IFS= read -r member; do
        [[ -n "$member" ]] || continue
        printf '%s\n' "$member"
      done < <(service_group_member_ids "$service_id")
    else
      printf '%s\n' "$service_id"
    fi
  done | awk '!seen[$0]++'
}

requested_service_ids_with_groups_from_env() {
  local services
  local service_id
  local member

  services="$(trim_commas "${AELAB_SERVICES:-}")"
  for service_id in $services; do
    [[ -n "$service_id" ]] || continue
    if service_definition_exists "$service_id" && service_is_group "$service_id"; then
      printf '%s\n' "$service_id"
      while IFS= read -r member; do
        [[ -n "$member" ]] || continue
        printf '%s\n' "$member"
      done < <(service_group_member_ids "$service_id")
    else
      printf '%s\n' "$service_id"
    fi
  done | awk '!seen[$0]++'
}

service_requested_from_env() {
  local service_id="$1"
  local member
  local services
  local name

  services="$(trim_commas "${AELAB_SERVICES:-}")"
  for name in $services; do
    [[ "$name" == "$service_id" ]] && return 0
    if service_definition_exists "$name" && service_is_group "$name"; then
      while IFS= read -r member; do
        [[ "$member" == "$service_id" ]] && return 0
      done < <(service_group_member_ids "$name")
    fi
  done

  return 1
}

normalize_requested_item() {
  local item="$1"
  printf '%s' "$(trim_commas "$item")"
}

expand_requested_item() {
  local item="$1"

  case "$item" in
    repo)
      printf '%s\n' "$item"
      ;;
    agents)
      requested_agent_ids_from_env
      ;;
    services)
      requested_service_ids_from_env
      ;;
    *)
      if service_definition_exists "$item" && service_is_group "$item"; then
        service_group_member_ids "$item"
      else
        printf '%s\n' "$item"
      fi
      ;;
  esac
}

resolve_requested_items() {
  local -a requested=()
  local item
  local expanded

  if (($# == 0)); then
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      requested+=("$item")
    done < <(requested_items_from_env)
  else
    requested=("$@")
  fi

  for item in "${requested[@]+"${requested[@]}"}"; do
    item="$(normalize_requested_item "$item")"
    [[ -n "$item" ]] || continue
    while IFS= read -r expanded; do
      [[ -n "$expanded" ]] || continue
      printf '%s\n' "$expanded"
    done < <(expand_requested_item "$item")
  done
}

host_config_file() {
  printf '%s/config/host.toml' "$(repo_root)"
}

repo_cfg_file() {
  printf '%s/config/repo.toml' "$(repo_root)"
}

infra_hook_file() {
  local hook="$1"
  printf '%s/config/infra/hooks/%s.sh' "$(repo_root)" "$hook"
}

run_infra_hook() {
  local hook="$1"
  shift || true
  local file
  local env_file

  file="$(infra_hook_file "$hook")"
  [[ -f "$file" ]] || return 0
  if [[ ! -x "$file" ]]; then
    log "hook $hook exists but is not executable: $file"
    return 0
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '[%s] dry-run: hook %s' "${AELAB_LOG_PREFIX:-aelab}" "$hook"
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  log "running hook $hook"
  env_file="$(mktemp "${TMPDIR:-/tmp}/aelab-hook-env.XXXXXX")"
  if ! AELAB_HOOK_NAME="$hook" AELAB_HOOK_ENV_FILE="$env_file" bash "$file" "$@"; then
    rm -f "$env_file"
    return 1
  fi
  if [[ -s "$env_file" ]]; then
    # shellcheck disable=SC1090
    source "$env_file"
  fi
  rm -f "$env_file"
}

shell_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\\$}"
  value="${value//\`/\\\`}"
  printf '"%s"' "$value"
}

toml_section_entries() {
  local file="$1"
  local wanted_section="$2"
  [[ -f "$file" ]] || return 0

  awk -v wanted_section="$wanted_section" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function strip_quotes(value) {
      value = trim(value)
      if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) {
        value = substr(value, 2, length(value) - 2)
        gsub(/\\"/, "\"", value)
        gsub(/\\\\/, "\\", value)
      }
      return value
    }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[[:space:]]*\[[^][]+\][[:space:]]*$/ {
      current_section = $0
      sub(/^[[:space:]]*\[/, "", current_section)
      sub(/\][[:space:]]*$/, "", current_section)
      current_section = trim(current_section)
      next
    }
    current_section != wanted_section { next }
    {
      split($0, parts, "=")
      key = trim(parts[1])
      value = strip_quotes(substr($0, index($0, "=") + 1))
      if (key != "" && value != "") {
        print key "\t" value
      }
    }
  ' "$file"
}

repo_cfg_value() {
  local section="$1"
  local key="$2"

  toml_section_entries "$(repo_cfg_file)" "$section" |
    awk -F'\t' -v wanted_key="$key" '$1 == wanted_key { print $2; exit }'
}

repo_cfg_entries() {
  local section="$1"

  toml_section_entries "$(repo_cfg_file)" "$section"
}

load_host_env() {
  local file
  file="$(host_config_file)"
  [[ -f "$file" ]] || return 0

  eval "$(toml_section_env "$file" "")"
  if [[ -n "${AELAB_PATH:-}" ]]; then
    PATH="$(expand_runtime_placeholders "$AELAB_PATH")"
    export PATH
  fi
}

aelab_group() {
  if [[ -n "${AELAB_GROUP:-}" ]]; then
    printf '%s' "$AELAB_GROUP"
  elif [[ -n "${AELAB_USER:-}" ]]; then
    id -gn "$AELAB_USER" 2>/dev/null || id -gn
  else
    id -gn
  fi
}

verbose_enabled() {
  case "${AELAB_LOG_VERBOSE:-}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

log() {
  local verbose=0
  case "${1:-}" in
    --verbose)
      verbose=1
      shift
      ;;
    --*)
      printf 'unknown log option: %s\n' "$1" >&2
      return 2
      ;;
  esac

  if ((verbose == 1)) && ! verbose_enabled; then
    return 0
  fi

  if [[ -n "${AELAB_LOG_PREFIX:-}" ]]; then
    printf '[%s] %s\n' "$AELAB_LOG_PREFIX" "$1"
  else
    printf '%s\n' "$1" >&2
  fi
}

print_no_requested_items_hint() {
  echo "No agents or services requested."
  echo "Check config/host.toml for AELAB_AGENTS and AELAB_SERVICES."
}

service_manifest_dir() {
  printf '%s/config/services.toml' "$(repo_root)"
}

service_definition_ids() {
  toml_section_names "$(service_manifest_dir)"
}

agent_kind_manifest_dir() {
  printf '%s/config/agents.toml' "$(repo_root)"
}

service_templates_dir() {
  printf '%s/infra/templates' "$(repo_root)"
}

sudoers_template_path() {
  if visudo -V 2>/dev/null | head -n 1 | grep -qi 'visudo-rs'; then
    printf '%s/sudo-rs.aelab' "$(service_templates_dir)"
  else
    printf '%s/sudoers.aelab' "$(service_templates_dir)"
  fi
}

aelab_sudo_group() {
  if is_macos; then
    printf 'admin'
  elif getent group wheel >/dev/null 2>&1; then
    printf 'wheel'
  else
    printf 'sudo'
  fi
}

render_sudoers_aelab() {
  local dest="$1"
  render_template "$(sudoers_template_path)" "$dest" \
    __AELAB_ROOT__ "${AELAB_ROOT:-$(aelab_root)}" \
    __AELAB_SUDO_GROUP__ "$(aelab_sudo_group)"
}

install_sudoers_aelab() {
  local dest="/etc/sudoers.d/aelab"
  if [[ -f "$dest" ]]; then
    log --verbose "sudoers file already present at $dest (remove it to refresh)"
    return 0
  fi

  local generated_dir
  generated_dir="$(repo_root)/infra/generated"
  mkdir -p "$generated_dir"
  local rendered="$generated_dir/sudoers.aelab"
  render_sudoers_aelab "$rendered"

  local group_owner
  group_owner="$(is_linux && printf 'root' || printf 'wheel')"

  log "installing $dest (one-time sudo prompt)"
  sudo install -o root -g "$group_owner" -m 0440 "$rendered" "$dest"

  if ! sudo visudo -c -f "$dest" >/dev/null; then
    echo "ERROR: $dest failed validation; removing"
    sudo rm -f "$dest"
    return 1
  fi
  log "sudoers installed; subsequent start/stop runs won't prompt"
}

uninstall_sudoers_aelab() {
  local dest="/etc/sudoers.d/aelab"
  [[ -f "$dest" ]] || return 1
  log "removing $dest"
  sudo rm -f "$dest"
  return 0
}

service_manifest_path() {
  service_manifest_dir
}

service_definition_exists() {
  toml_section_exists "$(service_manifest_dir)" "$1"
}

agent_kind_manifest_path() {
  agent_kind_manifest_dir
}

toml_section_names() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk '
    /^[[:space:]]*\[[^][]+\][[:space:]]*$/ {
      section = $0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*$/, "", section)
      print section
    }
  ' "$file" | sort -u
}

toml_section_exists() {
  local file="$1"
  local section="$2"
  toml_section_names "$file" | grep -qxF "$section"
}

toml_section_env() {
  local file="$1"
  local wanted_section="$2"
  local key
  local value

  while IFS=$'\t' read -r key value; do
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    printf '%s=%s\n' "$key" "$(shell_quote "$value")"
  done < <(toml_section_entries "$file" "$wanted_section")
}

reset_service_definition() {
  unset AELAB_SERVICE_ID || true
  unset AELAB_SERVICE_DESCRIPTION || true
  unset AELAB_SERVICE_BIN || true
  unset AELAB_SERVICE_BREW_TAPS || true
  unset AELAB_SERVICE_BREW_PACKAGES || true
  unset AELAB_SERVICE_BREW_CASKS || true
  unset AELAB_SERVICE_BREW_PACKAGES_MACOS_ARM64 || true
  unset AELAB_SERVICE_BREW_CASKS_MACOS_ARM64 || true
  unset AELAB_SERVICE_INSTALL_OPTIONAL || true
  unset AELAB_SERVICE_SYSTEMD_NAME || true
  unset AELAB_SERVICE_LAUNCHD_LABEL || true
  unset AELAB_SERVICE_ARGS || true
  unset AELAB_SERVICE_RELOAD_ARGS || true
  unset AELAB_SERVICE_STOP_COMMAND || true
  unset AELAB_SERVICE_STDOUT || true
  unset AELAB_SERVICE_STDERR || true
  unset AELAB_SERVICE_ENV || true
  unset AELAB_SERVICE_AFTER || true
  unset AELAB_SERVICE_WANTS || true
  unset AELAB_SERVICE_RESTART || true
  unset AELAB_SERVICE_RESTART_SEC || true
  unset AELAB_SERVICE_DIR || true
  unset AELAB_SERVICE_STATE_DIRS || true
  unset AELAB_SERVICE_USER || true
  unset AELAB_SERVICE_GROUP || true
  unset AELAB_SERVICE_WORKING_DIRECTORY || true
  unset AELAB_SERVICE_SYSTEMD_ENVIRONMENT_FILE || true
  unset AELAB_SERVICE_SYSTEMD_AMBIENT_CAPABILITIES || true
  unset AELAB_SERVICE_SYSTEMD_CAPABILITY_BOUNDING_SET || true
  unset AELAB_SERVICE_SYSTEMD_NO_NEW_PRIVILEGES || true
  unset AELAB_SERVICE_SYSTEMD_LIMIT_NOFILE || true
  unset AELAB_SERVICE_INSTALL_KIND || true
  unset AELAB_SERVICE_INSTALL_SCRIPT || true
  unset AELAB_SERVICE_GROUP_MEMBERS || true
  unset AELAB_SERVICE_CADDY_ROUTE || true
  unset AELAB_SERVICE_CADDY_UPSTREAM || true
  unset AELAB_SERVICE_PORT || true
}

reset_agent_kind_definition() {
  unset AELAB_AGENT_KIND || true
  unset AELAB_AGENT_HOME_ENV || true
  unset AELAB_AGENT_SETUP_ARGS || true
  unset AELAB_AGENT_TUI_ARGS || true
  unset AELAB_AGENT_TUI_YOLO_ARGS || true
  unset AELAB_AGENT_START_ARGS || true
  unset AELAB_AGENT_START_PORT_FLAG || true
  unset AELAB_AGENT_FORWARD_PREFIX || true
  unset AELAB_AGENT_BREW_TAPS || true
  unset AELAB_AGENT_BREW_PACKAGES || true
  unset AELAB_AGENT_BREW_CASKS || true
  unset AELAB_AGENT_BREW_PACKAGES_MACOS_ARM64 || true
  unset AELAB_AGENT_BREW_CASKS_MACOS_ARM64 || true
  unset AELAB_AGENT_INSTALL_KIND || true
  unset AELAB_AGENT_INSTALL_SCRIPT || true
}

require_service_field() {
  local field="$1"
  local service_id="$2"
  if [[ -z "${!field:-}" ]]; then
    echo "service manifest ${service_id} is missing ${field}"
    exit 1
  fi
}

load_service_definition() {
  local service_id="$1"

  if ! service_definition_exists "$service_id"; then
    echo "unknown service: $service_id"
    exit 1
  fi

  reset_service_definition
  eval "$(toml_section_env "$(service_manifest_dir)" "$service_id")"
  eval "$(toml_section_env "$(host_config_file)" "services.${service_id}")"

  require_service_field AELAB_SERVICE_ID "$service_id"
  require_service_field AELAB_SERVICE_DESCRIPTION "$service_id"
  if [[ -z "${AELAB_SERVICE_GROUP_MEMBERS:-}" ]]; then
    require_service_field AELAB_SERVICE_BIN "$service_id"
  fi
  if [[ "$AELAB_SERVICE_ID" != "$service_id" ]]; then
    echo "service manifest ${service_id} does not match AELAB_SERVICE_ID=${AELAB_SERVICE_ID}"
    exit 1
  fi

  AELAB_SERVICE_PORT="$(repo_cfg_value "service-ports" "$service_id")"
  AELAB_SERVICE_SYSTEMD_NAME="${AELAB_SERVICE_SYSTEMD_NAME:-$service_id}"
  AELAB_SERVICE_LAUNCHD_LABEL="${AELAB_SERVICE_LAUNCHD_LABEL:-$(launchd_label_prefix).$service_id}"
  AELAB_SERVICE_RESTART="${AELAB_SERVICE_RESTART:-on-failure}"
  AELAB_SERVICE_RESTART_SEC="${AELAB_SERVICE_RESTART_SEC:-3s}"
  AELAB_SERVICE_DIR="${AELAB_SERVICE_DIR:-__AELAB_ROOT__/state/runtimes/__SERVICE_ID__}"
  AELAB_SERVICE_STDOUT="${AELAB_SERVICE_STDOUT:-__AELAB_ROOT__/state/logs/__SERVICE_ID__.log}"
  AELAB_SERVICE_STDERR="${AELAB_SERVICE_STDERR:-__AELAB_ROOT__/state/logs/__SERVICE_ID__.err}"
  AELAB_SERVICE_STATE_DIRS="${AELAB_SERVICE_STATE_DIRS:-__AELAB_SERVICE_DIR__}"
  AELAB_SERVICE_WORKING_DIRECTORY="${AELAB_SERVICE_WORKING_DIRECTORY:-__AELAB_SERVICE_DIR__}"
}

service_manifest_field_value() {
  local service_id="$1"
  local field="$2"

  (
    service_definition_exists "$service_id" || exit 0
    reset_service_definition
    eval "$(toml_section_env "$(service_manifest_dir)" "$service_id")"
    eval "$(toml_section_env "$(host_config_file)" "services.${service_id}")"
    printf '%s' "${!field:-}"
  )
}

service_group_member_ids() {
  local service_id="$1"
  local raw
  local id

  raw="$(service_manifest_field_value "$service_id" "AELAB_SERVICE_GROUP_MEMBERS")"
  raw="$(trim_commas "$raw")"
  for id in $raw; do
    [[ -n "$id" ]] || continue
    printf '%s\n' "$id"
  done
}

service_is_group() {
  [[ -n "$(service_manifest_field_value "$1" "AELAB_SERVICE_GROUP_MEMBERS")" ]]
}

run_service_installer() {
  local service_id="$1"
  local script_path
  local install_optional
  local stdout_path
  local stderr_path
  local install_stamp

  load_service_definition "$service_id"
  install_optional="${AELAB_SERVICE_INSTALL_OPTIONAL:-}"

  case "${AELAB_SERVICE_INSTALL_KIND:-}" in
    "")
      ;;
    script)
      script_path="$(repo_root)/${AELAB_SERVICE_INSTALL_SCRIPT:-}"
      if [[ -z "${AELAB_SERVICE_INSTALL_SCRIPT:-}" || ! -f "$script_path" ]]; then
        echo "service ${service_id} is missing a valid AELAB_SERVICE_INSTALL_SCRIPT"
        exit 1
      fi
      ensure_service_directories
      stdout_path="$(service_stdout_log_path)"
      stderr_path="$(service_stderr_log_path)"
      ensure_group_writable_file "$stdout_path"
      ensure_group_writable_file "$stderr_path"
      install_stamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
      printf '[%s] installer start %s: %s\n' "$install_stamp" "$service_id" "$script_path" >>"$stdout_path"

      if ! bash "$script_path" \
        > >(tee -a "$stdout_path") \
        2> >(tee -a "$stderr_path" >&2); then
        case "$install_optional" in
          1|true|yes|on)
            echo "warning: optional installer failed for ${service_id}; continuing"
            ;;
          *)
            install_stamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
            printf '[%s] installer failed %s: %s\n' "$install_stamp" "$service_id" "$script_path" >>"$stderr_path"
            echo "installer failed for ${service_id}; inspect ./ae infra log ${service_id}" >&2
            exit 1
            ;;
        esac
      fi
      install_stamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
      printf '[%s] installer finished %s: %s\n' "$install_stamp" "$service_id" "$script_path" >>"$stdout_path"
      ;;
    *)
      echo "unsupported AELAB_SERVICE_INSTALL_KIND for ${service_id}: ${AELAB_SERVICE_INSTALL_KIND}"
      exit 1
      ;;
  esac
}

load_agent_kind_definition() {
  local kind="$1"

  if ! toml_section_exists "$(agent_kind_manifest_dir)" "$kind"; then
    echo "unknown agent kind: $kind"
    exit 1
  fi

  reset_agent_kind_definition
  eval "$(toml_section_env "$(agent_kind_manifest_dir)" "$kind")"
  eval "$(toml_section_env "$(host_config_file)" "agents.${kind}")"

  if [[ -z "${AELAB_AGENT_KIND:-}" ]]; then
    echo "agent kind manifest ${kind} is missing AELAB_AGENT_KIND"
    exit 1
  fi

  if [[ "$AELAB_AGENT_KIND" != "$kind" ]]; then
    echo "agent kind manifest ${kind} does not match AELAB_AGENT_KIND=${AELAB_AGENT_KIND}"
    exit 1
  fi
}

load_agent_definition() {
  local agent_id="$1"
  local kind

  kind="$(agent_kind_for_id "$agent_id")"
  load_agent_kind_definition "$kind"
}

agent_is_managed() {
  local agent_id="$1"

  load_agent_definition "$agent_id"
  [[ -n "${AELAB_AGENT_START_ARGS:-}" ]]
}

agent_directory_name() {
  local agent_id="$1"
  local match

  match="$(find "$(repo_root)/agents" -maxdepth 1 -mindepth 1 -type d -name "${agent_id}-*" | sort | head -n 1)"
  if [[ -n "$match" ]]; then
    basename "$match"
  else
    printf '%s' "$agent_id"
  fi
}

agent_kind_for_id() {
  local agent_id="$1"
  local name

  name="$(agent_directory_name "$agent_id")"
  if [[ "$name" =~ ^[0-9][0-9][0-9]-([^-]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi

  echo "unable to determine kind for agent: $agent_id" >&2
  return 1
}

known_agent_kind_for_id() {
  local agent_id="$1"
  local kind
  local cache_var

  if ! kind="$(agent_kind_for_id "$agent_id" 2>/dev/null)"; then
    cache_var="AELAB_WARNED_UNKNOWN_AGENT_${agent_id}"
    if [[ -z "${!cache_var:-}" ]]; then
      echo "warning: skipping agent ${agent_id}; unable to determine kind" >&2
      printf -v "$cache_var" 1
      export "$cache_var"
    fi
    return 1
  fi

  if [[ ! -f "$(agent_kind_manifest_path "$kind")" && ! -f "$(custom_agent_kind_manifest_path "$kind")" ]]; then
    cache_var="AELAB_WARNED_UNKNOWN_AGENT_KIND_${agent_id}"
    if [[ -z "${!cache_var:-}" ]]; then
      echo "warning: skipping agent ${agent_id}; unknown kind manifest: ${kind}" >&2
      printf -v "$cache_var" 1
      export "$cache_var"
    fi
    return 1
  fi

  printf '%s' "$kind"
}

requested_agent_kinds_from_env() {
  local agent_id
  local kind

  while IFS= read -r agent_id; do
    [[ -n "$agent_id" ]] || continue
    kind="$(known_agent_kind_for_id "$agent_id")" || continue
    [[ -n "$kind" ]] || continue
    printf '%s\n' "$kind"
  done < <(requested_agent_ids_from_env) | sort -u
}

expand_runtime_placeholders() {
  local value="$1"
  local service_dir
  value="${value//__AELAB_ROOT__/${AELAB_ROOT:-$(aelab_root)}}"
  value="${value//__AELAB_USER__/${AELAB_USER:-}}"
  value="${value//__AELAB_GROUP__/$(aelab_group)}"
  value="${value//__AELAB_HOST__/${AELAB_HOST:-}}"
  value="${value//__SERVICE_ID__/${AELAB_SERVICE_ID:-}}"
  value="${value//__SERVICE_PORT__/${AELAB_SERVICE_PORT:-}}"
  service_dir="${AELAB_SERVICE_DIR:-__AELAB_ROOT__/state/runtimes/__SERVICE_ID__}"
  service_dir="${service_dir//__AELAB_ROOT__/${AELAB_ROOT:-$(aelab_root)}}"
  service_dir="${service_dir//__SERVICE_ID__/${AELAB_SERVICE_ID:-}}"
  value="${value//__AELAB_SERVICE_DIR__/$service_dir}"
  printf '%s' "$value"
}

expand_agent_env_placeholders() {
  local agent_id="$1"
  local value="$2"
  local agent_dir

  value="$(expand_runtime_placeholders "$value")"
  agent_dir="${AELAB_ROOT:-$(aelab_root)}/agents/$(agent_directory_name "$agent_id")"
  value="${value//__AGENT_DIR__/$agent_dir}"
  printf '%s' "$value"
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "$value"
}

split_shell_words() {
  local input="$1"
  local -a words=()
  if [[ -n "$input" ]]; then
    # shellcheck disable=SC2206
    eval "words=($input)"
  fi
  printf '%s\n' "${words[@]}"
}

resolve_service_binary() {
  local bin
  bin="$(expand_runtime_placeholders "$AELAB_SERVICE_BIN")"
  if [[ "$bin" == */* ]]; then
    if [[ -x "$bin" ]]; then
      printf '%s' "$bin"
    fi
    return 0
  fi

  discover_tool_path "$bin"
}

service_description() {
  printf '%s' "$(expand_runtime_placeholders "$AELAB_SERVICE_DESCRIPTION")"
}

service_systemd_name() {
  printf '%s' "$AELAB_SERVICE_SYSTEMD_NAME"
}

service_launchd_label() {
  printf '%s' "$AELAB_SERVICE_LAUNCHD_LABEL"
}

service_launchd_plist_path() {
  printf '/Library/LaunchDaemons/%s.plist' "$(service_launchd_label)"
}

service_systemd_unit_path() {
  printf '/etc/systemd/system/%s.service' "$(service_systemd_name)"
}

agent_systemd_unit_path() {
  printf '/etc/systemd/system/agent@.service'
}

agent_launchd_plist_path() {
  local agent_id="$1"
  printf '/Library/LaunchDaemons/%s.plist' "$(service_label_for_agent "$agent_id")"
}

install_systemd_agent_unit_template() {
  local aelab_root="$1"
  local aelab_user="$2"
  local rendered
  local dest

  rendered="$(mktemp)"
  dest="$(agent_systemd_unit_path)"
  render_template "$(service_templates_dir)/agent.systemd" "$rendered" \
    __AELAB_ROOT__ "$aelab_root" \
    __AELAB_USER__ "$aelab_user" \
    __AELAB_GROUP__ "$(aelab_group)" \
    __PATH_BLOCK__ "$(systemd_path_block)"
  sudo install -m 0644 "$rendered" "$dest"
  rm -f "$rendered"

  printf '%s' "$dest"
}

agent_shared_env_file_path() {
  printf '%s/config/env/agents.env' "${AELAB_ROOT:-$(aelab_root)}"
}

agent_env_file_path() {
  local agent_id="$1"
  printf '%s/config/env/%s.env' "${AELAB_ROOT:-$(aelab_root)}" "$agent_id"
}

service_shared_env_file_path() {
  printf '%s/config/env/services.env' "${AELAB_ROOT:-$(aelab_root)}"
}

service_env_file_path() {
  local service_id="$1"
  printf '%s/config/env/%s.env' "${AELAB_ROOT:-$(aelab_root)}" "$service_id"
}

agent_stdout_log_path() {
  local agent_id="$1"
  printf '%s/state/logs/agent/%s.log' "${AELAB_ROOT:-$(aelab_root)}" "$agent_id"
}

agent_stderr_log_path() {
  local agent_id="$1"
  printf '%s/state/logs/agent/%s.err' "${AELAB_ROOT:-$(aelab_root)}" "$agent_id"
}

service_stdout_log_path() {
  printf '%s' "$(expand_runtime_placeholders "$AELAB_SERVICE_STDOUT")"
}

service_stderr_log_path() {
  printf '%s' "$(expand_runtime_placeholders "$AELAB_SERVICE_STDERR")"
}

service_exec_start() {
  local bin_path
  local args

  bin_path="$(resolve_service_binary)"
  if [[ -z "$bin_path" ]]; then
    echo "service ${AELAB_SERVICE_ID} binary not found: $(expand_runtime_placeholders "$AELAB_SERVICE_BIN")" >&2
    return 1
  fi

  args="$(expand_runtime_placeholders "${AELAB_SERVICE_ARGS:-}")"
  if [[ -n "$args" ]]; then
    printf '%s %s' "$bin_path" "$args"
  else
    printf '%s' "$bin_path"
  fi
}

service_exec_reload() {
  local bin_path
  local args

  args="$(expand_runtime_placeholders "${AELAB_SERVICE_RELOAD_ARGS:-}")"
  if [[ -z "$args" ]]; then
    return 0
  fi

  bin_path="$(resolve_service_binary)"
  if [[ -z "$bin_path" ]]; then
    echo "service ${AELAB_SERVICE_ID} binary not found: $(expand_runtime_placeholders "$AELAB_SERVICE_BIN")" >&2
    return 1
  fi

  printf '%s %s' "$bin_path" "$args"
}

service_program_arguments_block() {
  local bin_path
  local args
  local word
  local -a words=()

  bin_path="$(resolve_service_binary)"
  if [[ -z "$bin_path" ]]; then
    echo "service ${AELAB_SERVICE_ID} binary not found: $(expand_runtime_placeholders "$AELAB_SERVICE_BIN")" >&2
    return 1
  fi

  words+=("$bin_path")
  args="$(expand_runtime_placeholders "${AELAB_SERVICE_ARGS:-}")"
  if [[ -n "$args" ]]; then
    while IFS= read -r word; do
      [[ -n "$word" ]] || continue
      words+=("$word")
    done < <(split_shell_words "$args")
  fi

  for word in "${words[@]}"; do
    printf '    <string>%s</string>\n' "$(xml_escape "$word")"
  done
}

systemd_assignment_block() {
  local key="$1"
  local value="$2"
  if [[ -n "$value" ]]; then
    printf '%s=%s\n' "$key" "$value"
  fi
}

systemd_path_block() {
  if [[ -n "${AELAB_PATH:-}" ]]; then
    systemd_assignment_block Environment "PATH=$(expand_runtime_placeholders "$AELAB_PATH")"
  fi
}

systemd_escape_environment_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

service_systemd_environment_block() {
  local raw
  local item
  local key
  local value

  systemd_path_block

  raw="${AELAB_SERVICE_ENV:-}"
  [[ -n "$raw" ]] || return 0

  raw="${raw//|/$'\n'}"
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    if [[ "$item" != *=* ]]; then
      echo "invalid AELAB_SERVICE_ENV assignment: $item" >&2
      return 1
    fi
    key="${item%%=*}"
    value="${item#*=}"
    [[ -n "$key" ]] || continue
    value="$(expand_runtime_placeholders "$value")"
    printf 'Environment="%s=%s"\n' "$key" "$(systemd_escape_environment_value "$value")"
  done <<< "$raw"
}

service_systemd_environment_file_block() {
  local shared_file
  local file
  local custom_file

  shared_file="$(service_shared_env_file_path)"
  file="$(service_env_file_path "$AELAB_SERVICE_ID")"
  custom_file="$(expand_runtime_placeholders "${AELAB_SERVICE_SYSTEMD_ENVIRONMENT_FILE:-}")"

  systemd_assignment_block EnvironmentFile "-$shared_file"
  systemd_assignment_block EnvironmentFile "-$file"
  systemd_assignment_block EnvironmentFile "$custom_file"
}

launchd_string_block() {
  local key="$1"
  local value="$2"
  if [[ -n "$value" ]]; then
    printf '  <key>%s</key>\n' "$key"
    printf '  <string>%s</string>\n' "$(xml_escape "$value")"
  fi
}

agent_launchd_environment_variables_block() {
  local agent_id="$1"
  local shared_file
  local file
  local line
  local key
  local value
  local has_env=0

  if [[ -n "${AELAB_PATH:-}" ]]; then
    has_env=1
  fi

  shared_file="$(agent_shared_env_file_path)"
  file="$(agent_env_file_path "$agent_id")"
  if env_file_has_assignments "$shared_file" || env_file_has_assignments "$file"; then
    has_env=1
  fi

  ((has_env == 1)) || return 0

  printf '  <key>EnvironmentVariables</key>\n'
  printf '  <dict>\n'

  if [[ -n "${AELAB_PATH:-}" ]]; then
    printf '    <key>PATH</key>\n'
    printf '    <string>%s</string>\n' "$(xml_escape "$(expand_runtime_placeholders "$AELAB_PATH")")"
  fi

  emit_launchd_env_file_entries "$agent_id" "$shared_file" "$file"
  emit_launchd_env_file_entries "$agent_id" "$file"

  printf '  </dict>\n'
}

env_file_has_assignments() {
  local file="$1"
  local line
  local key

  [[ -f "$file" ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim_whitespace "$line")"
    [[ -n "$line" && "$line" != \#* && "$line" == *=* ]] || continue
    key="$(trim_whitespace "${line%%=*}")"
    [[ -n "$key" ]] || continue
    return 0
  done < "$file"

  return 1
}

env_file_contains_key() {
  local file="$1"
  local wanted_key="$2"
  local line
  local key

  [[ -f "$file" ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim_whitespace "$line")"
    [[ -n "$line" && "$line" != \#* && "$line" == *=* ]] || continue
    key="$(trim_whitespace "${line%%=*}")"
    [[ "$key" == "$wanted_key" ]] && return 0
  done < "$file"

  return 1
}

env_files_contain_key() {
  local wanted_key="$1"
  shift

  local file
  for file in "$@"; do
    [[ -n "$file" ]] || continue
    if env_file_contains_key "$file" "$wanted_key"; then
      return 0
    fi
  done

  return 1
}

emit_launchd_env_file_entries() {
  local agent_id="$1"
  local file="$2"
  local override_file="${3:-}"
  local line
  local key
  local value

  [[ -f "$file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim_whitespace "$line")"
    [[ -n "$line" && "$line" != \#* && "$line" == *=* ]] || continue
    key="$(trim_whitespace "${line%%=*}")"
    value="$(trim_whitespace "${line#*=}")"
    [[ -n "$key" ]] || continue
    if [[ -n "$override_file" ]] && env_file_contains_key "$override_file" "$key"; then
      continue
    fi
    value="$(strip_env_quotes "$value")"
    value="$(expand_agent_env_placeholders "$agent_id" "$value")"
    printf '    <key>%s</key>\n' "$(xml_escape "$key")"
    printf '    <string>%s</string>\n' "$(xml_escape "$value")"
  done < "$file"
}

emit_service_launchd_env_file_entries() {
  local file="$1"
  local override_file="${2:-}"
  local line
  local key
  local value

  [[ -f "$file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim_whitespace "$line")"
    [[ -n "$line" && "$line" != \#* && "$line" == *=* ]] || continue
    key="$(trim_whitespace "${line%%=*}")"
    value="$(trim_whitespace "${line#*=}")"
    [[ -n "$key" ]] || continue
    if [[ -n "$override_file" ]] && env_file_contains_key "$override_file" "$key"; then
      continue
    fi
    value="$(strip_env_quotes "$value")"
    value="$(expand_runtime_placeholders "$value")"
    printf '    <key>%s</key>\n' "$(xml_escape "$key")"
    printf '    <string>%s</string>\n' "$(xml_escape "$value")"
  done < "$file"
}

service_launchd_environment_variables_block() {
  local shared_file
  local file
  local raw
  local item
  local key
  local value
  local has_env=0

  shared_file="$(service_shared_env_file_path)"
  file="$(service_env_file_path "$AELAB_SERVICE_ID")"

  if [[ -n "${AELAB_PATH:-}" || -n "${AELAB_SERVICE_ENV:-}" ]] || env_file_has_assignments "$shared_file" || env_file_has_assignments "$file"; then
    has_env=1
  fi

  ((has_env == 1)) || return 0

  printf '  <key>EnvironmentVariables</key>\n'
  printf '  <dict>\n'

  if [[ -n "${AELAB_PATH:-}" ]]; then
    printf '    <key>PATH</key>\n'
    printf '    <string>%s</string>\n' "$(xml_escape "$(expand_runtime_placeholders "$AELAB_PATH")")"
  fi

  raw="${AELAB_SERVICE_ENV:-}"
  raw="${raw//|/$'\n'}"
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    if [[ "$item" != *=* ]]; then
      echo "invalid AELAB_SERVICE_ENV assignment: $item" >&2
      return 1
    fi
    key="${item%%=*}"
    value="${item#*=}"
    [[ -n "$key" ]] || continue
    if env_files_contain_key "$key" "$shared_file" "$file"; then
      continue
    fi
    value="$(expand_runtime_placeholders "$value")"
    printf '    <key>%s</key>\n' "$(xml_escape "$key")"
    printf '    <string>%s</string>\n' "$(xml_escape "$value")"
  done <<< "$raw"

  emit_service_launchd_env_file_entries "$shared_file" "$file"
  emit_service_launchd_env_file_entries "$file"

  printf '  </dict>\n'
}

ensure_aelab_state_root() {
  local group
  group="$(aelab_group)"
  mkdir -p \
    "$AELAB_ROOT/state" \
    "$AELAB_ROOT/state/logs" \
    "$AELAB_ROOT/state/logs/agent" \
    "$AELAB_ROOT/state/runtimes"
  chgrp "$group" \
    "$AELAB_ROOT/state" \
    "$AELAB_ROOT/state/logs" \
    "$AELAB_ROOT/state/logs/agent" \
    "$AELAB_ROOT/state/runtimes" 2>/dev/null || true
  chmod g+rwxs \
    "$AELAB_ROOT/state" \
    "$AELAB_ROOT/state/logs" \
    "$AELAB_ROOT/state/logs/agent" \
    "$AELAB_ROOT/state/runtimes" 2>/dev/null || true
}

repair_aelab_agent_permissions() {
  local agent_id="$1"
  local owner="${2:-${AELAB_USER:-}}"
  local agent_dir

  ensure_aelab_state_root
  agent_dir="$AELAB_ROOT/agents/$(agent_directory_name "$agent_id")"
  [[ -d "$agent_dir" ]] || return 0
  repair_aelab_path_permissions "$agent_dir" "$owner"
}

repair_aelab_service_permissions() {
  local owner="${1:-${AELAB_SERVICE_USER:-${AELAB_USER:-}}}"
  local service_dir
  local state_dirs
  local path
  local log_path
  local repaired_paths=""
  local repaired_path
  local skip

  ensure_service_directories
  service_dir="$(expand_runtime_placeholders "__AELAB_SERVICE_DIR__")"
  repair_aelab_path_permissions "$service_dir" "$owner"
  repaired_paths+="${service_dir}"$'\n'

  state_dirs="$(expand_runtime_placeholders "${AELAB_SERVICE_STATE_DIRS:-}")"
  if [[ -n "$state_dirs" ]]; then
    # shellcheck disable=SC2206
    local -a dirs=($(trim_commas "$state_dirs"))
    for path in "${dirs[@]}"; do
      [[ -n "$path" ]] || continue
      skip=0
      while IFS= read -r repaired_path; do
        [[ -n "$repaired_path" ]] || continue
        case "$path/" in
          "$repaired_path"/*) skip=1 ;;
        esac
      done <<< "$repaired_paths"
      ((skip == 0)) || continue
      repair_aelab_path_permissions "$path" "$owner"
      repaired_paths+="${path}"$'\n'
    done
  fi

  for log_path in "$(service_stdout_log_path)" "$(service_stderr_log_path)"; do
    [[ -e "$log_path" ]] || continue
    repair_aelab_path_permissions "$log_path" "$owner"
  done
}

repair_aelab_repo_permissions() {
  local owner="${1:-${AELAB_USER:-}}"
  local group
  local path
  local -a paths=()

  owner="$(expand_runtime_placeholders "$owner")"
  [[ -n "$owner" ]] || return 0
  group="$(aelab_group)"

  for path in \
    "$AELAB_ROOT/README.md" \
    "$AELAB_ROOT/LICENSE" \
    "$AELAB_ROOT/ae" \
    "$AELAB_ROOT/config" \
    "$AELAB_ROOT/infra"
  do
    [[ -e "$path" ]] && paths+=("$path")
  done

  chgrp "$group" "$AELAB_ROOT" 2>/dev/null || repair_aelab_sudo chgrp "$group" "$AELAB_ROOT" 2>/dev/null || true
  chmod g+rwxs "$AELAB_ROOT" 2>/dev/null || repair_aelab_sudo chmod g+rwxs "$AELAB_ROOT" 2>/dev/null || true
  find "${paths[@]}" -path "$AELAB_ROOT/.git" -prune -o -exec chgrp "$group" {} + 2>/dev/null || true
  find "${paths[@]}" -path "$AELAB_ROOT/.git" -prune -o -type d -exec chmod g+rwxs {} + 2>/dev/null || true
  find "${paths[@]}" -path "$AELAB_ROOT/.git" -prune -o -type f -exec chmod g+rw {} + 2>/dev/null || true

  find "${paths[@]}" -path "$AELAB_ROOT/.git" -prune -o -exec sudo -n chown "$owner:$group" {} + 2>/dev/null || true
  find "${paths[@]}" -path "$AELAB_ROOT/.git" -prune -o -type d -exec sudo -n chmod g+rwxs {} + 2>/dev/null || true
  find "${paths[@]}" -path "$AELAB_ROOT/.git" -prune -o -type f -exec sudo -n chmod g+rw {} + 2>/dev/null || true
  AELAB_REPAIR_NO_PROMPT=1 repair_aelab_group_acl "$AELAB_ROOT" "$group"
}

repair_aelab_path_permissions() {
  local path="$1"
  local owner="${2:-${AELAB_USER:-}}"
  local group
  local mismatch

  owner="$(expand_runtime_placeholders "$owner")"
  [[ -n "$owner" && -e "$path" ]] || return 0
  group="$(aelab_group)"
  mismatch="$(find "$path" \( ! -user "$owner" -o ! -group "$group" -o \( -type d \( ! -perm -020 -o ! -perm -2000 \) \) -o \( -type f ! -perm -020 \) \) -print -quit 2>/dev/null || true)"
  [[ -n "$mismatch" ]] || return 0
  log --verbose "[repair] $path -> $owner:$group, group-writable directories/files"

  chgrp -R "$group" "$path" 2>/dev/null || true
  find "$path" -type d -exec chmod g+rwxs {} + 2>/dev/null || true
  find "$path" -type f -exec chmod g+rw {} + 2>/dev/null || true
  repair_aelab_group_acl "$path" "$group"

  mismatch="$(find "$path" \( ! -user "$owner" -o ! -group "$group" -o \( -type d \( ! -perm -020 -o ! -perm -2000 \) \) -o \( -type f ! -perm -020 \) \) -print -quit 2>/dev/null || true)"
  [[ -n "$mismatch" ]] || return 0

  if ! repair_aelab_sudo chown -R "$owner:$group" "$path"; then
    log --verbose "[repair] skipped $path; sudo permission unavailable"
    return 0
  fi
  repair_aelab_sudo chmod g+rwxs "$path" 2>/dev/null || true
  find "$path" -type d -exec sudo -n chmod g+rwxs {} + 2>/dev/null || true
  find "$path" -type f -exec sudo -n chmod g+rw {} + 2>/dev/null || true
  repair_aelab_group_acl "$path" "$group"
}

repair_aelab_path_permissions_shallow() {
  local path="$1"
  local owner="${2:-${AELAB_USER:-}}"
  local group
  local mismatch=0
  local current_owner
  local current_group

  owner="$(expand_runtime_placeholders "$owner")"
  [[ -n "$owner" && -e "$path" ]] || return 0
  group="$(aelab_group)"
  current_owner="$(path_owner "$path")"
  current_group="$(path_group "$path")"

  if [[ "$current_owner" != "$owner" || "$current_group" != "$group" ]] || path_has_shallow_permission_mismatch "$path"; then
    mismatch=1
  fi
  ((mismatch == 1)) || return 0

  log --verbose "[repair] $path -> $owner:$group, group-writable"
  chgrp "$group" "$path" 2>/dev/null || true
  if [[ -d "$path" ]]; then
    chmod g+rwxs "$path" 2>/dev/null || true
  else
    chmod g+rw "$path" 2>/dev/null || true
  fi
  repair_aelab_group_acl "$path" "$group"

  current_owner="$(path_owner "$path")"
  current_group="$(path_group "$path")"
  if [[ "$current_owner" != "$owner" || "$current_group" != "$group" ]] || path_has_shallow_permission_mismatch "$path"; then
    if ! repair_aelab_sudo chown "$owner:$group" "$path"; then
      log --verbose "[repair] skipped $path; sudo permission unavailable"
      return 0
    fi
    if [[ -d "$path" ]]; then
      repair_aelab_sudo chmod g+rwxs "$path" || true
    else
      repair_aelab_sudo chmod g+rw "$path" || true
    fi
    repair_aelab_group_acl "$path" "$group"
  fi
}

path_has_shallow_permission_mismatch() {
  local path="$1"
  local mode_text
  local mode

  mode_text="$(path_mode "$path")"
  [[ -n "$mode_text" ]] || return 1
  mode=$((8#$mode_text))

  if [[ -d "$path" ]]; then
    (( (mode & 0020) == 0 || (mode & 0010) == 0 || (mode & 02000) == 0 ))
  elif [[ -f "$path" ]]; then
    (( (mode & 0020) == 0 ))
  else
    return 1
  fi
}

path_mode() {
  if is_macos; then
    stat -f '%Lp' "$1" 2>/dev/null || true
  else
    stat -c '%a' "$1" 2>/dev/null || true
  fi
}

path_owner() {
  if is_macos; then
    stat -f '%Su' "$1" 2>/dev/null || true
  else
    stat -c '%U' "$1" 2>/dev/null || true
  fi
}

path_group() {
  if is_macos; then
    stat -f '%Sg' "$1" 2>/dev/null || true
  else
    stat -c '%G' "$1" 2>/dev/null || true
  fi
}

repair_aelab_sudo() {
  if [[ "${AELAB_REPAIR_NO_PROMPT:-}" == "1" ]]; then
    sudo -n "$@" 2>/dev/null
  else
    sudo "$@"
  fi
}

repair_aelab_group_acl() {
  local path="$1"
  local group="$2"
  local acl

  is_macos || return 0
  [[ -e "$path" ]] || return 0
  ls -lde "$path" 2>/dev/null | grep -F "group:${group} allow" >/dev/null && return 0

  if [[ -d "$path" ]]; then
    acl="group:${group} allow list,add_file,search,delete_child,readattr,writeattr,readextattr,writeextattr,readsecurity,file_inherit,directory_inherit"
  else
    acl="group:${group} allow read,write,append,readattr,writeattr,readextattr,writeextattr,readsecurity"
  fi

  chmod +a "$acl" "$path" 2>/dev/null || repair_aelab_sudo chmod +a "$acl" "$path" || true
}

ensure_group_directory() {
  local path="$1"
  local group="$2"

  [[ -n "$path" ]] || return 0
  mkdir -p "$path"
  chgrp "$group" "$path" 2>/dev/null || true
  chmod g+rwxs "$path" 2>/dev/null || true
}

ensure_group_writable_file() {
  local path="$1"
  local owner="${2:-${AELAB_SERVICE_USER:-${AELAB_USER:-}}}"
  local group

  [[ -n "$path" ]] || return 0
  owner="$(expand_runtime_placeholders "$owner")"
  group="$(aelab_group)"

  if [[ -e "$path" ]]; then
    chgrp "$group" "$path" 2>/dev/null || true
    chmod g+rw "$path" 2>/dev/null || true
    if [[ -w "$path" ]]; then
      return 0
    fi
    repair_aelab_sudo chgrp "$group" "$path" 2>/dev/null || true
    repair_aelab_sudo chmod g+rw "$path" 2>/dev/null || true
    [[ -w "$path" ]] && return 0
  else
    if : >> "$path" 2>/dev/null; then
      chgrp "$group" "$path" 2>/dev/null || true
      chmod g+rw "$path" 2>/dev/null || true
      return 0
    fi
    repair_aelab_sudo install -o "$owner" -g "$group" -m 0664 /dev/null "$path" >/dev/null 2>&1 || true
    [[ -w "$path" ]] && return 0
  fi

  echo "unable to prepare writable log file: $path" >&2
  return 1
}

ensure_service_directories() {
  local stdout_path
  local stderr_path
  local state_dirs
  local path
  local group

  ensure_aelab_state_root
  group="$(aelab_group)"

  stdout_path="$(service_stdout_log_path)"
  stderr_path="$(service_stderr_log_path)"
  ensure_group_directory "$(dirname "$stdout_path")" "$group"
  ensure_group_directory "$(dirname "$stderr_path")" "$group"
  ensure_group_directory "$(expand_runtime_placeholders "__AELAB_SERVICE_DIR__")" "$group"

  state_dirs="$(expand_runtime_placeholders "${AELAB_SERVICE_STATE_DIRS:-}")"
  if [[ -n "$state_dirs" ]]; then
    # shellcheck disable=SC2206
    local -a dirs=($(trim_commas "$state_dirs"))
    for path in "${dirs[@]}"; do
      ensure_group_directory "$path" "$group"
    done
  fi
}

render_service_systemd_unit() {
  local dest="$1"
  local template
  local exec_start
  local exec_reload

  template="$(service_templates_dir)/service.systemd"
  exec_start="$(service_exec_start)" || return 1
  exec_reload="$(service_exec_reload)" || return 1

  render_template "$template" "$dest" \
    __DESCRIPTION__ "$(service_description)" \
    __AFTER_BLOCK__ "$(systemd_assignment_block After "$(expand_runtime_placeholders "${AELAB_SERVICE_AFTER:-}")")" \
    __WANTS_BLOCK__ "$(systemd_assignment_block Wants "$(expand_runtime_placeholders "${AELAB_SERVICE_WANTS:-}")")" \
    __USER_BLOCK__ "$(systemd_assignment_block User "$(expand_runtime_placeholders "${AELAB_SERVICE_USER:-}")")" \
    __GROUP_BLOCK__ "$(systemd_assignment_block Group "$(expand_runtime_placeholders "${AELAB_SERVICE_GROUP:-__AELAB_GROUP__}")")" \
    __WORKING_DIRECTORY_BLOCK__ "$(systemd_assignment_block WorkingDirectory "$(expand_runtime_placeholders "${AELAB_SERVICE_WORKING_DIRECTORY:-}")")" \
    __PATH_BLOCK__ "$(service_systemd_environment_block)" \
    __ENVIRONMENT_FILE_BLOCK__ "$(service_systemd_environment_file_block)" \
    __EXEC_START__ "$exec_start" \
    __EXEC_RELOAD_BLOCK__ "$(systemd_assignment_block ExecReload "$exec_reload")" \
    __EXEC_STOP_BLOCK__ "$(systemd_assignment_block ExecStop "$(expand_runtime_placeholders "${AELAB_SERVICE_STOP_COMMAND:-}")")" \
    __RESTART__ "$AELAB_SERVICE_RESTART" \
    __RESTART_SEC__ "$AELAB_SERVICE_RESTART_SEC" \
    __STDOUT__ "$(service_stdout_log_path)" \
    __STDERR__ "$(service_stderr_log_path)" \
    __AMBIENT_CAPABILITIES_BLOCK__ "$(systemd_assignment_block AmbientCapabilities "$(expand_runtime_placeholders "${AELAB_SERVICE_SYSTEMD_AMBIENT_CAPABILITIES:-}")")" \
    __CAPABILITY_BOUNDING_SET_BLOCK__ "$(systemd_assignment_block CapabilityBoundingSet "$(expand_runtime_placeholders "${AELAB_SERVICE_SYSTEMD_CAPABILITY_BOUNDING_SET:-}")")" \
    __NO_NEW_PRIVILEGES_BLOCK__ "$(systemd_assignment_block NoNewPrivileges "$(expand_runtime_placeholders "${AELAB_SERVICE_SYSTEMD_NO_NEW_PRIVILEGES:-}")")" \
    __LIMIT_NOFILE_BLOCK__ "$(systemd_assignment_block LimitNOFILE "$(expand_runtime_placeholders "${AELAB_SERVICE_SYSTEMD_LIMIT_NOFILE:-}")")"
}

install_systemd_service_unit() {
  local service_id="$1"
  local rendered
  local dest

  load_service_definition "$service_id"
  ensure_service_directories

  mkdir -p "$(repo_root)/infra/generated"
  rendered="$(mktemp "$(repo_root)/infra/generated/${service_id}.unit.XXXXXX")"
  dest="$(service_systemd_unit_path)"
  render_service_systemd_unit "$rendered"
  sudo install -m 0644 "$rendered" "$dest"
  rm -f "$rendered"

  printf '%s' "$dest"
}

render_service_launchd_plist() {
  local dest="$1"
  local template
  local program_arguments

  template="$(service_templates_dir)/service.launchd.plist"
  program_arguments="$(service_program_arguments_block)" || return 1

  render_template "$template" "$dest" \
    __LABEL__ "$(service_launchd_label)" \
    __USERNAME_BLOCK__ "$(launchd_string_block UserName "$(expand_runtime_placeholders "${AELAB_SERVICE_USER:-}")")" \
    __GROUPNAME_BLOCK__ "$(launchd_string_block GroupName "$(expand_runtime_placeholders "${AELAB_SERVICE_GROUP:-__AELAB_GROUP__}")")" \
    __WORKING_DIRECTORY_BLOCK__ "$(launchd_string_block WorkingDirectory "$(expand_runtime_placeholders "${AELAB_SERVICE_WORKING_DIRECTORY:-}")")" \
    __ENVIRONMENT_VARIABLES_BLOCK__ "$(service_launchd_environment_variables_block)" \
    __PROGRAM_ARGUMENTS_BLOCK__ "$program_arguments" \
    __STDOUT__ "$(service_stdout_log_path)" \
    __STDERR__ "$(service_stderr_log_path)"
}

install_service_launchd_plist() {
  local service_id="$1"
  local rendered
  local dest

  load_service_definition "$service_id"
  ensure_service_directories

  mkdir -p "$(repo_root)/infra/generated"
  rendered="$(mktemp "$(repo_root)/infra/generated/${service_id}.plist.XXXXXX")"
  dest="$(service_launchd_plist_path)"
  sudo launchctl bootout system "$dest" >/dev/null 2>&1 || true
  render_service_launchd_plist "$rendered"
  sudo install -m 0644 "$rendered" "$dest"
  rm -f "$rendered"

  printf '%s' "$dest"
}

service_label_for_agent() {
  local agent_id="$1"
  printf '%s.%s' "$(launchd_label_prefix)" "$agent_id"
}

systemd_service_state() {
  local service="$1"
  local state
  state="$(systemctl is-active "$service" 2>/dev/null || true)"
  if [[ -n "$state" ]]; then
    printf '%s' "$state"
  else
    printf '%s' "unknown"
  fi
}

systemd_service_pid() {
  local service="$1"
  local pid
  pid="$(systemctl show "$service" --property MainPID --value 2>/dev/null || true)"
  if [[ -n "$pid" && "$pid" != "0" ]]; then
    printf '%s' "$pid"
  else
    printf '%s' "-"
  fi
}

launchd_service_state() {
  local label="$1"
  local state
  state="$(launchctl print "system/$label" 2>/dev/null | awk -F' = ' '/state = / {print $2; exit}')"
  if [[ -n "$state" ]]; then
    printf '%s' "$state"
  else
    printf '%s' "unloaded"
  fi
}

launchd_service_pid() {
  local label="$1"
  local pid
  pid="$(launchctl print "system/$label" 2>/dev/null | awk -F' = ' '/pid = / {print $2; exit}')"
  if [[ -n "$pid" && "$pid" != "0" ]]; then
    printf '%s' "$pid"
  else
    printf '%s' "-"
  fi
}

install_launchd_agent_plist() {
  local agent_id="$1"
  local aelab_root="$2"
  local aelab_user="$3"
  local label
  local template
  local rendered
  local dest

  label="$(service_label_for_agent "$agent_id")"
  template="$(service_templates_dir)/agent.launchd.plist"
  mkdir -p "$(repo_root)/infra/generated"
  rendered="$(mktemp "$(repo_root)/infra/generated/agent-${agent_id}.plist.XXXXXX")"
  dest="/Library/LaunchDaemons/${label}.plist"

  sudo launchctl bootout system "$dest" >/dev/null 2>&1 || true
  render_template "$template" "$rendered" \
    __LABEL__ "$label" \
    __AELAB_ROOT__ "$aelab_root" \
    __AELAB_USER__ "$aelab_user" \
    __AELAB_GROUP__ "$(aelab_group)" \
    __ENVIRONMENT_VARIABLES_BLOCK__ "$(agent_launchd_environment_variables_block "$agent_id")" \
    __AGENT_ID__ "$agent_id"
  sudo install -m 0644 "$rendered" "$dest"
  rm -f "$rendered"

  printf '%s' "$dest"
}
