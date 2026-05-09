#!/usr/bin/env bash

set -euo pipefail

clawlab_script_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

infra_root() {
  cd "$(clawlab_script_dir)/.." && pwd
}

repo_root() {
  cd "$(infra_root)/.." && pwd
}

clawlab_root() {
  repo_root
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
  printf '%s' "net.tadija.clawlab"
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

  if [[ -n "${CLAWLAB_SERVICES:-}" ]]; then
    local services
    services="$(trim_commas "$CLAWLAB_SERVICES")"
    # shellcheck disable=SC2206
    local -a names=($services)
    local name
    for name in "${names[@]}"; do
      [[ -n "$name" ]] || continue
      items+=("$name")
    done
  fi

  if [[ -n "${CLAWLAB_AGENTS:-}" ]]; then
    local agents
    agents="$(trim_commas "$CLAWLAB_AGENTS")"
    # shellcheck disable=SC2206
    local -a ids=($agents)
    local id
    for id in "${ids[@]}"; do
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

  agents="$(trim_commas "${CLAWLAB_AGENTS:-}")"
  # shellcheck disable=SC2206
  local -a ids=($agents)
  for agent_id in "${ids[@]}"; do
    [[ -n "$agent_id" ]] || continue
    if is_agent_id "$agent_id"; then
      printf '%s\n' "$agent_id"
    fi
  done
}

requested_service_ids_from_env() {
  local services
  local service_id

  services="$(trim_commas "${CLAWLAB_SERVICES:-}")"
  # shellcheck disable=SC2206
  local -a ids=($services)
  for service_id in "${ids[@]}"; do
    [[ -n "$service_id" ]] || continue
    printf '%s\n' "$service_id"
  done
}

service_requested_from_env() {
  local service_id="$1"
  local services
  local name

  services="$(trim_commas "${CLAWLAB_SERVICES:-}")"
  # shellcheck disable=SC2206
  local -a names=($services)
  for name in "${names[@]}"; do
    [[ "$name" == "$service_id" ]] && return 0
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
    agents)
      requested_agent_ids_from_env
      ;;
    services)
      requested_service_ids_from_env
      ;;
    *)
      printf '%s\n' "$item"
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

  for item in "${requested[@]}"; do
    item="$(normalize_requested_item "$item")"
    [[ -n "$item" ]] || continue
    while IFS= read -r expanded; do
      [[ -n "$expanded" ]] || continue
      printf '%s\n' "$expanded"
    done < <(expand_requested_item "$item")
  done
}

host_env_file() {
  printf '%s/config/custom/host/.env' "$(repo_root)"
}

repo_cfg_file() {
  printf '%s/config/custom/repo.ini' "$(repo_root)"
}

repo_cfg_value() {
  local section="$1"
  local key="$2"

  [[ -f "$(repo_cfg_file)" ]] || return 0

  awk -v wanted_section="$section" -v wanted_key="$key" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }

    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }

    /^\[[^][]+\][[:space:]]*$/ {
      current_section = substr($0, 2, length($0) - 2)
      current_section = trim(current_section)
      next
    }

    current_section != wanted_section { next }

    {
      split($0, parts, "=")
      key = trim(parts[1])
      value = trim(substr($0, index($0, "=") + 1))
      if (key == wanted_key && value != "") {
        print value
        exit
      }
    }
  ' "$(repo_cfg_file)"
}

repo_cfg_entries() {
  local section="$1"

  [[ -f "$(repo_cfg_file)" ]] || return 0

  awk -v wanted_section="$section" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }

    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }

    /^\[[^][]+\][[:space:]]*$/ {
      current_section = substr($0, 2, length($0) - 2)
      current_section = trim(current_section)
      next
    }

    current_section != wanted_section { next }

    {
      split($0, parts, "=")
      key = trim(parts[1])
      value = trim(substr($0, index($0, "=") + 1))
      if (key != "" && value != "") {
        print key "\t" value
      }
    }
  ' "$(repo_cfg_file)"
}

load_host_env() {
  local file
  file="$(host_env_file)"
  if [[ -f "$file" ]]; then
    # shellcheck disable=SC1090
    source "$file"
  fi
}

