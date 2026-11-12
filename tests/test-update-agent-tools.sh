#!/usr/bin/env bash
set -euo pipefail

script_argument="${1:?path to update-agent-tools.sh is required}"
script_under_test="$(cd "$(dirname "$script_argument")" && pwd)/$(basename "$script_argument")"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/bin" "$test_root/profile" "$test_root/runtime"

cat >"$test_root/bin/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$AGENT_TOOLS_TEST_LOG"

profile=""
previous=""
for argument in "$@"; do
  if [[ "$previous" == "--profile" ]]; then
    profile="$argument"
    break
  fi
  previous="$argument"
done

if [[ "$*" == *"profile add"* ]]; then
  mkdir -p "$profile/bin"
  printf '#!%s\nprintf "codex-cli test\\n"\n' "$BASH" >"$profile/bin/codex"
  printf '#!%s\nprintf "claude test\\n"\n' "$BASH" >"$profile/bin/claude"
  chmod +x "$profile/bin/codex" "$profile/bin/claude"
fi
EOF
chmod +x "$test_root/bin/nix"

export AGENT_TOOLS_LOCK_DIR="$test_root/runtime/updater.lock"
export AGENT_TOOLS_PROFILE="$test_root/profile"
export AGENT_TOOLS_TEST_LOG="$test_root/nix-commands"
export AGENT_TOOLS_HOST_UPDATES=0
export NIX_BIN="$test_root/bin/nix"

bash "$script_under_test" --bootstrap >/dev/null
grep -q '^profile add .*#codex .*#claude-code$' "$AGENT_TOOLS_TEST_LOG"
if grep -q 'profile upgrade\|profile wipe-history' "$AGENT_TOOLS_TEST_LOG"; then
  echo "bootstrap unexpectedly upgraded an existing profile" >&2
  exit 1
fi

: >"$AGENT_TOOLS_TEST_LOG"
bash "$script_under_test" --update >/dev/null
grep -q '^profile upgrade .* --all --refresh$' "$AGENT_TOOLS_TEST_LOG"
grep -q '^profile wipe-history .* --older-than 14d$' "$AGENT_TOOLS_TEST_LOG"
if grep -q 'profile add' "$AGENT_TOOLS_TEST_LOG"; then
  echo "update unexpectedly reinstalled existing tools" >&2
  exit 1
fi

cat >"$test_root/bin/brew" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'brew %s\n' "$*" >>"$AGENT_TOOLS_HOST_TEST_LOG"
EOF
chmod +x "$test_root/bin/brew"

cat >"$test_root/bin/claude-native" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'claude %s\n' "$*" >>"$AGENT_TOOLS_HOST_TEST_LOG"
EOF
chmod +x "$test_root/bin/claude-native"

: >"$AGENT_TOOLS_TEST_LOG"
export AGENT_TOOLS_HOST_TEST_LOG="$test_root/host-commands"
export AGENT_TOOLS_HOST_UPDATES=1
export AGENT_TOOLS_SYSTEM=Darwin
export CODEX_BREW_BIN="$test_root/bin/brew"
export CLAUDE_NATIVE_BIN="$test_root/bin/claude-native"

bash "$script_under_test" --update >/dev/null
grep -q '^brew list --cask codex$' "$AGENT_TOOLS_HOST_TEST_LOG"
grep -q '^brew upgrade --cask codex$' "$AGENT_TOOLS_HOST_TEST_LOG"
grep -q '^claude update$' "$AGENT_TOOLS_HOST_TEST_LOG"
