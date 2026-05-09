#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
CLAWLAB_ROOT="${CLAWLAB_ROOT:-$repo_root}"

port=27017
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) port="$2"; shift 2 ;;
    *) shift ;;
  esac
done

state_root="$CLAWLAB_ROOT/state/runtimes/mongodb"
data_dir="$state_root/data"

mkdir -p "$data_dir"

exec mongod \
  --dbpath "$data_dir" \
  --bind_ip 127.0.0.1 \
  --port "$port"
