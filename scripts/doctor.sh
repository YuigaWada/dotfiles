#!/usr/bin/env bash
set -uo pipefail

failures=0
warnings=0

ok() {
  printf 'ok: %s\n' "$*"
}

warn() {
  printf 'warn: %s\n' "$*" >&2
  warnings=$((warnings + 1))
}

fail() {
  printf 'error: %s\n' "$*" >&2
  failures=$((failures + 1))
}

check_command() {
  command_name="$1"
  command_path="$(command -v "$command_name" 2>/dev/null || true)"

  if [[ -z "$command_path" ]]; then
    fail "$command_name is missing"
    return
  fi

  resolved_path="$(readlink -f "$command_path" 2>/dev/null || printf '%s' "$command_path")"
  case "$resolved_path" in
  /nix/store/*)
    ok "$command_name -> $resolved_path"
    ;;
  /opt/homebrew/* | /usr/local/Homebrew/* | /usr/local/homebrew-*/*)
    fail "$command_name still resolves to Homebrew: $resolved_path"
    ;;
  */.local/share/mise/* | */.nvm/* | */.pyenv/* | */node_modules/*)
    fail "$command_name still resolves to a legacy version manager: $resolved_path"
    ;;
  *)
    warn "$command_name is outside the Nix store: $resolved_path"
    ;;
  esac
}

check_unmanaged_command() {
  command_name="$1"
  command_path="$(command -v "$command_name" 2>/dev/null || true)"

  if [[ -z "$command_path" ]]; then
    fail "$command_name is missing (an existing unmanaged installation is expected)"
    return
  fi

  resolved_path="$(readlink -f "$command_path" 2>/dev/null || printf '%s' "$command_path")"
  ok "$command_name is available outside Nix management: $resolved_path"
}

printf 'dotfiles doctor (%s/%s)\n' "$(uname -s)" "$(uname -m)"

agent_tools_profile="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/agent-tools"
if [[ -x "$agent_tools_profile/bin/codex" && -x "$agent_tools_profile/bin/claude" ]]; then
  ok "Codex and Claude Code are installed in the auto-update profile"
else
  fail "agent auto-update profile is incomplete: $agent_tools_profile"
fi

for command_name in \
  nix git zsh tmux jq rg fd fzf direnv just yuwd \
  node pnpm uv go gopls dlv cargo wasm-pack codex claude agy; do
  check_command "$command_name"
done

check_unmanaged_command python3

if command -v codex >/dev/null 2>&1; then
  codex --version || warn "codex could not print its version"
fi

if command -v claude >/dev/null 2>&1; then
  claude --version || warn "claude could not print its version"
fi

if [[ -f "$HOME/.codex/config.toml" ]]; then
  codex_default_permissions="$(yq -p=toml -r '.default_permissions // ""' "$HOME/.codex/config.toml" 2>/dev/null || true)"
  if [[ "$codex_default_permissions" == ":danger-full-access" ]]; then
    ok "Codex default permissions are full access"
  else
    fail "Codex default permissions are not full access"
  fi

  if yq -p=toml -e 'has("sandbox_mode") or has("sandbox_workspace_write")' \
    "$HOME/.codex/config.toml" >/dev/null 2>&1; then
    fail "Codex config still contains legacy sandbox settings that override permission profiles"
  else
    ok "Codex permission profile has no conflicting legacy sandbox settings"
  fi
else
  fail "Codex config is missing: $HOME/.codex/config.toml"
fi

if [[ -f "$HOME/.claude/settings.json" ]]; then
  claude_default_mode="$(jq -r '.permissions.defaultMode // ""' "$HOME/.claude/settings.json" 2>/dev/null || true)"
  if [[ "$claude_default_mode" == "auto" ]]; then
    ok "Claude Code default permission mode is auto"
  else
    fail "Claude Code default permission mode is not auto"
  fi
else
  fail "Claude Code settings are missing: $HOME/.claude/settings.json"
fi

if [[ -x "$HOME/.agents/skills/agmsg/scripts/version.sh" ]]; then
  agmsg_version="$(bash "$HOME/.agents/skills/agmsg/scripts/version.sh" 2>/dev/null || true)"
  if [[ -n "$agmsg_version" ]]; then
    ok "agmsg is installed: $agmsg_version"
  else
    fail "agmsg is installed but could not print its version"
  fi
else
  fail "agmsg is missing"
fi

agmsg_skill="$HOME/.agents/skills/agmsg/SKILL.md"
if [[ "$(sed -n '1p' "$agmsg_skill" 2>/dev/null || true)" == "---" ]] &&
  [[ "$(sed -n '2p' "$agmsg_skill" 2>/dev/null || true)" == "name: agmsg" ]] &&
  [[ "$(sed -n '4p' "$agmsg_skill" 2>/dev/null || true)" == "---" ]]; then
  ok "agmsg SKILL.md has valid YAML frontmatter"
else
  fail "agmsg SKILL.md is missing valid YAML frontmatter"
fi

homebrew_found=false
for brew_path in \
  /opt/homebrew/bin/brew \
  /usr/local/homebrew-x86/bin/brew \
  /usr/local/Homebrew/bin/brew \
  /usr/local/bin/brew; do
  if [[ -x "$brew_path" ]]; then
    ok "Homebrew remains for host-managed GUI applications: $brew_path"
    homebrew_found=true
  fi
done
[[ "$homebrew_found" == true ]] || ok "Homebrew is absent (GUI applications are host-managed another way)"

for legacy_path in \
  "$HOME/.local/share/mise" \
  "$HOME/.config/mise" \
  "$HOME/.nvm" \
  "$HOME/.pyenv" \
  "$HOME/.zplug" \
  "$HOME/powerlevel10k" \
  "$HOME/.cargo/bin" \
  "$HOME/.rustup" \
  "$HOME/.local/bin/mise" \
  "$HOME/.local/bin/uv" \
  "$HOME/.local/bin/uvx"; do
  if [[ -e "$legacy_path" ]]; then
    warn "legacy path remains: $legacy_path"
  fi
done

case "$(uname -s)" in
Darwin)
  if /sbin/mount | /usr/bin/grep -q ' on /nix '; then
    ok "Nix Store is mounted at /nix"
  else
    fail "Nix Store is not mounted at /nix"
  fi

  if /usr/bin/grep -qx 'nix' /etc/synthetic.conf 2>/dev/null; then
    ok "/etc/synthetic.conf declares the /nix mount point"
  else
    fail "/etc/synthetic.conf is missing the literal nix entry"
  fi

  if /usr/bin/grep -Eq '^[^#]*[[:space:]]/nix[[:space:]]+apfs[[:space:]]+rw' /etc/fstab 2>/dev/null; then
    ok "/etc/fstab declares Nix Store mount options"
  else
    fail "/etc/fstab is missing the /nix APFS entry"
  fi

  if [[ -f /Library/LaunchDaemons/org.nixos.darwin-store.plist ]] &&
    [[ "$(/usr/bin/plutil -extract Label raw -o - /Library/LaunchDaemons/org.nixos.darwin-store.plist 2>/dev/null || true)" == "org.nixos.darwin-store" ]]; then
    ok "Nix Store boot-time mount daemon is installed"
  else
    fail "Nix Store boot-time mount daemon is missing or invalid"
  fi

  if launchctl print "gui/$UID/org.nix-community.home.agent-tools-update" >/dev/null 2>&1; then
    ok "daily agent-tools update LaunchAgent is loaded"
  else
    fail "daily agent-tools update LaunchAgent is not loaded"
  fi

  ghostty_config="$HOME/Library/Application Support/com.mitchellh.ghostty/config"
  ghostty_config_target="$(readlink -f "$ghostty_config" 2>/dev/null || true)"
  if [[ -L "$ghostty_config" && "$ghostty_config_target" == /nix/store/* ]]; then
    ok "Ghostty config is managed by Home Manager: $ghostty_config_target"
  else
    fail "Ghostty config is not managed by Home Manager: $ghostty_config"
  fi

  check_command aerospace
  check_command yuwai-tabs

  aerospace_config="$HOME/.config/aerospace/aerospace.toml"
  if [[ -L "$aerospace_config" && "$(readlink -f "$aerospace_config" 2>/dev/null || true)" == "$HOME/.zsh/config/aerospace/aerospace.toml" ]]; then
    ok "AeroSpace config links to ~/.zsh"
  else
    fail "AeroSpace config is not linked to ~/.zsh: $aerospace_config"
  fi

  service_details="$(launchctl print "gui/$UID/org.nixos.aerospace" 2>/dev/null || true)"
  service_command="$(/usr/bin/plutil -extract ProgramArguments.2 raw -o - "$HOME/Library/LaunchAgents/org.nixos.aerospace.plist" 2>/dev/null || true)"
  if [[ "$service_command" != *"/nix/store/"*"/Applications/AeroSpace.app/Contents/MacOS/AeroSpace --config-path $aerospace_config" ]]; then
    fail "AeroSpace launchd service is not configured to use Nix and ~/.zsh"
  elif ! printf '%s\n' "$service_details" | grep -q '^[[:space:]]*state = running$'; then
    fail "AeroSpace launchd service is not running"
  else
    ok "AeroSpace launchd service is running from Nix"
  fi

  tabs_app="$HOME/Applications/Yuwai Tabs.app"
  tabs_service="$(launchctl print "gui/$UID/org.nix-community.home.yuwai-tabs" 2>/dev/null || true)"
  tabs_program="$(/usr/bin/plutil -extract ProgramArguments.2 raw -o - "$HOME/Library/LaunchAgents/org.nix-community.home.yuwai-tabs.plist" 2>/dev/null || true)"
  if [[ "$tabs_program" != *"$tabs_app/Contents/MacOS/yuwai-tabs"* ]] || ! /usr/bin/codesign --verify "$tabs_app" >/dev/null 2>&1; then
    fail "Yuwai Tabs app is not installed and signed by Home Manager"
  elif ! printf '%s\n' "$tabs_service" | grep -q '^[[:space:]]*state = running$'; then
    fail "Yuwai Tabs LaunchAgent is not running"
  else
    ok "Nix-built Yuwai Tabs app and LaunchAgent are running"
  fi

  if launchctl print "gui/$UID/com.yuigawada.yuwai-tabs" >/dev/null 2>&1; then
    fail "old standalone Yuwai Tabs LaunchAgent is still loaded"
  else
    ok "old standalone Yuwai Tabs LaunchAgent is stopped"
  fi

  for retired_service in yabai skhd; do
    if launchctl print "gui/$UID/org.nixos.$retired_service" >/dev/null 2>&1; then
      fail "retired $retired_service LaunchAgent is still loaded"
    else
      ok "retired $retired_service LaunchAgent is absent"
    fi
  done

  if launchctl print system/com.tailscale.tailscaled >/dev/null 2>&1; then
    ok "tailscaled is loaded"
  else
    warn "tailscaled is not loaded"
  fi
  ;;
Linux)
  if systemctl --user is-enabled agent-tools-update.timer >/dev/null 2>&1; then
    ok "daily agent-tools update timer is enabled"
  else
    fail "daily agent-tools update timer is not enabled"
  fi

  if infocmp xterm-ghostty >/dev/null 2>&1; then
    ok "xterm-ghostty terminfo is available for remote Ghostty sessions"
  else
    fail "xterm-ghostty terminfo is missing"
  fi

  if [[ -e /run/opengl-driver ]]; then
    ok "non-NixOS GPU bridge exists"
  else
    warn "/run/opengl-driver is missing; run the setup command printed by Home Manager"
  fi
  ;;
esac

printf 'doctor result: %d error(s), %d warning(s)\n' "$failures" "$warnings"
[[ "$failures" -eq 0 ]]
