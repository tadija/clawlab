#!/usr/bin/env bash
set -euo pipefail

is_macos() {
  [[ "$(uname -s)" == "Darwin" ]]
}

is_arm64() {
  [[ "$(uname -m)" == "arm64" ]]
}

if command -v vibetunnel >/dev/null 2>&1; then
  echo "vibetunnel already installed"
  exit 0
fi

if is_macos && is_arm64; then
  echo "vibetunnel is managed via Homebrew cask on macOS arm64"
  echo "run ./cmd infra bootstrap so Brewfile casks are installed on this host"
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required to install vibetunnel"
  exit 1
fi

npm install -g vibetunnel

if ! command -v vibetunnel >/dev/null 2>&1; then
  echo "vibetunnel install completed but vibetunnel is not on PATH"
  exit 1
fi

echo "installed vibetunnel"

