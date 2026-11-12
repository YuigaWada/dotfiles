#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: cleanup-mediaanalysisd \
  --expected-product-version VERSION \
  --expected-build-version BUILD \
  --container-path PATH
EOF
}

expected_product_version=""
expected_build_version=""
container_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
  --expected-product-version)
    expected_product_version="${2:-}"
    shift 2
    ;;
  --expected-build-version)
    expected_build_version="${2:-}"
    shift 2
    ;;
  --container-path)
    container_path="${2:-}"
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
  esac
done

if [[ -z "$expected_product_version" || -z "$expected_build_version" || -z "$container_path" ]]; then
  usage >&2
  exit 2
fi

if [[ ! "$expected_product_version" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] ||
  [[ ! "$expected_build_version" =~ ^[0-9A-Za-z]+$ ]]; then
  echo "cleanup-mediaanalysisd: invalid macOS version constraint" >&2
  exit 2
fi

# Keep the destructive target constrained to one user's mediaanalysisd
# container. The launchd configuration supplies the concrete absolute path.
if [[ ! "$container_path" =~ ^/Users/[^/]+/Library/Containers/com[.]apple[.]mediaanalysisd$ ]]; then
  echo "cleanup-mediaanalysisd: refusing unsafe container path: $container_path" >&2
  exit 2
fi

sw_vers_bin="${SW_VERS_BIN:-/usr/bin/sw_vers}"
launchctl_bin="${LAUNCHCTL_BIN:-/bin/launchctl}"
rm_bin="${RM_BIN:-/bin/rm}"

for required_command in "$sw_vers_bin" "$launchctl_bin" "$rm_bin"; do
  if [[ ! -x "$required_command" ]]; then
    echo "cleanup-mediaanalysisd: required command is not executable: $required_command" >&2
    exit 1
  fi
done

product_version="$($sw_vers_bin -productVersion)"
build_version="$($sw_vers_bin -buildVersion)"

if [[ "$product_version" != "$expected_product_version" || "$build_version" != "$expected_build_version" ]]; then
  printf 'cleanup-mediaanalysisd: skipping macOS %s (%s); target is %s (%s)\n' \
    "$product_version" "$build_version" "$expected_product_version" "$expected_build_version"
  exit 0
fi

unload_service() {
  local plist="$1"

  if "$launchctl_bin" unload -w "$plist"; then
    printf 'cleanup-mediaanalysisd: unloaded %s\n' "$plist"
  else
    printf 'cleanup-mediaanalysisd: warning: could not unload %s; continuing\n' "$plist" >&2
  fi
}

unload_service "/System/Library/LaunchAgents/com.apple.mediaanalysisd.plist"
unload_service "/System/Library/LaunchDaemons/com.apple.mediaanalysisd.plist"

"$rm_bin" -rf -- "$container_path"
printf 'cleanup-mediaanalysisd: removed %s\n' "$container_path"
