#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/core.sh"

load_host_env

AELAB_ROOT="${AELAB_ROOT:-$(aelab_root)}"
REPAIR_MODE="none"

usage() {
  cat <<'EOF'
Usage:
  doctor.sh [service-or-agent...|repo] [--repair|--repair-full|--no-repair]
EOF
}

service_bin() {
  local tool="$1"
  local bin
  bin="$(discover_tool_path "$tool")"
  if [[ -n "$bin" ]]; then
    printf '%s' "$bin"
  else
    printf '%s' "(missing)"
  fi
}

append_unique_word() {
  local list="$1"
  local word="$2"

  [[ -n "$word" ]] || {
    printf '%s' "$list"
    return 0
  }

  case " $list " in
    *" $word "*) printf '%s' "$list" ;;
    *) printf '%s' "$(trim_whitespace "$list $word")" ;;
  esac
}

first_arg() {
  local raw="$1"
  raw="${raw%%|*}"
  printf '%s' "$raw"
}

agent_kind_tool() {
  local kind="$1"

  load_agent_kind_definition "$kind"
  if [[ -n "${AELAB_AGENT_START_ARGS:-}" ]]; then
    first_arg "$AELAB_AGENT_START_ARGS"
  elif [[ -n "${AELAB_AGENT_TUI_ARGS:-}" ]]; then
    first_arg "$AELAB_AGENT_TUI_ARGS"
  elif [[ -n "${AELAB_AGENT_SETUP_ARGS:-}" ]]; then
    first_arg "$AELAB_AGENT_SETUP_ARGS"
  elif [[ -n "${AELAB_AGENT_FORWARD_PREFIX:-}" ]]; then
    first_arg "$AELAB_AGENT_FORWARD_PREFIX"
  elif [[ -n "${AELAB_AGENT_BREW_PACKAGES:-}" ]]; then
    first_arg "$AELAB_AGENT_BREW_PACKAGES"
  elif [[ -n "${AELAB_AGENT_BREW_CASKS:-}" ]]; then
    first_arg "$AELAB_AGENT_BREW_CASKS"
  fi
}

host_short_name() {
  hostname -s 2>/dev/null || hostname 2>/dev/null || printf '%s' "unknown"
}

service_state_for_item() {
  local item="$1"
  if [[ "$item" == "repo" ]]; then
    printf '%s' "local"
  elif is_agent_id "$item"; then
    if ! agent_is_managed "$item"; then
      printf '%s' "interactive"
      return 0
    fi
    if is_linux; then
      systemd_service_state "agent@${item}"
    else
      launchd_service_state "$(service_label_for_agent "$item")"
    fi
  elif service_definition_exists "$item"; then
    load_service_definition "$item"
    if is_linux; then
      systemd_service_state "$(service_systemd_name)"
    else
      launchd_service_state "$(service_launchd_label)"
    fi
  fi
}

