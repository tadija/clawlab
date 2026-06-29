#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/core.sh"

load_host_env

AELAB_ROOT="${AELAB_ROOT:-$(aelab_root)}"

usage() {
  cat <<'EOF'
Usage:
  preflight.sh [service-or-agent...|agents|services|repo]
EOF
}

ERRORS=0
WARNINGS=0

note_ok() {
  printf 'ok: %s\n' "$1"
}

note_warn() {
  WARNINGS=$((WARNINGS + 1))
  printf 'warn: %s\n' "$1"
}

note_error() {
  ERRORS=$((ERRORS + 1))
  printf 'error: %s\n' "$1"
}

group_exists() {
  local group="$1"
  if is_macos; then
    dscacheutil -q group -a name "$group" | grep -q '^name: '
  else
    getent group "$group" >/dev/null 2>&1
  fi
}

agent_directory_exists() {
  local agent_id="$1"
  find "$(repo_root)/agents" -maxdepth 1 -mindepth 1 -type d -name "${agent_id}-*" | grep -q .
}

check_duplicate_words() {
  local label="$1"
  local raw="$2"
  local duplicates

  duplicates="$(
    printf '%s\n' "$(trim_commas "$raw")" |
      tr ' ' '\n' |
      sed '/^$/d' |
      sort |
      uniq -d
  )"

  if [[ -n "$duplicates" ]]; then
    note_error "${label} contains duplicates: $(printf '%s' "$duplicates" | tr '\n' ' ' | xargs)"
  else
    note_ok "${label} has no duplicates"
  fi
}

check_repo_port_duplicates() {
  local section="$1"
  local label="$2"
  local duplicates

  duplicates="$(
    repo_cfg_entries "$section" |
      awk -F'\t' '{print $2}' |
      sed '/^$/d' |
      sort |
      uniq -d
  )"

  if [[ -n "$duplicates" ]]; then
    note_error "${label} contains duplicate port values: $(printf '%s' "$duplicates" | tr '\n' ' ' | xargs)"
  else
    note_ok "${label} has no duplicate port values"
  fi
}

check_cross_port_collisions() {
  local duplicates

  duplicates="$(
    {
      repo_cfg_entries "agent-ports" | awk -F'\t' '{print $2}'
      repo_cfg_entries "service-ports" | awk -F'\t' '{print $2}'
    } |
      sed '/^$/d' |
      sort |
      uniq -d
  )"

  if [[ -n "$duplicates" ]]; then
    note_error "agent and service ports collide: $(printf '%s' "$duplicates" | tr '\n' ' ' | xargs)"
  else
    note_ok "agent and service ports do not collide"
  fi
}