clawlab_group() {
  if [[ -n "${CLAWLAB_GROUP:-}" ]]; then
    printf '%s' "$CLAWLAB_GROUP"
  elif [[ -n "${CLAWLAB_USER:-}" ]]; then
    id -gn "$CLAWLAB_USER" 2>/dev/null || id -gn
  else
    id -gn
  fi
}

verbose_enabled() {
  case "${CLAWLAB_LOG_VERBOSE:-}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

verbose_log() {
  verbose_enabled || return 0
  printf '%s\n' "$1" >&2
}

verbose_progress() {
  verbose_enabled || return 0
  if declare -F progress >/dev/null; then
    progress "$1"
  else
    verbose_log "$1"
  fi
}

service_manifest_dir() {
  printf '%s/config/services' "$(repo_root)"
}

custom_service_manifest_dir() {
  printf '%s/config/custom/override/services' "$(repo_root)"
}

service_definition_ids() {
  local file

  {
    for file in "$(service_manifest_dir)"/*.env; do
      [[ -e "$file" ]] || continue
      basename "$file" .env
    done
    for file in "$(custom_service_manifest_dir)"/*.env; do
      [[ -e "$file" ]] || continue
      basename "$file" .env
    done
  } | sort -u
}

agent_kind_manifest_dir() {
  printf '%s/config/agents' "$(repo_root)"
}

custom_agent_kind_manifest_dir() {
  printf '%s/config/custom/override/agents' "$(repo_root)"
}

service_templates_dir() {
  printf '%s/infra/templates' "$(repo_root)"
}

service_manifest_path() {
  local service_id="$1"
  printf '%s/%s.env' "$(service_manifest_dir)" "$service_id"
}

custom_service_manifest_path() {
  local service_id="$1"
  printf '%s/%s.env' "$(custom_service_manifest_dir)" "$service_id"
}

service_definition_exists() {
  [[ -f "$(service_manifest_path "$1")" || -f "$(custom_service_manifest_path "$1")" ]]
}

agent_kind_manifest_path() {
  local kind="$1"
  printf '%s/%s.env' "$(agent_kind_manifest_dir)" "$kind"
}

custom_agent_kind_manifest_path() {
  local kind="$1"
  printf '%s/%s.env' "$(custom_agent_kind_manifest_dir)" "$kind"
}

agent_kind_definition_exists() {
  [[ -f "$(agent_kind_manifest_path "$1")" || -f "$(custom_agent_kind_manifest_path "$1")" ]]
}

reset_service_definition() {
  unset CLAWLAB_SERVICE_ID || true
  unset CLAWLAB_SERVICE_DESCRIPTION || true
  unset CLAWLAB_SERVICE_BIN || true
  unset CLAWLAB_SERVICE_BREW_TAPS || true
  unset CLAWLAB_SERVICE_BREW_PACKAGES || true
  unset CLAWLAB_SERVICE_BREW_CASKS || true
  unset CLAWLAB_SERVICE_BREW_PACKAGES_MACOS_ARM64 || true
  unset CLAWLAB_SERVICE_BREW_CASKS_MACOS_ARM64 || true
  unset CLAWLAB_SERVICE_INSTALL_OPTIONAL || true
  unset CLAWLAB_SERVICE_SYSTEMD_NAME || true
  unset CLAWLAB_SERVICE_LAUNCHD_LABEL || true
  unset CLAWLAB_SERVICE_ARGS || true
  unset CLAWLAB_SERVICE_RELOAD_ARGS || true
  unset CLAWLAB_SERVICE_STOP_COMMAND || true
  unset CLAWLAB_SERVICE_STDOUT || true
  unset CLAWLAB_SERVICE_STDERR || true
  unset CLAWLAB_SERVICE_ENV || true
  unset CLAWLAB_SERVICE_AFTER || true
  unset CLAWLAB_SERVICE_WANTS || true
  unset CLAWLAB_SERVICE_RESTART || true
  unset CLAWLAB_SERVICE_RESTART_SEC || true
  unset CLAWLAB_SERVICE_DIR || true
  unset CLAWLAB_SERVICE_STATE_DIRS || true
  unset CLAWLAB_SERVICE_USER || true
  unset CLAWLAB_SERVICE_GROUP || true
  unset CLAWLAB_SERVICE_WORKING_DIRECTORY || true
  unset CLAWLAB_SERVICE_SYSTEMD_ENVIRONMENT_FILE || true
  unset CLAWLAB_SERVICE_SYSTEMD_AMBIENT_CAPABILITIES || true
  unset CLAWLAB_SERVICE_SYSTEMD_CAPABILITY_BOUNDING_SET || true
  unset CLAWLAB_SERVICE_SYSTEMD_NO_NEW_PRIVILEGES || true
  unset CLAWLAB_SERVICE_SYSTEMD_LIMIT_NOFILE || true
  unset CLAWLAB_SERVICE_INSTALL_KIND || true
  unset CLAWLAB_SERVICE_INSTALL_SCRIPT || true
  unset CLAWLAB_SERVICE_CADDY_ROUTE || true
  unset CLAWLAB_SERVICE_CADDY_UPSTREAM || true
  unset CLAWLAB_SERVICE_CADDY_ROOT_UPSTREAM || true
  unset CLAWLAB_SERVICE_CADDY_ROOT_SERVICE_ID || true
  unset CLAWLAB_SERVICE_PORT || true
}

reset_agent_kind_definition() {
  unset CLAWLAB_AGENT_KIND || true
  unset CLAWLAB_AGENT_HOME_ENV || true
  unset CLAWLAB_AGENT_SETUP_ARGS || true
  unset CLAWLAB_AGENT_START_ARGS || true
  unset CLAWLAB_AGENT_START_PORT_FLAG || true
  unset CLAWLAB_AGENT_FORWARD_PREFIX || true
  unset CLAWLAB_AGENT_BREW_TAPS || true
  unset CLAWLAB_AGENT_BREW_PACKAGES || true
  unset CLAWLAB_AGENT_INSTALL_KIND || true
  unset CLAWLAB_AGENT_INSTALL_SCRIPT || true
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
  local file
  local custom_file
  file="$(service_manifest_path "$service_id")"
  custom_file="$(custom_service_manifest_path "$service_id")"

  if [[ ! -f "$file" && ! -f "$custom_file" ]]; then
    echo "unknown service: $service_id"
    exit 1
  fi

  reset_service_definition
  if [[ -f "$file" ]]; then
    # shellcheck disable=SC1090
    source "$file"
  fi
  if [[ -f "$custom_file" ]]; then
    # shellcheck disable=SC1090
    source "$custom_file"
  fi

  require_service_field CLAWLAB_SERVICE_ID "$service_id"
  require_service_field CLAWLAB_SERVICE_DESCRIPTION "$service_id"
  require_service_field CLAWLAB_SERVICE_BIN "$service_id"
  if [[ "$CLAWLAB_SERVICE_ID" != "$service_id" ]]; then
    echo "service manifest ${service_id} does not match CLAWLAB_SERVICE_ID=${CLAWLAB_SERVICE_ID}"
    exit 1
  fi

  CLAWLAB_SERVICE_PORT="$(repo_cfg_value "service-ports" "$service_id")"
  CLAWLAB_SERVICE_SYSTEMD_NAME="${CLAWLAB_SERVICE_SYSTEMD_NAME:-$service_id}"
  CLAWLAB_SERVICE_LAUNCHD_LABEL="${CLAWLAB_SERVICE_LAUNCHD_LABEL:-$(launchd_label_prefix).$service_id}"
  CLAWLAB_SERVICE_RESTART="${CLAWLAB_SERVICE_RESTART:-on-failure}"
  CLAWLAB_SERVICE_RESTART_SEC="${CLAWLAB_SERVICE_RESTART_SEC:-3s}"
  CLAWLAB_SERVICE_DIR="${CLAWLAB_SERVICE_DIR:-__CLAWLAB_ROOT__/state/runtimes/__SERVICE_ID__}"
  CLAWLAB_SERVICE_STDOUT="${CLAWLAB_SERVICE_STDOUT:-__CLAWLAB_ROOT__/state/logs/__SERVICE_ID__.log}"
  CLAWLAB_SERVICE_STDERR="${CLAWLAB_SERVICE_STDERR:-__CLAWLAB_ROOT__/state/logs/__SERVICE_ID__.err}"
  CLAWLAB_SERVICE_STATE_DIRS="${CLAWLAB_SERVICE_STATE_DIRS:-__CLAWLAB_SERVICE_DIR__}"
  CLAWLAB_SERVICE_WORKING_DIRECTORY="${CLAWLAB_SERVICE_WORKING_DIRECTORY:-__CLAWLAB_SERVICE_DIR__}"
}

service_manifest_field_value() {
  local service_id="$1"
  local field="$2"

  (
    local file
    local custom_file
    file="$(service_manifest_path "$service_id")"
    custom_file="$(custom_service_manifest_path "$service_id")"
    [[ -f "$file" || -f "$custom_file" ]] || exit 0
    reset_service_definition
    if [[ -f "$file" ]]; then
      # shellcheck disable=SC1090
      source "$file"
    fi
    if [[ -f "$custom_file" ]]; then
      # shellcheck disable=SC1090
      source "$custom_file"
    fi
    printf '%s' "${!field:-}"
  )
}

caddy_root_service_id() {
  service_manifest_field_value "caddy" "CLAWLAB_SERVICE_CADDY_ROOT_SERVICE_ID"
}

caddy_managed_service_ids() {
  local service_id

  service_id="$(caddy_root_service_id)"
  if [[ -n "$service_id" && "$service_id" != "caddy" ]]; then
    printf '%s\n' "$service_id"
  fi
}

run_service_installer() {
  local service_id="$1"
  local script_path
  local install_optional

  load_service_definition "$service_id"
  install_optional="${CLAWLAB_SERVICE_INSTALL_OPTIONAL:-}"

  case "${CLAWLAB_SERVICE_INSTALL_KIND:-}" in
    "")
      ;;
    script)
      script_path="$(repo_root)/${CLAWLAB_SERVICE_INSTALL_SCRIPT:-}"
      if [[ -z "${CLAWLAB_SERVICE_INSTALL_SCRIPT:-}" || ! -f "$script_path" ]]; then
        echo "service ${service_id} is missing a valid CLAWLAB_SERVICE_INSTALL_SCRIPT"
        exit 1
      fi
      if ! bash "$script_path"; then
        case "$install_optional" in
          1|true|yes|on)
            echo "warning: optional installer failed for ${service_id}; continuing"
            ;;
          *)
            exit 1
            ;;
        esac
      fi
      ;;
    *)
      echo "unsupported CLAWLAB_SERVICE_INSTALL_KIND for ${service_id}: ${CLAWLAB_SERVICE_INSTALL_KIND}"
      exit 1
      ;;
  esac
}

load_agent_kind_definition() {
  local kind="$1"
  local file
  local custom_file
  file="$(agent_kind_manifest_path "$kind")"
  custom_file="$(custom_agent_kind_manifest_path "$kind")"

  if [[ ! -f "$file" && ! -f "$custom_file" ]]; then
    echo "unknown agent kind: $kind"
    exit 1
  fi

  reset_agent_kind_definition
  if [[ -f "$file" ]]; then
    # shellcheck disable=SC1090
    source "$file"
  fi
  if [[ -f "$custom_file" ]]; then
    # shellcheck disable=SC1090
    source "$custom_file"
  fi

  if [[ -z "${CLAWLAB_AGENT_KIND:-}" ]]; then
    echo "agent kind manifest ${kind} is missing CLAWLAB_AGENT_KIND"
    exit 1
  fi

  if [[ "$CLAWLAB_AGENT_KIND" != "$kind" ]]; then
    echo "agent kind manifest ${kind} does not match CLAWLAB_AGENT_KIND=${CLAWLAB_AGENT_KIND}"
    exit 1
  fi
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

requested_agent_kinds_from_env() {
  local agent_id
  local kind

  while IFS= read -r agent_id; do
    [[ -n "$agent_id" ]] || continue
    kind="$(agent_kind_for_id "$agent_id")" || continue
    [[ -n "$kind" ]] || continue
    printf '%s\n' "$kind"
  done < <(requested_agent_ids_from_env) | sort -u
}

expand_runtime_placeholders() {
  local value="$1"
  local service_dir
  value="${value//__CLAWLAB_ROOT__/${CLAWLAB_ROOT:-$(clawlab_root)}}"
  value="${value//__CLAWLAB_USER__/${CLAWLAB_USER:-}}"
  value="${value//__CLAWLAB_GROUP__/$(clawlab_group)}"
  value="${value//__CLAWLAB_HOST__/${CLAWLAB_HOST:-}}"
  value="${value//__SERVICE_ID__/${CLAWLAB_SERVICE_ID:-}}"
  value="${value//__SERVICE_PORT__/${CLAWLAB_SERVICE_PORT:-}}"
  service_dir="${CLAWLAB_SERVICE_DIR:-__CLAWLAB_ROOT__/state/runtimes/__SERVICE_ID__}"
  service_dir="${service_dir//__CLAWLAB_ROOT__/${CLAWLAB_ROOT:-$(clawlab_root)}}"
  service_dir="${service_dir//__SERVICE_ID__/${CLAWLAB_SERVICE_ID:-}}"
  value="${value//__CLAWLAB_SERVICE_DIR__/$service_dir}"
  printf '%s' "$value"
}

expand_agent_env_placeholders() {
  local agent_id="$1"
  local value="$2"
  local agent_dir

  value="$(expand_runtime_placeholders "$value")"
  agent_dir="${CLAWLAB_ROOT:-$(clawlab_root)}/agents/$(agent_directory_name "$agent_id")"
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
  bin="$(expand_runtime_placeholders "$CLAWLAB_SERVICE_BIN")"
  if [[ "$bin" == */* ]]; then
    if [[ -x "$bin" ]]; then
      printf '%s' "$bin"
    fi
    return 0
  fi

  discover_tool_path "$bin"
}

