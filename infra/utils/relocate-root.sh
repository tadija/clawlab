#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  sudo bash infra/utils/relocate-root.sh [target-root]

Example:
  sudo bash infra/utils/relocate-root.sh /Users/Shared/clawlab
  sudo bash infra/utils/relocate-root.sh /srv/clawlab
EOF
}

script_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

current_root() {
  cd "$(script_dir)/../.." && pwd
}

stat_owner_group() {
  local path="$1"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    stat -f '%Su:%Sg' "$path"
  else
    stat -c '%U:%G' "$path"
  fi
}

default_target_root() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    printf '%s\n' "/Users/Shared/clawlab"
  else
    printf '%s\n' "/srv/clawlab"
  fi
}

main() {
  local target_root="${1:-$(default_target_root)}"
  local source_root
  local parent_dir
  local backup_root
  local owner_group

  if (($# > 1)); then
    usage
    exit 1
  fi

  source_root="$(current_root)"
  backup_root="${source_root}.relocate-backup"
  parent_dir="$(dirname "$target_root")"

  if [[ "$source_root" == "$target_root" ]]; then
    echo "source and target are the same: $source_root"
    exit 0
  fi

  if [[ -e "$target_root" ]]; then
    echo "target already exists: $target_root" >&2
    exit 1
  fi

  if [[ -e "$backup_root" ]]; then
    echo "backup already exists: $backup_root" >&2
    exit 1
  fi

  owner_group="$(stat_owner_group "$source_root")"

  mkdir -p "$parent_dir"
  rsync -a "$source_root/" "$target_root/"
  chown -R "$owner_group" "$target_root"
  chmod -R g+rwX "$target_root"
  find "$target_root" -type d -exec chmod g+s {} +

  mv "$source_root" "$backup_root"
  ln -s "$target_root" "$source_root"

  cat <<EOF
relocated clawlab root
  source backup: $backup_root
  active root:   $target_root
  compatibility: $source_root -> $target_root
EOF
}

main "$@"
