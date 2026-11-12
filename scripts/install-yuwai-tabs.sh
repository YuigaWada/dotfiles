#!/bin/sh
set -eu

package=$1
home=$2
app="$home/Applications/Yuwai Tabs.app"
source_app="$package/share/yuwai-tabs/Yuwai Tabs.app"
state="$home/.local/state/yuwai-tabs"
marker="$state/package-path"

if [ -r "$marker" ] && [ "$(cat "$marker")" = "$package" ] &&
  /usr/bin/codesign --verify "$app" >/dev/null 2>&1; then
  exit 0
fi

identity=$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null |
  /usr/bin/sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' |
  /usr/bin/head -n 1)
if [ -z "$identity" ]; then
  identity=-
  echo 'Yuwai Tabs: using ad-hoc signing; Accessibility permission may need renewal after updates' >&2
fi

/bin/mkdir -p "$home/Applications" "$state"
if [ -d "$app" ]; then
  /bin/chmod -R u+w "$app"
fi
/usr/bin/ditto "$source_app" "$app"
/bin/chmod -R u+w "$app"
/usr/bin/codesign --force --sign "$identity" --timestamp=none "$app"
/usr/bin/codesign --verify "$app"
/usr/bin/printf '%s\n' "$package" >"$marker"