service_description() {
  printf '%s' "$(expand_runtime_placeholders "$CLAWLAB_SERVICE_DESCRIPTION")"
}

service_systemd_name() {
  printf '%s' "$CLAWLAB_SERVICE_SYSTEMD_NAME"
}

service_launchd_label() {
  printf '%s' "$CLAWLAB_SERVICE_LAUNCHD_LABEL"
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
  local clawlab_root="$1"
  local clawlab_user="$2"
  local rendered
  local dest

  rendered="$(mktemp)"
  dest="$(agent_systemd_unit_path)"
  render_template "$(service_templates_dir)/agent.systemd" "$rendered" \
    __CLAWLAB_ROOT__ "$clawlab_root" \
    __CLAWLAB_USER__ "$clawlab_user" \
    __CLAWLAB_GROUP__ "$(clawlab_group)" \
    __PATH_BLOCK__ "$(systemd_path_block)"
  sudo install -m 0644 "$rendered" "$dest"
  rm -f "$rendered"

  printf '%s' "$dest"
}

agent_shared_env_file_path() {
  printf '%s/config/custom/env/agents.env' "${CLAWLAB_ROOT:-$(clawlab_root)}"
}

agent_env_file_path() {
  local agent_id="$1"
  printf '%s/config/custom/env/agents/%s.env' "${CLAWLAB_ROOT:-$(clawlab_root)}" "$agent_id"
}

