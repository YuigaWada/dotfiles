set shell := ["bash", "-euo", "pipefail", "-c"]

import? "justfile.local"

default:
    @just --list

# Install/switch the matching macOS or Ubuntu configuration.
switch:
    ./scripts/bootstrap-nix.sh

# Install Nix first, then switch the matching configuration.
bootstrap:
    ./scripts/bootstrap-nix.sh --install-nix

# Evaluate every supported host without activating it.
check:
    nix flake check --all-systems --no-build

# Format Nix, shell, and Markdown sources.
fmt:
    nix fmt
    shfmt -w -i 2 scripts

doctor:
    nix run .#doctor

# Restore the macOS boot-time /nix mount artifacts; the script prompts first.
repair-nix-volume:
    ./scripts/repair-nix-volume.sh

# Control the Nix-managed AeroSpace LaunchAgent.
start-aerospace:
    test "$(uname -s)" = Darwin
    label="gui/$UID/org.nixos.aerospace"; if launchctl print "$label" 2>/dev/null | awk '$1 == "state" && $3 == "running" { running = 1 } END { exit !running }'; then echo "AeroSpace is already running"; else launchctl bootout "$label" >/dev/null 2>&1 || true; launchctl bootstrap "gui/$UID" "$HOME/Library/LaunchAgents/org.nixos.aerospace.plist"; fi

stop-aerospace:
    test "$(uname -s)" = Darwin
    label="gui/$UID/org.nixos.aerospace"; if launchctl print "$label" >/dev/null 2>&1; then launchctl bootout "$label"; else echo "AeroSpace is already stopped"; fi

restart-aerospace: stop-aerospace start-aerospace

# Dry-run only. Use `nix run .#cleanup-legacy -- --apply` after verification.
cleanup-preview:
    nix run .#cleanup-legacy

develop:
    nix develop

# Open a shell in the repository root.
shell:
    cd "{{justfile_directory()}}" && "${SHELL:-/bin/sh}"
