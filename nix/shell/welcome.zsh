# Preserve the original terminal artwork without bringing back the legacy
# recursive .zshrc or package-manager initialisation.
_dotfiles_render_welcome() {
  emulate -L zsh

  local art_file="${DOTFILES_WELCOME_ART:-}"
  [[ -o interactive && -t 1 && "$TERM" != dumb && -r "$art_file" ]] || return 0

  local -a art_lines messages
  art_lines=("${(@f)$(<"$art_file")}")
  messages=(
    $'\e[1;32m+-------------------------------------+\e[0m'
    $'\e[1;32m[Terminal] Welcome to yuwd\047s terminal.\e[0m'
    $'\e[1;32m[dotfiles] checking ...\e[0m'
  )

  if [[ -d "$DOTFILES_DIR/.git" ]] && ! git -C "$DOTFILES_DIR" diff --quiet --ignore-submodules -- 2>/dev/null; then
    messages+=(
      $'\e[1;33m[warn] DIRTY DOTFILES\e[0m'
      $'\e[1;33m    -> Commit the tracked changes in ~/.zsh\e[0m'
    )
  else
    messages+=($'\e[1;32m[dotfiles] ok\e[0m')
  fi

  messages+=(
    $'\e[1;32m[dotfiles] done\e[0m'
    $'\e[1;32m+-------------------------------------+\e[0m'
  )

  integer middle=$(((${#art_lines} - ${#messages}) / 2 + 1))
  ((middle < 1)) && middle=1

  # Match the legacy startup screen: move home and clear everything below it.
  print -n -- $'\e[H\e[J'

  integer index=1 message_index
  local line
  for line in "${art_lines[@]}"; do
    message_index=$((index - middle + 1))
    if ((message_index >= 1 && message_index <= ${#messages})); then
      print -r -- "$line ${messages[message_index]}"
    else
      print -r -- "$line"
    fi
    ((index++))
  done
}

_dotfiles_render_welcome
unfunction _dotfiles_render_welcome
unset DOTFILES_WELCOME_ART
