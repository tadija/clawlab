#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
AELAB_ROOT="${AELAB_ROOT:-$repo_root}"

port=3306
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) port="$2"; shift 2 ;;
    *) shift ;;
  esac
done

state_root="$AELAB_ROOT/state/runtimes/mysql"
data_dir="$state_root/data"
socket_path="$state_root/mysql.sock"
pid_file="$state_root/mysql.pid"

mkdir -p "$data_dir"

if [[ ! -d "$data_dir/mysql" ]]; then
  mysqld --initialize-insecure --datadir="$data_dir"
fi

exec mysqld \
  --datadir="$data_dir" \
  --socket="$socket_path" \
  --pid-file="$pid_file" \
  --bind-address=127.0.0.1 \
  --port="$port"
