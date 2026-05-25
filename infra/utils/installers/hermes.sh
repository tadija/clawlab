#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")/../.." && pwd)/commands/core.sh"

load_host_env

HERMES_INSTALL_URL="https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh"
HERMES_SHARED_ROOT="${HERMES_SHARED_ROOT:-$(repo_root)/state/runtimes/hermes}"
HERMES_SHARED_HOME="${HERMES_SHARED_HOME:-$HERMES_SHARED_ROOT/home}"
HERMES_SHARED_INSTALL_DIR="${HERMES_SHARED_INSTALL_DIR:-$HERMES_SHARED_ROOT/hermes-agent}"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required to install hermes"
  exit 1
fi

agent_dir_from_hermes_home() {
  local hermes_home="$1"
  if [[ "$hermes_home" == */.hermes ]]; then
    dirname "$hermes_home"
  else
    printf '%s\n' "$hermes_home"
  fi
}

discover_hermes_agent_dirs() {
  local agent_id
  local kind
  local dir
  local found=0

  while IFS= read -r agent_id; do
    [[ -n "$agent_id" ]] || continue
    kind="$(agent_kind_for_id "$agent_id")" || continue
    [[ "$kind" == "hermes" ]] || continue
    dir="$(repo_root)/agents/$(agent_directory_name "$agent_id")"
    [[ -d "$dir" ]] || continue
    printf '%s\n' "$dir"
    found=1
  done < <(requested_agent_ids_from_env)

  if ((found == 1)); then
    return 0
  fi

  find "$(repo_root)/agents" -maxdepth 1 -mindepth 1 -type d -name '*-hermes' | sort
}

install_for_agent_dir() {
  local agent_dir="$1"
  local hermes_home="$agent_dir/.hermes"
  local hermes_bin="$agent_dir/.local/bin/hermes"
  local shared_bin="$HERMES_SHARED_INSTALL_DIR/venv/bin/hermes"

  if [[ ! -x "$shared_bin" ]]; then
    mkdir -p "$HERMES_SHARED_ROOT" "$HERMES_SHARED_HOME"

    curl -fsSL "$HERMES_INSTALL_URL" | \
      HOME="$HERMES_SHARED_HOME" HERMES_HOME="$HERMES_SHARED_HOME/.hermes" bash -s -- \
        --skip-setup \
        --dir "$HERMES_SHARED_INSTALL_DIR" \
        --hermes-home "$HERMES_SHARED_HOME/.hermes"

    if [[ ! -x "$shared_bin" ]]; then
      echo "hermes install completed but ${shared_bin} was not created"
      exit 1
    fi
  fi

  mkdir -p "$agent_dir/.local/bin" "$hermes_home"/{cron,sessions,logs,pairing,hooks,image_cache,audio_cache,memories,skills}
  ln -sf "$shared_bin" "$hermes_bin"

  if [[ ! -f "$hermes_home/.env" ]]; then
    if [[ -f "$HERMES_SHARED_INSTALL_DIR/.env.example" ]]; then
      cp "$HERMES_SHARED_INSTALL_DIR/.env.example" "$hermes_home/.env"
    else
      touch "$hermes_home/.env"
    fi
  fi

  if [[ ! -f "$hermes_home/config.yaml" && -f "$HERMES_SHARED_INSTALL_DIR/cli-config.yaml.example" ]]; then
    cp "$HERMES_SHARED_INSTALL_DIR/cli-config.yaml.example" "$hermes_home/config.yaml"
  fi

  if [[ ! -f "$hermes_home/SOUL.md" ]]; then
    cat > "$hermes_home/SOUL.md" <<'EOF'
# Hermes Soul

You are Hermes, an autonomous AI agent.
EOF
  fi

  if [[ -d "$HERMES_SHARED_INSTALL_DIR/skills" ]] && [[ -z "$(find "$hermes_home/skills" -mindepth 1 -maxdepth 1 ! -name '.bundled_manifest' -print -quit 2>/dev/null)" ]]; then
    cp -R "$HERMES_SHARED_INSTALL_DIR/skills/." "$hermes_home/skills/"
  fi

  echo "installed hermes for ${agent_dir} using shared runtime ${HERMES_SHARED_INSTALL_DIR}"
}

main() {
  local -a agent_dirs=()
  local agent_dir

  if [[ -n "${HERMES_HOME:-}" ]]; then
    agent_dirs=("$(agent_dir_from_hermes_home "$HERMES_HOME")")
  else
    while IFS= read -r agent_dir; do
      [[ -n "$agent_dir" ]] || continue
      agent_dirs+=("$agent_dir")
    done < <(discover_hermes_agent_dirs)
  fi

  if ((${#agent_dirs[@]} == 0)); then
    echo "unable to determine a Hermes agent directory"
    echo "set HERMES_HOME or create a *-hermes agent under $(repo_root)/agents"
    exit 1
  fi

  for agent_dir in "${agent_dirs[@]}"; do
    install_for_agent_dir "$agent_dir"
  done
}

main "$@"
