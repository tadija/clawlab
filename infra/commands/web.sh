#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/core.sh"

AELAB_LOG_PREFIX="web"
load_host_env

usage() {
  cat <<'EOF'
Usage:
  web.sh [--print]

Options:
  --print  print the web UI URL without opening it
EOF
}

web_url() {
  local url=""
  local port

  if [[ -n "${AELAB_HOST:-}" ]]; then
    url="$(repo_cfg_value "hosts" "$AELAB_HOST")"
  fi

  if [[ -n "$url" ]]; then
    printf '%s\n' "$url"
    return 0
  fi

  port="$(repo_cfg_value "service-ports" "core-http")"
  if [[ -z "$port" ]]; then
    port="2108"
  fi

  printf 'http://localhost:%s\n' "$port"
}

open_web() {
  local url="$1"

  if command -v open >/dev/null 2>&1; then
    open "$url"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url"
  elif command -v wslview >/dev/null 2>&1; then
    wslview "$url"
  else
    log "no browser opener found; open manually: $url"
  fi
}

main() {
  local print_only=0
  local arg
  local url

  for arg in "$@"; do
    case "$arg" in
      --print)
        print_only=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        exit 1
        ;;
    esac
  done

  url="$(web_url)"
  printf '%s\n' "$url"

  if ((print_only == 0)); then
    open_web "$url"
  fi
}

main "$@"