service_shared_env_file_path() {
  printf '%s/config/custom/env/services.env' "${CLAWLAB_ROOT:-$(clawlab_root)}"
}

service_env_file_path() {
  local service_id="$1"
  printf '%s/config/custom/env/services/%s.env' "${CLAWLAB_ROOT:-$(clawlab_root)}" "$service_id"
}

agent_stdout_log_path() {
  local agent_id="$1"
  printf '%s/state/logs/agent/%s.log' "${CLAWLAB_ROOT:-$(clawlab_root)}" "$agent_id"
}

agent_stderr_log_path() {
  local agent_id="$1"
  printf '%s/state/logs/agent/%s.err' "${CLAWLAB_ROOT:-$(clawlab_root)}" "$agent_id"
}

service_stdout_log_path() {
  printf '%s' "$(expand_runtime_placeholders "$CLAWLAB_SERVICE_STDOUT")"
}

service_stderr_log_path() {
  printf '%s' "$(expand_runtime_placeholders "$CLAWLAB_SERVICE_STDERR")"
}

service_exec_start() {
  local bin_path
  local args

  bin_path="$(resolve_service_binary)"
  if [[ -z "$bin_path" ]]; then
    echo "service ${CLAWLAB_SERVICE_ID} binary not found: $(expand_runtime_placeholders "$CLAWLAB_SERVICE_BIN")" >&2
    return 1
  fi

  args="$(expand_runtime_placeholders "${CLAWLAB_SERVICE_ARGS:-}")"
  if [[ -n "$args" ]]; then
    printf '%s %s' "$bin_path" "$args"
  else
    printf '%s' "$bin_path"
  fi
}

