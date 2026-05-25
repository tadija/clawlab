#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")/../.." && pwd)/commands/core.sh"

if command -v nanobot >/dev/null 2>&1; then
  echo "nanobot already installed"
  exit 0
fi

if ! command -v uv >/dev/null 2>&1; then
  echo "uv is required to install nanobot"
  exit 1
fi

uv tool install nanobot-ai

if ! command -v nanobot >/dev/null 2>&1; then
  echo "nanobot install completed but nanobot is not on PATH"
  exit 1
fi

echo "installed nanobot"
