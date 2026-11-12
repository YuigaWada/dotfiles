#!/usr/bin/env bash
set -euo pipefail

mode="update"
case "${1:-}" in
"") ;;
--bootstrap) mode="bootstrap" ;;
--update) ;;
*)
  echo "usage: update-agent-tools [--bootstrap|--update]" >&2
  exit 2
  ;;
esac

profile="${AGENT_TOOLS_PROFILE:-${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/agent-tools}"
flake_ref="${AGENT_TOOLS_FLAKE_REF:-github:NixOS/nixpkgs/nixpkgs-unstable}"
nix_bin="${NIX_BIN:-nix}"
host_updates="${AGENT_TOOLS_HOST_UPDATES:-1}"
host_system="${AGENT_TOOLS_SYSTEM:-$(uname -s)}"
claude_native_bin="${CLAUDE_NATIVE_BIN:-$HOME/.local/bin/claude}"
codex_brew_bin="${CODEX_BREW_BIN:-}"
lock_parent="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
lock_dir="${AGENT_TOOLS_LOCK_DIR:-$lock_parent/yuwd-agent-tools-update-$UID.lock}"

if [[ -z "$codex_brew_bin" && "$host_system" == "Darwin" ]]; then
  for brew_candidate in \
    /opt/homebrew/bin/brew \
    /usr/local/homebrew-x86/bin/brew \
    /usr/local/bin/brew; do
    if [[ -x "$brew_candidate" ]] &&
      "$brew_candidate" list --cask codex >/dev/null 2>&1; then
      codex_brew_bin="$brew_candidate"
      break
    fi
  done
fi

mkdir -p "$(dirname "$profile")" "$(dirname "$lock_dir")"
if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "agent tools update is already running; skipping"
  exit 0
fi

cleanup() {
  rmdir "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT

# claude-code is unfree in nixpkgs. Keep the exception scoped to these two
# explicitly selected packages and the updater process.
export NIXPKGS_ALLOW_UNFREE=1

missing_packages=()
[[ -x "$profile/bin/codex" ]] || missing_packages+=("$flake_ref#codex")
[[ -x "$profile/bin/claude" ]] || missing_packages+=("$flake_ref#claude-code")

if ((${#missing_packages[@]} > 0)); then
  "$nix_bin" profile add --impure --profile "$profile" "${missing_packages[@]}"
fi

if [[ "$mode" == "update" ]]; then
  "$nix_bin" profile upgrade --impure --profile "$profile" --all --refresh

  # The Codex desktop/code-mode host is supplied by the Homebrew cask on this
  # Mac, while Claude's native installer deliberately updates independently of
  # nixpkgs. Keep the binaries users actually launch current as well as the Nix
  # fallbacks; nixpkgs can lag upstream releases for a few days.
  if [[ "$host_updates" == "1" ]]; then
    if [[ "$host_system" == "Darwin" && -x "$codex_brew_bin" ]] &&
      "$codex_brew_bin" list --cask codex >/dev/null 2>&1; then
      "$codex_brew_bin" upgrade --cask codex
    fi
    if [[ -x "$claude_native_bin" ]]; then
      "$claude_native_bin" update
    fi
  fi

  "$nix_bin" profile wipe-history --profile "$profile" --older-than 14d
fi

"$profile/bin/codex" --version
"$profile/bin/claude" --version