main() {
  local -a requested=()
  local -a targets=()
  local item
  local arg

  while (($#)); do
    arg="$1"
    shift
    case "$arg" in
      --repair)
        REPAIR_MODE="shallow"
        ;;
      --repair-full)
        REPAIR_MODE="full"
        ;;
      --no-repair)
        REPAIR_MODE="none"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        targets+=("$arg")
        ;;
    esac
  done

  case "$REPAIR_MODE" in
    shallow|full|none) ;;
    *)
      usage
      echo "unsupported repair mode: $REPAIR_MODE"
      exit 1
      ;;
  esac

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    requested+=("$item")
  done < <(resolve_requested_items "${targets[@]+"${targets[@]}"}")

  echo "== host =="
  printf 'host: %s\n' "$(host_short_name)"
  printf 'user: %s\n' "${AELAB_USER:-unset}"
  printf 'manager: %s\n' "$(service_manager)"
  printf 'root: %s\n' "$AELAB_ROOT"
  printf 'repair: %s\n' "$REPAIR_MODE"

  echo
  echo "== checks =="
  local relevant_tools=""
  local missing_tools=""
  local found_tools=""
  local relevant_agent_kinds=""
  local seen_services=""
  local found_service_bins=""
  local missing_service_bins=""
  local tool

  for item in "${requested[@]+"${requested[@]}"}"; do
    if [[ "$item" == "repo" ]]; then
      :
    elif is_agent_id "$item"; then
      local kind
      if ! kind="$(agent_kind_for_id "$item" 2>/dev/null)"; then
        continue
      fi
      relevant_agent_kinds="$(append_unique_word "$relevant_agent_kinds" "$kind")"
      tool="$(agent_kind_tool "$kind")"
      relevant_tools="$(append_unique_word "$relevant_tools" "$tool")"
    elif service_definition_exists "$item"; then
      case " $seen_services " in
        *" $item "*) ;;
        *)
          local resolved_bin
          load_service_definition "$item"
          resolved_bin="$(resolve_service_binary)"
          if [[ -n "$resolved_bin" ]]; then
            found_service_bins="$(append_unique_word "$found_service_bins" "$item")"
          elif [[ -z "${AELAB_SERVICE_GROUP_MEMBERS:-}" ]]; then
            missing_service_bins="$(append_unique_word "$missing_service_bins" "$item")"
          fi
          seen_services="$(append_unique_word "$seen_services" "$item")"
          ;;
      esac
    fi
  done

  for tool in $relevant_tools; do
    if [[ "$(service_bin "$tool")" == "(missing)" ]]; then
      missing_tools="$(append_unique_word "$missing_tools" "$tool")"
    else
      found_tools="$(append_unique_word "$found_tools" "$tool")"
    fi
  done
  printf 'tools: %s\n' "${found_tools:-none}"
  if [[ -n "$missing_tools" ]]; then
    printf 'missing tools: %s\n' "$missing_tools"
  fi

  if [[ -n "$found_service_bins" ]]; then
    printf 'service binaries: %s\n' "$found_service_bins"
  fi
  if [[ -n "$missing_service_bins" ]]; then
    printf 'missing service binaries: %s\n' "$missing_service_bins"
  fi

  printf 'agent kinds: %s\n' "${relevant_agent_kinds:-none}"

  if ((${#requested[@]} == 0)); then
    echo
    print_no_requested_items_hint
    exit 0
  fi

  local problems=0
  local state
  local problem_items=""
  local log_items=""

  echo
  echo "== requested =="
  for item in "${requested[@]}"; do
    if [[ "$item" == "repo" ]] || is_agent_id "$item" || service_definition_exists "$item"; then
      repair_requested_item "$item"
      state="$(service_state_for_item "$item")"
      printf '%s: %s\n' "$item" "$state"
      if [[ "$state" != active && "$state" != running && "$state" != waiting && "$state" != interactive && "$state" != local ]]; then
        problems=$((problems + 1))
        problem_items+="${item}: ${state}"$'\n'
        log_items+="${item} "
      fi
    else
      echo "unknown service or agent id: $item"
      exit 1
    fi
  done

  if ((problems > 0)); then
    log_items="$(trim_whitespace "$log_items")"
    echo
    echo "== problems =="
    printf '%s' "$problem_items"
    echo
    echo "== next =="
    printf 'inspect logs: ./ae infra log --short %s\n' "$log_items"
    printf 'permission repair, known generated paths: ./ae infra doctor %s --repair\n' "$log_items"
    printf 'permission repair, full: ./ae infra doctor %s --repair-full\n' "$log_items"
    if [[ -n "$missing_service_bins" ]]; then
      printf 'install missing service binaries: ./ae infra bootstrap services\n'
    fi
    echo
    printf '%s\n' "doctor: found $problems problem(s)"
    exit 1
  fi

  echo
  echo "doctor: ok"
}

repair_requested_item() {
  local item="$1"

  case "$REPAIR_MODE" in
    none)
      return 0
      ;;
    shallow)
      if [[ "$item" == "repo" ]]; then
        repair_aelab_repo_permissions "$AELAB_USER"
      elif is_agent_id "$item"; then
        repair_agent_known_generated_paths "$item"
      fi
      ;;
    full)
      if [[ "$item" == "repo" ]]; then
        repair_aelab_repo_permissions "$AELAB_USER"
      elif is_agent_id "$item"; then
        repair_aelab_agent_permissions "$item" "$AELAB_USER"
      elif service_definition_exists "$item"; then
        load_service_definition "$item"
        repair_aelab_service_permissions
      fi
      ;;
  esac
}

repair_agent_known_generated_paths() {
  local agent_id="$1"
  local kind
  local agent_dir
  local relative_path

  if ! kind="$(agent_kind_for_id "$agent_id" 2>/dev/null)"; then
    return 0
  fi

  agent_dir="$AELAB_ROOT/agents/$(agent_directory_name "$agent_id")"
  [[ -d "$agent_dir" ]] || return 0

  while IFS= read -r relative_path; do
    [[ -n "$relative_path" ]] || continue
    repair_aelab_path_permissions_shallow "$agent_dir/$relative_path" "$AELAB_USER"
  done < <(known_generated_repair_paths_for_agent_kind "$kind")
}

known_generated_repair_paths_for_agent_kind() {
  local kind="$1"

  case "$kind" in
    openclaw)
      printf '%s\n' \
        ".openclaw" \
        ".openclaw/tasks" \
        ".openclaw/openclaw.json.last-good"
      ;;
  esac
}

main "$@"
