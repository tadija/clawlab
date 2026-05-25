#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")/../.." && pwd)/commands/core.sh"

load_host_env

MERCURY_PACKAGE="${MERCURY_PACKAGE:-@cosmicstack/mercury-agent}"
MERCURY_SHARED_ROOT="${MERCURY_SHARED_ROOT:-$(repo_root)/state/runtimes/mercury}"
MERCURY_SHARED_HOME="${MERCURY_SHARED_HOME:-$MERCURY_SHARED_ROOT/home}"

if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required to install mercury"
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node is required to run mercury"
  exit 1
fi

if ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)' >/dev/null 2>&1; then
  echo "mercury requires Node.js >= 20"
  exit 1
fi

agent_dir_from_mercury_home() {
  local mercury_home="$1"
  if [[ "$mercury_home" == */.mercury ]]; then
    dirname "$mercury_home"
  else
    printf '%s\n' "$mercury_home"
  fi
}

discover_mercury_agent_dirs() {
  local agent_id
  local kind
  local dir
  local found=0

  while IFS= read -r agent_id; do
    [[ -n "$agent_id" ]] || continue
    kind="$(agent_kind_for_id "$agent_id")" || continue
    [[ "$kind" == "mercury" ]] || continue
    dir="$(repo_root)/agents/$(agent_directory_name "$agent_id")"
    [[ -d "$dir" ]] || continue
    printf '%s\n' "$dir"
    found=1
  done < <(requested_agent_ids_from_env)

  if ((found == 1)); then
    return 0
  fi

  find "$(repo_root)/agents" -maxdepth 1 -mindepth 1 -type d -name '*-mercury' | sort
}

install_shared_runtime() {
  local shared_bin="$MERCURY_SHARED_ROOT/node_modules/.bin/mercury"

  if [[ -x "$shared_bin" ]]; then
    return 0
  fi

  mkdir -p "$MERCURY_SHARED_ROOT" "$MERCURY_SHARED_HOME"

  HOME="$MERCURY_SHARED_HOME" npm install --prefix "$MERCURY_SHARED_ROOT" "$MERCURY_PACKAGE"

  if [[ ! -x "$shared_bin" ]]; then
    echo "mercury install completed but ${shared_bin} was not created"
    exit 1
  fi
}

install_for_agent_dir() {
  local agent_dir="$1"
  local mercury_home="$agent_dir/.mercury"
  local mercury_bin="$agent_dir/.local/bin/mercury"
  local shared_bin="$MERCURY_SHARED_ROOT/node_modules/.bin/mercury"

  install_shared_runtime

  mkdir -p \
    "$agent_dir/.local/bin" \
    "$mercury_home"/{memory,skills,soul}

  ln -sf "$shared_bin" "$mercury_bin"

  if [[ ! -f "$mercury_home/.env" ]]; then
    touch "$mercury_home/.env"
  fi

  echo "installed mercury for ${agent_dir} using shared runtime ${MERCURY_SHARED_ROOT}"
}

main() {
  local -a agent_dirs=()
  local agent_dir

  if [[ -n "${MERCURY_HOME:-}" ]]; then
    agent_dirs=("$(agent_dir_from_mercury_home "$MERCURY_HOME")")
  else
    while IFS= read -r agent_dir; do
      [[ -n "$agent_dir" ]] || continue
      agent_dirs+=("$agent_dir")
    done < <(discover_mercury_agent_dirs)
  fi

  if ((${#agent_dirs[@]} == 0)); then
    echo "unable to determine a Mercury agent directory"
    echo "set MERCURY_HOME or create a *-mercury agent under $(repo_root)/agents"
    exit 1
  fi

  for agent_dir in "${agent_dirs[@]}"; do
    install_for_agent_dir "$agent_dir"
  done
}

main "$@"
