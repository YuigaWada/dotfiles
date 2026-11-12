#!/usr/bin/env bash
set -euo pipefail

apply=false
if [[ "${1:-}" == "--apply" ]]; then
  apply=true
elif [[ $# -gt 0 ]]; then
  echo "usage: dotfiles-cleanup-legacy [--apply]" >&2
  exit 2
fi

legacy_paths=(
  "$HOME/.local/share/mise"
  "$HOME/.config/mise"
  "$HOME/.nvm"
  "$HOME/.pyenv"
  "$HOME/.zplug"
  "$HOME/powerlevel10k"
  "$HOME/.cargo/bin"
  "$HOME/.rustup"
  "$HOME/.local/bin/mise"
  "$HOME/.local/bin/uv"
  "$HOME/.local/bin/uvx"
  "$HOME/Library/LaunchAgents/com.asmvik.yabai.plist"
  "$HOME/Library/LaunchAgents/com.koekeishiya.skhd.plist"
  "$HOME/Library/LaunchAgents/com.koekeishiya.yabai.plist"
)

# GUI applications and all Homebrew casks remain host-managed. Only formulae
# whose active services have been migrated explicitly are safe to uninstall.
nix_managed_brew_formulae=(
  skhd
  yabai
  yuigawada/versions/yabai@7.1.15
)

brew_bins=()
for brew_candidate in \
  /opt/homebrew/bin/brew \
  /usr/local/homebrew-x86/bin/brew \
  /usr/local/Homebrew/bin/brew \
  /usr/local/bin/brew; do
  [[ ! -x "$brew_candidate" ]] || brew_bins+=("$brew_candidate")
done

echo "Legacy paths that currently exist:"
for legacy_path in "${legacy_paths[@]}"; do
  [[ ! -e "$legacy_path" ]] || printf '  %s\n' "$legacy_path"
done

for brew_bin in "${brew_bins[@]}"; do
  echo "Homebrew installation: $brew_bin"
  echo "Homebrew formulae:"
  "$brew_bin" list --formula -1 2>/dev/null || true
  echo "Homebrew casks (preserved):"
  "$brew_bin" list --cask -1 2>/dev/null || true
done

if [[ "$apply" != true ]]; then
  echo
  echo "Dry run only. Re-run with --apply after dotfiles-doctor reports Nix paths."
  exit 0
fi

for required_command in node codex claude; do
  required_path="$(command -v "$required_command" 2>/dev/null || true)"
  resolved_path="$(readlink -f "$required_path" 2>/dev/null || true)"
  if [[ "$resolved_path" != /nix/store/* ]]; then
    echo "refusing cleanup: $required_command is not provided by Nix ($resolved_path)" >&2
    exit 1
  fi
done

printf 'Type remove-legacy-tools to continue: '
read -r confirmation
if [[ "$confirmation" != "remove-legacy-tools" ]]; then
  echo "Cancelled."
  exit 1
fi

backup_root="$HOME/.local/state/dotfiles-migration/$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$backup_root"
move_failure_sources=()
move_failure_targets=()

move_to_backup() {
  source_path="$1"
  backup_name="$2"
  if [[ -e "$source_path" || -L "$source_path" ]]; then
    echo "moving $source_path to $backup_root/$backup_name"
    if ! mv -- "$source_path" "$backup_root/$backup_name"; then
      move_failure_sources+=("$source_path")
      move_failure_targets+=("$backup_root/$backup_name")
      echo "warning: could not move $source_path; continuing with other paths" >&2
    fi
  fi
}

move_to_backup "$HOME/.local/share/mise" mise-data
move_to_backup "$HOME/.config/mise" mise-config
move_to_backup "$HOME/.nvm" nvm
move_to_backup "$HOME/.pyenv" pyenv
move_to_backup "$HOME/.zplug" zplug
move_to_backup "$HOME/powerlevel10k" powerlevel10k
move_to_backup "$HOME/.cargo/bin" cargo-bin
move_to_backup "$HOME/.rustup" rustup
move_to_backup "$HOME/.local/bin/mise" local-bin-mise
move_to_backup "$HOME/.local/bin/uv" local-bin-uv
move_to_backup "$HOME/.local/bin/uvx" local-bin-uvx
move_to_backup "$HOME/Library/LaunchAgents/com.asmvik.yabai.plist" launch-agent-com.asmvik.yabai.plist
move_to_backup "$HOME/Library/LaunchAgents/com.koekeishiya.skhd.plist" launch-agent-com.koekeishiya.skhd.plist
move_to_backup "$HOME/Library/LaunchAgents/com.koekeishiya.yabai.plist" launch-agent-com.koekeishiya.yabai.plist

for brew_bin in "${brew_bins[@]}"; do
  for service in yabai skhd; do
    "$brew_bin" services stop "$service" >/dev/null 2>&1 || true
  done

  for formula in "${nix_managed_brew_formulae[@]}"; do
    if "$brew_bin" list --formula "$formula" >/dev/null 2>&1; then
      "$brew_bin" uninstall --formula --force "$formula" || true
    fi
  done

  "$brew_bin" autoremove || true
done

echo "Movable legacy user directories were moved to: $backup_root"

if [[ "${#move_failure_sources[@]}" -gt 0 ]]; then
  echo "The following paths need elevated ownership cleanup:" >&2
  for failure_index in "${!move_failure_sources[@]}"; do
    printf '  sudo mv -- %q %q\n' \
      "${move_failure_sources[$failure_index]}" \
      "${move_failure_targets[$failure_index]}" >&2
  done
  echo "Do not run this whole cleanup command with sudo." >&2
  exit 1
fi

echo "Run the Nix switch command once more, then run dotfiles-doctor."
