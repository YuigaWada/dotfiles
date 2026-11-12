#!/usr/bin/env bash
set -euo pipefail

install_nix=false
interactive=false
assume_yes=false

usage() {
  cat <<EOF
usage: $0 [--install-nix] [--interactive | --yes]

  --install-nix  Install Nix when it is not already available.
  --interactive  Confirm the detected Ubuntu user and home interactively.
  --yes          Accept the detected Ubuntu user and home non-interactively.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --install-nix) install_nix=true ;;
  --interactive) interactive=true ;;
  --yes) assume_yes=true ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
  esac
  shift
done

if [[ "$interactive" == true && "$assume_yes" == true ]]; then
  echo "--interactive and --yes cannot be used together" >&2
  exit 2
fi

dotfiles_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nix_flags=(--extra-experimental-features "nix-command flakes")
host_os="$(uname -s)"
detected_username="$(id -un)"
detected_home="$HOME"
profile=""

case "$host_os" in
Darwin)
  if [[ "$(uname -m)" != "arm64" ]]; then
    echo "This repository currently targets Apple Silicon macOS." >&2
    exit 1
  fi
  ;;
Linux)
  printf 'Detected Ubuntu identity:\n'
  printf '  user: %s\n' "$detected_username"
  printf '  home: %s\n' "$detected_home"

  if [[ "$assume_yes" != true ]]; then
    if [[ ! -t 0 ]]; then
      echo "Cannot confirm the detected identity without a terminal; re-run with --yes." >&2
      exit 2
    fi
    read -r -p "Use this identity? [Y/n] " reply
    case "${reply:-y}" in
    y | Y | yes | YES) ;;
    *)
      echo "Aborted without changing the Home Manager profile." >&2
      exit 1
      ;;
    esac
  fi

  case "$(uname -m)" in
  x86_64) profile="current@ubuntu-x86_64" ;;
  aarch64 | arm64) profile="current@ubuntu-aarch64" ;;
  *)
    echo "Unsupported Linux architecture: $(uname -m)" >&2
    exit 1
    ;;
  esac
  ;;
*)
  echo "Unsupported operating system: $host_os" >&2
  exit 1
  ;;
esac

export DOTFILES_USERNAME="$detected_username"
export DOTFILES_HOME="$detected_home"

# A partial Darwin installation can leave the APFS store intact but mounted at
# /Volumes/Nix Store instead of /nix. Treat that as a mount-artifact failure,
# not as a missing Nix installation: reinstalling would risk the existing store
# without repairing the next boot.
if [[ "$host_os" == "Darwin" && ! -d /nix/store ]] &&
  /usr/sbin/diskutil info "Nix Store" >/dev/null 2>&1; then
  cat >&2 <<EOF
The existing Nix Store is not mounted at /nix.

Restore its macOS boot artifacts, reboot, and run bootstrap again:
  $dotfiles_dir/scripts/repair-nix-volume.sh
  sudo shutdown -r now
EOF
  exit 2
fi

# A freshly installed multi-user Nix may be running while the current shell
# still has its old PATH. Load the known profile before deciding to reinstall.
if [[ -r /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
  # shellcheck disable=SC1091
  source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
elif [[ -r "$HOME/.nix-profile/etc/profile.d/nix.sh" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi

if ! command -v nix >/dev/null 2>&1; then
  if [[ "$install_nix" != true ]]; then
    cat >&2 <<'MESSAGE'
Nix is not installed.

Install the official multi-user distribution, then re-run this script:
  curl -L https://nixos.org/nix/install | sh -s -- --daemon

Alternatively, let this script invoke that installer:
  ./scripts/bootstrap-nix.sh --install-nix
MESSAGE
    exit 2
  fi

  installer_file="$(mktemp "${TMPDIR:-/tmp}/install-nix.XXXXXX")"
  trap 'rm -f "$installer_file"' EXIT
  curl --fail --location --proto '=https' --tlsv1.2 \
    https://nixos.org/nix/install --output "$installer_file"
  sh "$installer_file" --daemon

  # shellcheck disable=SC1091
  source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi

nix_bin="$(command -v nix)"

case "$host_os" in
Darwin)
  # Use root's HOME for the root-owned darwin-rebuild process. Keeping the
  # invoking user's HOME makes Nix warn that root does not own it. Pass the
  # invoking identity explicitly so sudo cannot replace it with root's.
  sudo -H /usr/bin/env \
    "DOTFILES_USERNAME=$detected_username" "DOTFILES_HOME=$detected_home" \
    "$nix_bin" "${nix_flags[@]}" run --impure "$dotfiles_dir#darwin-rebuild" -- \
    switch --impure --flake "$dotfiles_dir#current"
  ;;
Linux)
  "$nix_bin" "${nix_flags[@]}" run "$dotfiles_dir#home-manager" -- \
    switch --impure --option experimental-features "nix-command flakes" \
    -b before-nix --flake "$dotfiles_dir#$profile"
  ;;
esac

# The invoking shell can predate installation of the mutable agent-tools
# profile. Check the activated tools without requiring a new shell first.
agent_tools_profile="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/agent-tools"
export PATH="$agent_tools_profile/bin:$PATH"

exec "$nix_bin" "${nix_flags[@]}" run "$dotfiles_dir#doctor"
