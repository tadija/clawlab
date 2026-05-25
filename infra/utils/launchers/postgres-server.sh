#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
AELAB_ROOT="${AELAB_ROOT:-$repo_root}"

port=5432
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) port="$2"; shift 2 ;;
    *) shift ;;
  esac
done

state_root="$AELAB_ROOT/state/runtimes/postgres"
data_dir="$state_root/data"
socket_dir="$state_root"

mkdir -p "$data_dir"

if [[ ! -f "$data_dir/PG_VERSION" ]]; then
  initdb -D "$data_dir"
fi

exec postgres \
  -D "$data_dir" \
  -k "$socket_dir" \
  -h 127.0.0.1 \
  -p "$port"
