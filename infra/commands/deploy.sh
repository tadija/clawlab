#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/core.sh"

AELAB_LOG_PREFIX="deploy"
load_host_env

usage() {
  cat <<'EOF'
Usage:
  deploy.sh [options] [host...]

Options:
  --no-pull             pass through to remote update
  --no-restart          pass through to remote update
  --dry-run             print remote commands without running them
  --                    pass remaining args to remote update
  -h, --help            show this help

Examples:
  ./ae infra deploy
  ./ae infra deploy dev-server app-server
  ./ae infra deploy --no-restart
  ./ae infra deploy dev-server -- caddy
EOF
}

shell_quote() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

deploy_host_names() {
  repo_cfg_entries "deploy-hosts" | awk -F'\t' '{print $1}'
}

deploy_host_spec() {
  local host="$1"
  repo_cfg_value "deploy-hosts" "$host"
}

run_remote_update() {
  local host="$1"
  local spec="$2"
  shift 2
  local ssh_target
  local ssh_port
  local root
  local remote_cmd
  local arg
  local -a ssh_args=()

  IFS=: read -r ssh_target ssh_port root <<<"$spec"
  if [[ -z "${root:-}" ]]; then
    root="$ssh_port"
    ssh_port=""
  fi

  if [[ -z "$ssh_target" || -z "$root" || "$ssh_target" == "$spec" ]]; then
    echo "invalid [deploy-hosts] entry for ${host}: ${spec}" >&2
    return 1
  fi

  if [[ -n "$ssh_port" ]]; then
    ssh_args+=("-p" "$ssh_port")
  fi

  remote_cmd="cd $(shell_quote "$root") && bash infra/commands/update.sh --yes"
  for arg in "$@"; do
    remote_cmd+=" $(shell_quote "$arg")"
  done

  if ((DRY_RUN == 1)); then
    printf '[deploy] dry-run: ssh'
    if ((${#ssh_args[@]} > 0)); then
      printf ' %q' "${ssh_args[@]}"
    fi
    printf ' %q %q' "$ssh_target" "$remote_cmd"
    printf '\n'
    return 0
  fi

  log "[$host] updating via $ssh_target:$root"
  ssh "${ssh_args[@]}" "$ssh_target" "$remote_cmd"
}

main() {
  local -a requested_hosts=()
  local -a update_args=()
  local -a hosts=()
  local arg
  local host
  local spec
  local failures=0

  DRY_RUN=0

  while (($#)); do
    arg="$1"
    shift
    case "$arg" in
      --dry-run)
        DRY_RUN=1
        update_args+=("$arg")
        ;;
      --no-pull|--no-restart)
        update_args+=("$arg")
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      --)
        update_args+=("$@")
        break
        ;;
      -*)
        echo "unknown option: $arg" >&2
        usage >&2
        exit 1
        ;;
      *)
        requested_hosts+=("$arg")
        ;;
    esac
  done

  if ((${#requested_hosts[@]} == 0)); then
    while IFS= read -r host; do
      [[ -n "$host" ]] || continue
      hosts+=("$host")
    done < <(deploy_host_names)
  else
    hosts=("${requested_hosts[@]}")
  fi

  if ((${#hosts[@]} == 0)); then
    echo "no [deploy-hosts] entries configured in $(repo_cfg_file)" >&2
    exit 1
  fi

  for host in "${hosts[@]}"; do
    spec="$(deploy_host_spec "$host")"
    if [[ -z "$spec" ]]; then
      echo "unknown deploy host: $host" >&2
      failures=$((failures + 1))
      continue
    fi
    if run_remote_update "$host" "$spec" "${update_args[@]}"; then
      log "[$host] complete"
    else
      echo "[deploy] [$host] failed" >&2
      failures=$((failures + 1))
    fi
  done

  if ((failures > 0)); then
    echo "[deploy] failed on ${failures} host(s)" >&2
    exit 1
  fi

  log "completed"
}

main "$@"
