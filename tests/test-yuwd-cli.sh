#!/usr/bin/env bash
set -euo pipefail

script_argument="${1:?path to yuwd.sh is required}"
script_under_test="$(cd "$(dirname "$script_argument")" && pwd)/$(basename "$script_argument")"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/bin" "$test_root/repository" "$test_root/work"
touch "$test_root/repository/justfile"

# shellcheck disable=SC2016 # Expanded when the generated fixture runs.
printf '#!%s\nprintf "%%s\\n" "$@" >"$YUWD_TEST_LOG"\n' "$BASH" >"$test_root/bin/just"
chmod +x "$test_root/bin/just"

export DOTFILES_DIR="$test_root/repository"
export PATH="$test_root/bin:$PATH"
export YUWD_TEST_LOG="$test_root/arguments"

cd "$test_root/work"
bash "$script_under_test" switch
expected_switch=$(printf '%s\n' \
  --justfile "$test_root/repository/justfile" \
  --working-directory "$test_root/repository" switch)
[[ "$(cat "$YUWD_TEST_LOG")" == "$expected_switch" ]]

bash "$script_under_test" restart aerospace
[[ "$(tail -n 1 "$YUWD_TEST_LOG")" == "restart-aerospace" ]]

bash "$script_under_test" start aerospace
[[ "$(tail -n 1 "$YUWD_TEST_LOG")" == "start-aerospace" ]]

bash "$script_under_test" start
[[ "$(tail -n 1 "$YUWD_TEST_LOG")" == "start-aerospace" ]]

bash "$script_under_test" stop aerospace
[[ "$(tail -n 1 "$YUWD_TEST_LOG")" == "stop-aerospace" ]]

bash "$script_under_test" stop
[[ "$(tail -n 1 "$YUWD_TEST_LOG")" == "stop-aerospace" ]]

bash "$script_under_test" restart
[[ "$(tail -n 1 "$YUWD_TEST_LOG")" == "restart-aerospace" ]]

bash "$script_under_test" repair nix
[[ "$(tail -n 1 "$YUWD_TEST_LOG")" == "repair-nix-volume" ]]

if bash "$script_under_test" restart invalid >/dev/null 2>&1; then
  echo "invalid restart target unexpectedly succeeded" >&2
  exit 1
fi

if bash "$script_under_test" start invalid >/dev/null 2>&1; then
  echo "invalid start target unexpectedly succeeded" >&2
  exit 1
fi

if bash "$script_under_test" stop invalid >/dev/null 2>&1; then
  echo "invalid stop target unexpectedly succeeded" >&2
  exit 1
fi
