#!/bin/bash
set -euo pipefail

action="${1:-}"
aerospace=/run/current-system/sw/bin/aerospace
case "$action" in
workspace-layout)
  case "${AEROSPACE_FOCUSED_WORKSPACE:-}" in
  2)
    "$aerospace" layout --workspace 2 --root h_tiles
    ;;
  3)
    "$aerospace" layout --workspace 3 --root v_tiles
    ;;
  9) "$aerospace" layout --workspace 9 --root h_accordion ;;
  4)
    ids=()
    vertical_count=0
    horizontal_count=0
    app_tabs=0
    window_rows="$("$aerospace" list-windows --workspace 4 --format '%{window-id} %{window-parent-container-layout}')"
    while read -r id parent; do
      [[ -n "$id" && "$parent" != floating ]] || continue
      ids+=("$id")
      case "$parent" in
      v_tiles) ((vertical_count += 1)) ;;
      h_tiles) ((horizontal_count += 1)) ;;
      *_accordion) ((app_tabs += 1)) ;;
      esac
    done <<<"$window_rows"
    # The tab companion owns nested app groups; flattening would ungroup them.
    if ((app_tabs > 0)); then
      exit 0
    fi
    "$aerospace" layout --workspace 4 --root h_tiles
    # Two vertical columns, each with two windows. Preserve an existing grid.
    if ((${#ids[@]} >= 4 && vertical_count >= 4)) ||
      ((${#ids[@]} == 3 && vertical_count == 2 && horizontal_count == 1)); then
      exit 0
    fi
    if ((${#ids[@]} >= 3)); then
      "$aerospace" flatten-workspace-tree --workspace 4
      "$aerospace" join-with --window-id "${ids[0]}" right
      if ((${#ids[@]} >= 4)); then
        "$aerospace" join-with --window-id "${ids[2]}" right
      fi
    fi
    ;;
  esac
  ;;
focus-running)
  bundle_id="${2:?bundle ID required}"
  app_name="${3:?app name required}"
  if [[ -n "$(/usr/bin/lsappinfo find "bundleid=$bundle_id")" ]]; then
    /usr/bin/open -a "$app_name"
  fi
  ;;
save-app)
  bundle_id="$("$aerospace" list-windows --focused --format '%{app-bundle-id}')"
  [[ -n "$bundle_id" ]] || exit 1
  /bin/mkdir -p "$HOME/.cache"
  /usr/bin/printf 'bundle:%s\n' "$bundle_id" >"$HOME/.cache/aerospace_open_app"
  ;;
recall-app)
  [[ -r "$HOME/.cache/aerospace_open_app" ]] || exit 0
  IFS= read -r saved <"$HOME/.cache/aerospace_open_app"
  if [[ "$saved" == bundle:* ]]; then
    bundle_id="${saved#bundle:}"
  else
    bundle_id=""
    while IFS=$'\t' read -r app_name app_bundle_id; do
      if [[ "$app_name" == "$saved" ]]; then
        bundle_id="$app_bundle_id"
        break
      fi
    done < <("$aerospace" list-windows --all --format '%{app-name}%{tab}%{app-bundle-id}')
  fi
  if [[ -n "$bundle_id" && -n "$(/usr/bin/lsappinfo find "bundleid=$bundle_id")" ]]; then
    /usr/bin/open -b "$bundle_id"
  fi
  ;;
*)
  exit 2
  ;;
esac
