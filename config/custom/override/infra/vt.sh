#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
CLAWLAB_ROOT="${CLAWLAB_ROOT:-$(cd "$script_dir/../../../.." && pwd)}"

# shellcheck disable=SC1091
source "$CLAWLAB_ROOT/infra/commands/core.sh"

load_host_env

usage() {
  cat <<'EOF'
Usage:
  vt.sh [vt-args...]

Runs the VibeTunnel vt wrapper against the clawlab-managed VibeTunnel
service. With no args, starts an interactive shell session.
EOF
}

if (($# > 0)); then
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
  esac
fi

load_service_definition "vibetunnel"

service_env_value() {
  local key="$1"
  local raw="${CLAWLAB_SERVICE_ENV:-}"
  local item
  local item_key
  local item_value

  raw="${raw//|/$'\n'}"
  while IFS= read -r item; do
    [[ -n "$item" && "$item" == *=* ]] || continue
    item_key="${item%%=*}"
    item_value="${item#*=}"
    if [[ "$item_key" == "$key" ]]; then
      expand_runtime_placeholders "$item_value"
      return 0
    fi
  done <<< "$raw"
}

resolve_vibetunnel_bin() {
  local bin

  bin="$(expand_runtime_placeholders "${CLAWLAB_VIBETUNNEL_BIN:-}")"
  if [[ -z "$bin" ]]; then
    bin="$(command -v vibetunnel 2>/dev/null || true)"
  fi
  if [[ -z "$bin" && -x "/Applications/VibeTunnel.app/Contents/Resources/vibetunnel" ]]; then
    bin="/Applications/VibeTunnel.app/Contents/Resources/vibetunnel"
  fi
  printf '%s' "$bin"
}

resolve_vt_script() {
  local bin="$1"
  local script

  script="$(expand_runtime_placeholders "${CLAWLAB_VIBETUNNEL_VT:-}")"
  if [[ -n "$script" ]]; then
    printf '%s' "$script"
    return 0
  fi
  if [[ -n "$bin" ]]; then
    script="$(dirname "$bin")/../bin/vt"
    if [[ -x "$script" ]]; then
      printf '%s' "$script"
      return 0
    fi
    script="$(dirname "$bin")/vt"
    if [[ -x "$script" ]]; then
      printf '%s' "$script"
      return 0
    fi
  fi
  script="$(command -v vt 2>/dev/null || true)"
  if [[ -n "$script" ]]; then
    printf '%s' "$script"
    return 0
  fi
}

vt_bin="$(resolve_vibetunnel_bin)"
vt_script="$(resolve_vt_script "$vt_bin")"
vt_fwd_bin="$(dirname "$vt_bin")/vibetunnel-fwd"
runtime_home="$(service_env_value HOME)"
runtime_home="${runtime_home:-$(expand_runtime_placeholders "__CLAWLAB_SERVICE_DIR__/home")}"
control_dir="$(service_env_value VIBETUNNEL_CONTROL_DIR)"
control_dir="${control_dir:-$(expand_runtime_placeholders "__CLAWLAB_SERVICE_DIR__/control")}"
real_home="${HOME:-}"
real_zdotdir="${ZDOTDIR:-}"
real_shell="${SHELL:-/bin/bash}"

if [[ -z "$real_home" ]]; then
  real_home="$(eval "printf '%s' ~" 2>/dev/null || true)"
fi
if [[ -z "$real_zdotdir" ]]; then
  real_zdotdir="$real_home"
fi

if [[ ! -x "$vt_script" ]]; then
  echo "VibeTunnel vt wrapper not executable: $vt_script" >&2
  exit 1
fi

if [[ ! -x "$vt_bin" ]]; then
  echo "VibeTunnel binary not executable: $vt_bin" >&2
  exit 1
fi

args=("$@")
if ((${#args[@]} == 0)); then
  args=(-S /usr/bin/env "HOME=$real_home" "ZDOTDIR=$real_zdotdir" "SHELL=$real_shell" "$real_shell" -l)
elif [[ "${args[0]}" == "--shell" || "${args[0]}" == "-i" ]]; then
  args=(-S /usr/bin/env "HOME=$real_home" "ZDOTDIR=$real_zdotdir" "SHELL=$real_shell" "$real_shell" -l "${args[@]:1}")
elif [[ "${args[0]}" == "--no-shell-wrap" || "${args[0]}" == "-S" ]]; then
  args=(-S /usr/bin/env "HOME=$real_home" "ZDOTDIR=$real_zdotdir" "SHELL=$real_shell" "${args[@]:1}")
elif [[ "${args[0]}" != "status" && "${args[0]}" != "version" && "${args[0]}" != "--version" ]]; then
  args=(-S /usr/bin/env "HOME=$real_home" "ZDOTDIR=$real_zdotdir" "SHELL=$real_shell" "${args[@]}")
fi

if [[ -n "${VIBETUNNEL_SESSION_ID:-}" ]]; then
  session_json="$control_dir/$VIBETUNNEL_SESSION_ID/session.json"
  if [[ ! -f "$session_json" ]] || ! grep -q '"status"[[:space:]]*:[[:space:]]*"running"' "$session_json"; then
    unset VIBETUNNEL_SESSION_ID
  fi
fi

export VIBETUNNEL_BIN="$vt_bin"
export VIBETUNNEL_CONTROL_DIR="$control_dir"
export HOME="$runtime_home"
if [[ -x "$vt_fwd_bin" ]]; then
  export VIBETUNNEL_FWD_BIN="$vt_fwd_bin"
fi

if (($# == 0)); then
  caddy_route="$(expand_runtime_placeholders "${CLAWLAB_SERVICE_CADDY_ROUTE:-}")"
  if [[ "$caddy_route" == :* ]]; then
    host_name="${CLAWLAB_HOST:-$(hostname -s 2>/dev/null || hostname)}"
    echo "http://${host_name}:${caddy_route#:}"
  fi
fi

exec /bin/bash "$vt_script" "${args[@]}"
