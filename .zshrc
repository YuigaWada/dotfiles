# Bootstrap fallback. Home Manager owns the active zsh configuration after the
# first successful switch, but keep the existing prompt during activation too.
_dotfiles_hm_zdotdir="$HOME/.config/zsh"
if [[ -r "$_dotfiles_hm_zdotdir/.zshrc" ]]; then
  export ZDOTDIR="$_dotfiles_hm_zdotdir"
  [[ ! -r "$ZDOTDIR/.zshenv" ]] || source "$ZDOTDIR/.zshenv"
  if [[ -o login && -r "$ZDOTDIR/.zprofile" ]]; then
    source "$ZDOTDIR/.zprofile"
  fi
  source "$ZDOTDIR/.zshrc"
  unset _dotfiles_hm_zdotdir
  return
fi
unset _dotfiles_hm_zdotdir

if [[ -r /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
  source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi

if [[ -r "$HOME/.nix-profile/share/zsh-powerlevel10k/powerlevel10k.zsh-theme" ]]; then
  source "$HOME/.nix-profile/share/zsh-powerlevel10k/powerlevel10k.zsh-theme"
  [[ ! -r "$HOME/.p10k.zsh" ]] || source "$HOME/.p10k.zsh"
elif [[ -o interactive ]]; then
  print -P "%F{yellow}[dotfiles] run ~/.zsh/scripts/bootstrap-nix.sh to activate the Nix profile%f"
fi