check_projects() {
  local raw="${AELAB_PROJECTS:-}"
  local item
  local title
  local path

  [[ -n "$raw" ]] || {
    note_warn "AELAB_PROJECTS is empty"
    return 0
  }

  for item in $raw; do
    if [[ "$item" != *=* ]]; then
      note_error "invalid AELAB_PROJECTS entry: $item"
      continue
    fi
    title="${item%%=*}"
    path="${item#*=}"
    [[ -n "$title" ]] || note_error "AELAB_PROJECTS entry has empty title: $item"
    if [[ "$path" != /* ]]; then
      note_error "AELAB_PROJECTS path must be absolute: $item"
      continue
    fi
    if [[ ! -e "$path" ]]; then
      note_error "AELAB_PROJECTS path does not exist: $path"
      continue
    fi
  done

  note_ok "AELAB_PROJECTS paths resolved"
}

check_host_env() {
  local host_config
  local duplicate_keys
  local host_url
  local tls_mode
  host_config="$(host_config_file)"

  if [[ ! -f "$host_config" ]]; then
    note_error "missing host config: $host_config"
    return 0
  fi
  note_ok "host config present: $host_config"

  duplicate_keys="$(
    awk '
      /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
      /^[[:space:]]*\[/ { in_section = 1; next }
      in_section { next }
      /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ {
        key=$0
        sub(/=.*/, "", key)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
        seen[key]++
      }
      END {
        for (key in seen) {
          if (seen[key] > 1) print key
        }
      }
    ' "$host_config" | sort
  )"
  if [[ -n "$duplicate_keys" ]]; then
    note_warn "host config redefines keys: $(printf '%s' "$duplicate_keys" | tr '\n' ' ' | xargs)"
  else
    note_ok "host config keys are unique"
  fi

  [[ -n "${AELAB_USER:-}" ]] || note_error "AELAB_USER is not set"
  [[ -n "${AELAB_ROOT:-}" ]] || note_error "AELAB_ROOT is not set"
  [[ -n "${AELAB_HOST:-}" ]] || note_error "AELAB_HOST is not set"

  if [[ -n "${AELAB_USER:-}" ]]; then
    if id "$AELAB_USER" >/dev/null 2>&1; then
      note_ok "AELAB_USER exists: $AELAB_USER"
    else
      note_error "AELAB_USER does not exist: $AELAB_USER"
    fi
  fi

  if [[ -n "${AELAB_GROUP:-}" ]]; then
    if group_exists "$AELAB_GROUP"; then
      note_ok "AELAB_GROUP exists: $AELAB_GROUP"
    else
      note_error "AELAB_GROUP does not exist: $AELAB_GROUP"
    fi
  else
    note_warn "AELAB_GROUP is not set; falling back to the primary group for ${AELAB_USER:-current user}"
  fi

  if [[ -n "${AELAB_ROOT:-}" ]]; then
    if [[ -d "$AELAB_ROOT" ]]; then
      note_ok "AELAB_ROOT exists: $AELAB_ROOT"
      [[ -w "$AELAB_ROOT" ]] || note_warn "AELAB_ROOT is not writable by current user: $AELAB_ROOT"
    else
      note_error "AELAB_ROOT does not exist: $AELAB_ROOT"
    fi
  fi

  if [[ -n "${AELAB_HOST:-}" ]]; then
    host_url="$(repo_cfg_value "hosts" "$AELAB_HOST")"
    if [[ -n "$host_url" ]]; then
      note_ok "AELAB_HOST is defined in $(repo_cfg_file): $AELAB_HOST"
    else
      note_error "AELAB_HOST is missing from [hosts] in $(repo_cfg_file): $AELAB_HOST"
    fi
  fi

  tls_mode="$(printf '%s' "${AELAB_CADDY_TLS:-off}" | tr '[:upper:]' '[:lower:]')"
  case "$tls_mode" in
    off|"")
      if [[ "${host_url:-}" == https://* ]]; then
        note_warn "AELAB_CADDY_TLS is off but [hosts] URL is HTTPS: ${host_url}"
      else
        note_ok "AELAB_CADDY_TLS is off"
      fi
      ;;
    internal)
      if [[ -z "${host_url:-}" ]]; then
        note_error "AELAB_CADDY_TLS=internal needs AELAB_HOST in [hosts]"
      elif [[ "$host_url" == https://* ]]; then
        note_ok "AELAB_CADDY_TLS=internal matches HTTPS host URL"
      else
        note_error "AELAB_CADDY_TLS=internal needs an HTTPS [hosts] URL: ${host_url}"
      fi
      ;;
    *)
      note_error "unsupported AELAB_CADDY_TLS: ${AELAB_CADDY_TLS}"
      ;;
  esac

  check_duplicate_words "AELAB_AGENTS" "${AELAB_AGENTS:-}"
  check_duplicate_words "AELAB_SERVICES" "${AELAB_SERVICES:-}"
  check_projects
}

check_repo_ports() {
  check_repo_port_duplicates "agent-ports" "[agent-ports]"
  check_repo_port_duplicates "service-ports" "[service-ports]"
  check_cross_port_collisions
}

check_agent_target() {
  local agent_id="$1"
  local kind
  local port

  if ! agent_directory_exists "$agent_id"; then
    note_error "assigned agent directory is missing for ${agent_id}"
    return 0
  fi

  if ! kind="$(agent_kind_for_id "$agent_id" 2>/dev/null)"; then
    note_error "unable to determine kind for agent ${agent_id}"
    return 0
  fi

  if ! toml_section_exists "$(agent_kind_manifest_path "$kind")" "$kind"; then
    note_error "agent ${agent_id} references unknown kind manifest: ${kind}"
    return 0
  fi

  load_agent_kind_definition "$kind"
  note_ok "agent ${agent_id} resolves to kind ${kind}"

  if [[ -n "${AELAB_AGENT_START_PORT_FLAG:-}" ]]; then
    port="$(repo_cfg_value "agent-ports" "$agent_id")"
    if [[ -n "$port" ]]; then
      note_ok "agent ${agent_id} has port ${port}"
    else
      note_error "agent ${agent_id} is managed but missing [agent-ports] entry"
    fi
  fi
}

check_service_target() {
  local service_id="$1"

  if ! service_definition_exists "$service_id"; then
    note_error "unknown service manifest: ${service_id}"
    return 0
  fi

  load_service_definition "$service_id"
  note_ok "service ${service_id} manifest resolved"

  if [[ -n "${AELAB_SERVICE_CADDY_ROUTE:-}" || "${AELAB_SERVICE_ARGS:-}" == *"__SERVICE_PORT__"* ]]; then
    if [[ -n "${AELAB_SERVICE_PORT:-}" ]]; then
      note_ok "service ${service_id} has port ${AELAB_SERVICE_PORT}"
    else
      note_error "service ${service_id} needs a [service-ports] entry"
    fi
  fi
}

main() {
  local -a requested=()
  local item

  while (($#)); do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      *)
        break
        ;;
    esac
  done

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    requested+=("$item")
  done < <(resolve_requested_items "$@")

  echo "== host config =="
  check_host_env

  echo
  echo "== repo config =="
  check_repo_ports

  echo
  echo "== requested targets =="
  if ((${#requested[@]} == 0)); then
    note_warn "no explicit or host-assigned targets resolved"
  fi

  for item in "${requested[@]}"; do
    if [[ "$item" == "repo" ]]; then
      note_ok "repo target selected"
    elif is_agent_id "$item"; then
      check_agent_target "$item"
    else
      check_service_target "$item"
    fi
  done

  echo
  if ((ERRORS > 0)); then
    printf 'preflight: failed with %d error(s) and %d warning(s)\n' "$ERRORS" "$WARNINGS"
    exit 1
  fi

  printf 'preflight: ok'
  if ((WARNINGS > 0)); then
    printf ' (%d warning(s))' "$WARNINGS"
  fi
  printf '\n\n'
}

main "$@"
