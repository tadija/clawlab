#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/core.sh"

AELAB_LOG_PREFIX="update"
load_host_env

AELAB_ROOT="${AELAB_ROOT:-$(aelab_root)}"

usage() {
  cat <<'EOF'
Usage:
  update.sh [options] [service-or-agent...]

Options:
  --no-pull             skip git pull --ff-only
  --no-restart          skip infra restart
  -y, --yes             auto-confirm broad restart prompts
  --dry-run             print what would run without changing anything
  -h, --help            show this help

Examples:
  ./ae infra update
  ./ae infra update caddy
  ./ae infra update services
  ./ae infra update core-http core-tty
EOF
}

run() {
  if ((DRY_RUN == 1)); then
    printf '[update] dry-run:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  "$@"
}

git_status_short() {
  git -C "$AELAB_ROOT" status --short
}

confirm_broad_restart() {
  local -a requested=("$@")
  local -a expanded=()
  local item
  local reply
  local broad=0

  for item in "${requested[@]}"; do
    case "$item" in
      agents|services|all)
        broad=1
        ;;
    esac
  done

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    expanded+=("$item")
  done < <(resolve_requested_items "${requested[@]}")

  if ((broad == 0 && ${#expanded[@]} <= 1)); then
    return 0
  fi

  if ((${#expanded[@]} > 0)); then
    log "restart target expands to ${#expanded[@]} items: ${expanded[*]}"
  else
    log "broad restart target requested: ${requested[*]}"
  fi
  if ((DRY_RUN == 1)); then
    return 0
  fi

  if ((YES == 1)); then
    log "auto-confirmed via --yes"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    echo "broad restart requested in non-interactive mode; pass --yes, explicit targets, or --no-restart" >&2
    exit 1
  fi

  printf '[update] Continue with core restart? [y/N]: ' >&2
  read -r reply
  case "${reply,,}" in
    y|yes)
      return 0
      ;;
    *)
      log "restart skipped"
      DO_RESTART=0
      return 0
      ;;
  esac
}

stash_local_changes() {
  local status

  status="$(git_status_short)"
  if [[ -z "$status" ]]; then
    log "worktree clean"
    STASHED=0
    return 0
  fi

  log "local changes before update:"
  printf '%s\n' "$status"

  STASHED=1
  run git -C "$AELAB_ROOT" stash push --include-untracked -m "aelab update $(date '+%Y-%m-%d %H:%M:%S %Z')"
}

restore_local_changes() {
  if ((STASHED == 0)); then
    return 0
  fi

  log "restoring stashed local changes"
  if ((DRY_RUN == 1)); then
    run git -C "$AELAB_ROOT" stash apply
    return 0
  fi

  if git -C "$AELAB_ROOT" stash apply; then
    git -C "$AELAB_ROOT" stash drop >/dev/null
    return 0
  fi

  echo "failed to apply stashed local changes; stash was kept" >&2
  exit 1
}

main() {
  local -a restart_args=()
  local arg
  local script_dir

  DO_PULL=1
  DO_RESTART=1
  DRY_RUN=0
  STASHED=0
  YES=0

  while (($#)); do
    arg="$1"
    shift
    case "$arg" in
      --no-pull)
        DO_PULL=0
        ;;
      --no-restart)
        DO_RESTART=0
        ;;
      -y|--yes)
        YES=1
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      --)
        restart_args+=("$@")
        break
        ;;
      -*)
        echo "unknown option: $arg" >&2
        usage >&2
        exit 1
        ;;
      *)
        restart_args+=("$arg")
        ;;
    esac
  done

  script_dir="$(cd "$(dirname "$0")" && pwd)"

  if ((${#restart_args[@]} == 0)); then
    restart_args=(core)
  fi

  log "fetching"
  run git -C "$AELAB_ROOT" fetch --prune

  stash_local_changes

  if ((DO_PULL == 1)); then
    log "pulling latest with --ff-only"
    run git -C "$AELAB_ROOT" pull --ff-only
  else
    log "pull skipped"
  fi

  restore_local_changes

  if ((DO_RESTART == 1)); then
    confirm_broad_restart "${restart_args[@]}"
  fi

  if ((DO_RESTART == 1)); then
    log "restarting ${restart_args[*]}"
    run bash "$script_dir/restart.sh" "${restart_args[@]}"
  else
    log "restart skipped"
  fi

  log "status"
  run bash "$script_dir/status.sh" "${restart_args[@]}" || true

  log "completed"
}

main "$@"