service_exec_reload() {
  local bin_path
  local args

  args="$(expand_runtime_placeholders "${CLAWLAB_SERVICE_RELOAD_ARGS:-}")"
  if [[ -z "$args" ]]; then
    return 0
  fi

  bin_path="$(resolve_service_binary)"
  if [[ -z "$bin_path" ]]; then
    echo "service ${CLAWLAB_SERVICE_ID} binary not found: $(expand_runtime_placeholders "$CLAWLAB_SERVICE_BIN")" >&2
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
    echo "service ${CLAWLAB_SERVICE_ID} binary not found: $(expand_runtime_placeholders "$CLAWLAB_SERVICE_BIN")" >&2
    return 1
  fi

  words+=("$bin_path")
  args="$(expand_runtime_placeholders "${CLAWLAB_SERVICE_ARGS:-}")"
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
  if [[ -n "${CLAWLAB_PATH:-}" ]]; then
    systemd_assignment_block Environment "PATH=$(expand_runtime_placeholders "$CLAWLAB_PATH")"
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

  raw="${CLAWLAB_SERVICE_ENV:-}"
  [[ -n "$raw" ]] || return 0

  raw="${raw//|/$'\n'}"
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    if [[ "$item" != *=* ]]; then
      echo "invalid CLAWLAB_SERVICE_ENV assignment: $item" >&2
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
  file="$(service_env_file_path "$CLAWLAB_SERVICE_ID")"
  custom_file="$(expand_runtime_placeholders "${CLAWLAB_SERVICE_SYSTEMD_ENVIRONMENT_FILE:-}")"

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

  if [[ -n "${CLAWLAB_PATH:-}" ]]; then
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

  if [[ -n "${CLAWLAB_PATH:-}" ]]; then
    printf '    <key>PATH</key>\n'
    printf '    <string>%s</string>\n' "$(xml_escape "$(expand_runtime_placeholders "$CLAWLAB_PATH")")"
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
  file="$(service_env_file_path "$CLAWLAB_SERVICE_ID")"

  if [[ -n "${CLAWLAB_PATH:-}" || -n "${CLAWLAB_SERVICE_ENV:-}" ]] || env_file_has_assignments "$shared_file" || env_file_has_assignments "$file"; then
    has_env=1
  fi

  ((has_env == 1)) || return 0

  printf '  <key>EnvironmentVariables</key>\n'
  printf '  <dict>\n'

  if [[ -n "${CLAWLAB_PATH:-}" ]]; then
    printf '    <key>PATH</key>\n'
    printf '    <string>%s</string>\n' "$(xml_escape "$(expand_runtime_placeholders "$CLAWLAB_PATH")")"
  fi

  raw="${CLAWLAB_SERVICE_ENV:-}"
  raw="${raw//|/$'\n'}"
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    if [[ "$item" != *=* ]]; then
      echo "invalid CLAWLAB_SERVICE_ENV assignment: $item" >&2
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

ensure_clawlab_state_root() {
  local group
  group="$(clawlab_group)"
  mkdir -p \
    "$CLAWLAB_ROOT/state" \
    "$CLAWLAB_ROOT/state/logs" \
    "$CLAWLAB_ROOT/state/logs/agent" \
    "$CLAWLAB_ROOT/state/runtimes"
  chgrp "$group" \
    "$CLAWLAB_ROOT/state" \
    "$CLAWLAB_ROOT/state/logs" \
    "$CLAWLAB_ROOT/state/logs/agent" \
    "$CLAWLAB_ROOT/state/runtimes" 2>/dev/null || true
  chmod g+rwxs \
    "$CLAWLAB_ROOT/state" \
    "$CLAWLAB_ROOT/state/logs" \
    "$CLAWLAB_ROOT/state/logs/agent" \
    "$CLAWLAB_ROOT/state/runtimes" 2>/dev/null || true
}

repair_clawlab_agent_permissions() {
  local agent_id="$1"
  local agent_dir

  ensure_clawlab_state_root
  agent_dir="$CLAWLAB_ROOT/agents/$(agent_directory_name "$agent_id")"
  [[ -d "$agent_dir" ]] || return 0
  repair_clawlab_path_permissions "$agent_dir" "${2:-${CLAWLAB_USER:-}}"
}

repair_clawlab_service_permissions() {
  local owner="${1:-${CLAWLAB_SERVICE_USER:-${CLAWLAB_USER:-}}}"
  local service_dir
  local state_dirs
  local path
  local log_path
  local repaired_paths=""
  local repaired_path
  local skip

  ensure_service_directories
  service_dir="$(expand_runtime_placeholders "__CLAWLAB_SERVICE_DIR__")"
  repair_clawlab_path_permissions "$service_dir" "$owner"
  repaired_paths+="${service_dir}"$'\n'

  state_dirs="$(expand_runtime_placeholders "${CLAWLAB_SERVICE_STATE_DIRS:-}")"
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
      repair_clawlab_path_permissions "$path" "$owner"
      repaired_paths+="${path}"$'\n'
    done
  fi

  for log_path in "$(service_stdout_log_path)" "$(service_stderr_log_path)"; do
    [[ -e "$log_path" ]] || continue
    repair_clawlab_path_permissions "$log_path" "$owner"
  done
}

repair_clawlab_path_permissions() {
  local path="$1"
  local owner="${2:-${CLAWLAB_USER:-}}"
  local group
  local mismatch

  owner="$(expand_runtime_placeholders "$owner")"
  [[ -n "$owner" && -e "$path" ]] || return 0
  group="$(clawlab_group)"
  mismatch="$(find "$path" \( ! -user "$owner" -o ! -group "$group" -o \( -type d \( ! -perm -020 -o ! -perm -2000 \) \) -o \( -type f ! -perm -020 \) \) -print -quit 2>/dev/null || true)"
  [[ -n "$mismatch" ]] || return 0
  verbose_log "[repair] $path -> $owner:$group, group-writable directories/files"
  sudo chown -R "$owner:$group" "$path"
  sudo find "$path" -type d -exec chmod g+rwxs {} +
  sudo find "$path" -type f -exec chmod g+rw {} +
}

ensure_group_directory() {
  local path="$1"
  local group="$2"

  [[ -n "$path" ]] || return 0
  mkdir -p "$path"
  chgrp "$group" "$path" 2>/dev/null || true
  chmod g+rwxs "$path" 2>/dev/null || true
}

ensure_service_directories() {
  local stdout_path
  local stderr_path
  local state_dirs
  local path
  local group

  ensure_clawlab_state_root
  group="$(clawlab_group)"

  stdout_path="$(service_stdout_log_path)"
  stderr_path="$(service_stderr_log_path)"
  ensure_group_directory "$(dirname "$stdout_path")" "$group"
  ensure_group_directory "$(dirname "$stderr_path")" "$group"
  ensure_group_directory "$(expand_runtime_placeholders "__CLAWLAB_SERVICE_DIR__")" "$group"

  state_dirs="$(expand_runtime_placeholders "${CLAWLAB_SERVICE_STATE_DIRS:-}")"
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
    __AFTER_BLOCK__ "$(systemd_assignment_block After "$(expand_runtime_placeholders "${CLAWLAB_SERVICE_AFTER:-}")")" \
    __WANTS_BLOCK__ "$(systemd_assignment_block Wants "$(expand_runtime_placeholders "${CLAWLAB_SERVICE_WANTS:-}")")" \
    __USER_BLOCK__ "$(systemd_assignment_block User "$(expand_runtime_placeholders "${CLAWLAB_SERVICE_USER:-}")")" \
    __GROUP_BLOCK__ "$(systemd_assignment_block Group "$(expand_runtime_placeholders "${CLAWLAB_SERVICE_GROUP:-__CLAWLAB_GROUP__}")")" \
    __WORKING_DIRECTORY_BLOCK__ "$(systemd_assignment_block WorkingDirectory "$(expand_runtime_placeholders "${CLAWLAB_SERVICE_WORKING_DIRECTORY:-}")")" \
    __PATH_BLOCK__ "$(service_systemd_environment_block)" \
    __ENVIRONMENT_FILE_BLOCK__ "$(service_systemd_environment_file_block)" \
    __EXEC_START__ "$exec_start" \
    __EXEC_RELOAD_BLOCK__ "$(systemd_assignment_block ExecReload "$exec_reload")" \
    __EXEC_STOP_BLOCK__ "$(systemd_assignment_block ExecStop "$(expand_runtime_placeholders "${CLAWLAB_SERVICE_STOP_COMMAND:-}")")" \
    __RESTART__ "$CLAWLAB_SERVICE_RESTART" \
    __RESTART_SEC__ "$CLAWLAB_SERVICE_RESTART_SEC" \
    __STDOUT__ "$(service_stdout_log_path)" \
    __STDERR__ "$(service_stderr_log_path)" \
    __AMBIENT_CAPABILITIES_BLOCK__ "$(systemd_assignment_block AmbientCapabilities "$(expand_runtime_placeholders "${CLAWLAB_SERVICE_SYSTEMD_AMBIENT_CAPABILITIES:-}")")" \
    __CAPABILITY_BOUNDING_SET_BLOCK__ "$(systemd_assignment_block CapabilityBoundingSet "$(expand_runtime_placeholders "${CLAWLAB_SERVICE_SYSTEMD_CAPABILITY_BOUNDING_SET:-}")")" \
    __NO_NEW_PRIVILEGES_BLOCK__ "$(systemd_assignment_block NoNewPrivileges "$(expand_runtime_placeholders "${CLAWLAB_SERVICE_SYSTEMD_NO_NEW_PRIVILEGES:-}")")" \
    __LIMIT_NOFILE_BLOCK__ "$(systemd_assignment_block LimitNOFILE "$(expand_runtime_placeholders "${CLAWLAB_SERVICE_SYSTEMD_LIMIT_NOFILE:-}")")"
}

install_systemd_service_unit() {
  local service_id="$1"
  local rendered
  local dest

  load_service_definition "$service_id"
  ensure_service_directories

  rendered="$(mktemp)"
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
    __USERNAME_BLOCK__ "$(launchd_string_block UserName "$(expand_runtime_placeholders "${CLAWLAB_SERVICE_USER:-}")")" \
    __GROUPNAME_BLOCK__ "$(launchd_string_block GroupName "$(expand_runtime_placeholders "${CLAWLAB_SERVICE_GROUP:-__CLAWLAB_GROUP__}")")" \
    __WORKING_DIRECTORY_BLOCK__ "$(launchd_string_block WorkingDirectory "$(expand_runtime_placeholders "${CLAWLAB_SERVICE_WORKING_DIRECTORY:-}")")" \
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

  rendered="$(mktemp)"
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
  local clawlab_root="$2"
  local clawlab_user="$3"
  local label
  local template
  local rendered
  local dest

  label="$(service_label_for_agent "$agent_id")"
  template="$(service_templates_dir)/agent.launchd.plist"
  rendered="$(mktemp)"
  dest="/Library/LaunchDaemons/${label}.plist"

  sudo launchctl bootout system "$dest" >/dev/null 2>&1 || true
  render_template "$template" "$rendered" \
    __LABEL__ "$label" \
    __CLAWLAB_ROOT__ "$clawlab_root" \
    __CLAWLAB_USER__ "$clawlab_user" \
    __CLAWLAB_GROUP__ "$(clawlab_group)" \
    __ENVIRONMENT_VARIABLES_BLOCK__ "$(agent_launchd_environment_variables_block "$agent_id")" \
    __AGENT_ID__ "$agent_id"
  sudo install -m 0644 "$rendered" "$dest"
  rm -f "$rendered"

  printf '%s' "$dest"
}
