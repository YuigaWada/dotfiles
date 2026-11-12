#!/usr/bin/env bash
set -euo pipefail

script_argument="${1:?path to cleanup-mediaanalysisd.sh is required}"
script_under_test="$(cd "$(dirname "$script_argument")" && pwd)/$(basename "$script_argument")"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/bin"

cat >"$test_root/bin/sw_vers" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
-productVersion) printf '%s\n' "$MEDIAANALYSISD_TEST_PRODUCT_VERSION" ;;
-buildVersion) printf '%s\n' "$MEDIAANALYSISD_TEST_BUILD_VERSION" ;;
*) exit 2 ;;
esac
EOF

cat >"$test_root/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'launchctl %s\n' "$*" >>"$MEDIAANALYSISD_TEST_LOG"
if [[ "$*" == *"${MEDIAANALYSISD_TEST_LAUNCHCTL_FAILURE:-never-match}"* ]]; then
  exit 1
fi
EOF

cat >"$test_root/bin/rm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'rm %s\n' "$*" >>"$MEDIAANALYSISD_TEST_LOG"
EOF

chmod +x "$test_root/bin/sw_vers" "$test_root/bin/launchctl" "$test_root/bin/rm"

export SW_VERS_BIN="$test_root/bin/sw_vers"
export LAUNCHCTL_BIN="$test_root/bin/launchctl"
export RM_BIN="$test_root/bin/rm"
export MEDIAANALYSISD_TEST_LOG="$test_root/actions"
export MEDIAANALYSISD_TEST_PRODUCT_VERSION="15.3"
export MEDIAANALYSISD_TEST_BUILD_VERSION="24D60"

arguments=(
  --expected-product-version 15.3
  --expected-build-version 24D60
  --container-path /Users/test/Library/Containers/com.apple.mediaanalysisd
)

: >"$MEDIAANALYSISD_TEST_LOG"
MEDIAANALYSISD_TEST_PRODUCT_VERSION="15.4" bash "$script_under_test" "${arguments[@]}" >/dev/null
[[ ! -s "$MEDIAANALYSISD_TEST_LOG" ]]

: >"$MEDIAANALYSISD_TEST_LOG"
MEDIAANALYSISD_TEST_BUILD_VERSION="24D61" bash "$script_under_test" "${arguments[@]}" >/dev/null
[[ ! -s "$MEDIAANALYSISD_TEST_LOG" ]]

if bash "$script_under_test" \
  --expected-product-version 15.3 \
  --expected-build-version 24D60 \
  --container-path /Users/test/Library/Containers/other >/dev/null 2>&1; then
  echo "unsafe container path unexpectedly succeeded" >&2
  exit 1
fi

: >"$MEDIAANALYSISD_TEST_LOG"
export MEDIAANALYSISD_TEST_LAUNCHCTL_FAILURE="LaunchDaemons"
bash "$script_under_test" "${arguments[@]}" >/dev/null 2>&1

grep -Fxq \
  'launchctl unload -w /System/Library/LaunchAgents/com.apple.mediaanalysisd.plist' \
  "$MEDIAANALYSISD_TEST_LOG"
grep -Fxq \
  'launchctl unload -w /System/Library/LaunchDaemons/com.apple.mediaanalysisd.plist' \
  "$MEDIAANALYSISD_TEST_LOG"
grep -Fxq \
  'rm -rf -- /Users/test/Library/Containers/com.apple.mediaanalysisd' \
  "$MEDIAANALYSISD_TEST_LOG"
