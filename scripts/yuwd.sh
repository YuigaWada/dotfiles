#!/usr/bin/env bash
set -euo pipefail

dotfiles_dir="${DOTFILES_DIR:-$HOME/.zsh}"
justfile="$dotfiles_dir/justfile"

if [[ ! -f "$justfile" ]]; then
  echo "yuwd: $justfile was not found" >&2
  exit 1
fi

case "${1:-}" in
start | stop | restart)
  service_action="$1"
  case "${2:-aerospace}" in
  aerospace) set -- "$service_action-aerospace" ;;
  *)
    echo "usage: yuwd $service_action [aerospace]" >&2
    exit 2
    ;;
  esac
  ;;
esac

if [[ "${1:-}" == "repair" ]]; then
  case "${2:-nix-volume}" in
  nix | nix-volume) set -- repair-nix-volume ;;
  *)
    echo "usage: yuwd repair {nix|nix-volume}" >&2
    exit 2
    ;;
  esac
fi

exec just --justfile "$justfile" --working-directory "$dotfiles_dir" "$@"
