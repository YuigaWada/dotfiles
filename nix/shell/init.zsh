# Nix owns package paths. Do not initialise Homebrew, mise, pyenv, nvm, or zplug here.
typeset -g DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.zsh}"

# A shell that predates the Nix migration can retain mise's hook functions
# even after the mise binary has been retired. Remove only mise-owned handlers;
# leave unrelated user-defined hooks intact.
chpwd_functions=("${(@)chpwd_functions:#_mise_hook}")
precmd_functions=("${(@)precmd_functions:#_mise_hook}")
preexec_functions=("${(@)preexec_functions:#_mise_hook}")
(( ${+functions[_mise_hook]} )) && unfunction _mise_hook
if [[ "${functions[command_not_found_handler]-}" == *mise* ]]; then
  unfunction command_not_found_handler
fi

# Prefer the active user and system profiles. On macOS, Home Manager is
# activated by nix-darwin under /etc/profiles/per-user; the old standalone
# Home Manager profile may contain retired window managers.
typeset -ga _dotfiles_clean_path=()
typeset -ga _dotfiles_nix_bins=("$HOME/.local/state/nix/profiles/agent-tools/bin")
if [[ "$OSTYPE" == darwin* ]]; then
  _dotfiles_nix_bins+=("/etc/profiles/per-user/$USER/bin" "/run/current-system/sw/bin")
else
  _dotfiles_nix_bins+=("$HOME/.local/state/nix/profiles/home-manager/home-path/bin")
fi
_dotfiles_nix_bins+=("/nix/var/nix/profiles/default/bin")
for _dotfiles_nix_bin in "${_dotfiles_nix_bins[@]}"; do
  [[ ! -d "$_dotfiles_nix_bin" ]] || _dotfiles_clean_path+=("$_dotfiles_nix_bin")
done
for _dotfiles_inherited_bin in "${path[@]}"; do
  case "$_dotfiles_inherited_bin" in
    "/etc/profiles/per-user/$USER/bin" | "$HOME/.local/state/nix/profiles/home-manager/home-path/bin" | \
      */.local/share/mise/* | */.nvm/* | */.pyenv/* | \
      /opt/homebrew/Cellar/pyenv-virtualenv/*/shims)
      ;;
    *) _dotfiles_clean_path+=("$_dotfiles_inherited_bin") ;;
  esac
done
path=("${_dotfiles_clean_path[@]}")
unset _dotfiles_clean_path _dotfiles_nix_bin _dotfiles_nix_bins _dotfiles_inherited_bin

# Nix-managed commands stay first. Existing tools outside Nix remain available
# as a fallback, so an unmanaged command does not need to be reinstalled.
typeset -ga _dotfiles_fallback_bins=(
  "$HOME/.local/bin"
  "$HOME/go/bin"
  "$HOME/.cabal/bin"
  "$HOME/.ghcup/bin"
  "$HOME/.deta/bin"
  "$HOME/.codeium/windsurf/bin"
  "$HOME/.antigravity/antigravity/bin"
  "$HOME/Downloads/google-cloud-sdk/bin"
  "/Applications/Ghostty.app/Contents/MacOS"
  "/opt/homebrew/bin"
  "/opt/homebrew/sbin"
  "/usr/local/homebrew-x86/bin"
  "/usr/local/homebrew-x86/sbin"
  "/opt/local/bin"
  "/opt/local/sbin"
  "/usr/local/go/bin"
  "/usr/local/texlive/2022/bin/universal-darwin"
  "/Library/TeX/texbin"
)

typeset -U path
for _dotfiles_fallback_bin in "${_dotfiles_fallback_bins[@]}"; do
  [[ ! -d "$_dotfiles_fallback_bin" ]] || path+=("$_dotfiles_fallback_bin")
done
unset _dotfiles_fallback_bin _dotfiles_fallback_bins

if [[ -o interactive ]]; then
  if [[ "$PWD" == "$HOME" && -d "$HOME/workspace" ]]; then
    builtin cd "$HOME/workspace"
  fi
fi
