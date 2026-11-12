{
  config,
  lib,
  pkgs,
  identity,
  inputs,
  ...
}:

let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  homeDirectory = if isDarwin then identity.darwin.homeDirectory else identity.ubuntu.homeDirectory;
  emacsPackage = pkgs.emacs-nox;
  agmsgVersion = lib.removeSuffix "\n" (builtins.readFile "${inputs.agmsg}/VERSION");
  codexDefaultPermissions = ":danger-full-access";
  claudeDefaultPermissionMode = "auto";
  personalGitIdentity =
    let
      name = lib.toLower identity.username;
    in
    lib.hasInfix "yuiga" name && lib.hasInfix "wada" name;
in
{
  home = {
    username = identity.username;
    inherit homeDirectory;
    stateVersion = "26.05";

    packages = with pkgs; [
      act
      agent-tools-updater
      antigravity-cli
      ascii-image-converter
      autossh
      bison
      coreutils
      curl
      direnv
      delve
      docker-client
      docker-compose
      dotcmd
      dotfiles-cli
      dotfiles-cleanup-legacy
      dotfiles-doctor
      emacsPackage
      fd
      file
      findutils
      flyctl
      fzf
      gh
      git
      git-lfs
      git-number
      gnumake
      gnupg
      gnused
      go
      google-cloud-sdk
      gopls
      jq
      just
      lua
      meson
      mosh
      nh
      nixd
      nixfmt-tree
      nkf
      nodejs_22
      pinentry-curses
      pnpm
      pv
      rclone
      ripgrep
      rsync
      rustc
      cargo
      clippy
      rustfmt
      shellcheck
      shfmt
      slackdump
      sqlite
      stress
      testdisk
      texliveSmall
      tmux
      tree
      unzip
      uv
      wasm-pack
      wget
      which
      yuwd-cli
      yq-go
      zip
      zlib
      zsh
      zsh-powerlevel10k
    ];

    sessionVariables = {
      EDITOR = "emacs -nw";
      VISUAL = "emacs -nw";
      GOPATH = "${config.xdg.dataHome}/go";
      LESSCHARSET = "utf-8";
      NODE_ENV = "development";
    };

    sessionPath = [ "${homeDirectory}/.local/state/nix/profiles/agent-tools/bin" ];

    activation.ensureWorkspace = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run mkdir -p "${homeDirectory}/workspace"
    '';

    # Codex and Claude Code use a dedicated mutable Nix profile. This keeps
    # their frequent releases independent from the pinned development tools.
    activation.installAgentTools = lib.hm.dag.entryAfter [ "installPackages" ] ''
      run ${pkgs.agent-tools-updater}/bin/update-agent-tools --bootstrap
    '';

    # agmsg's code is pinned as a Flake input, while its messages, teams, and
    # runtime state remain mutable outside the Nix store. The upstream
    # installer preserves those state directories when updating in place.
    activation.installAgmsg = lib.hm.dag.entryAfter [ "installPackages" ] ''
      run mkdir -p "$HOME/.claude"
      agmsg_path="${
        lib.makeBinPath [
          pkgs.bash
          pkgs.coreutils
          pkgs.findutils
          pkgs.git
          pkgs.gnused
          pkgs.sqlite
        ]
      }:$PATH"

      agmsg_skill_dir="$HOME/.agents/skills/agmsg"
      if [[ -e "$agmsg_skill_dir/.agmsg" ]]; then
        installed_agmsg_version=""
        if [[ -x "$agmsg_skill_dir/scripts/version.sh" ]]; then
          installed_agmsg_version="$(${pkgs.bash}/bin/bash "$agmsg_skill_dir/scripts/version.sh" 2>/dev/null || true)"
        fi

        if [[ "$installed_agmsg_version" == "${agmsgVersion}" ]]; then
          echo "agmsg ${agmsgVersion} is already installed; skipping the in-place updater"
        else
          # Sources copied from /nix/store keep read-only mode bits. Make only
          # the user's installed copy writable before the in-place update.
          run ${pkgs.coreutils}/bin/chmod -R u+w "$agmsg_skill_dir"
          run ${pkgs.coreutils}/bin/env "PATH=$agmsg_path" \
            ${pkgs.bash}/bin/bash ${inputs.agmsg}/install.sh --update --cmd agmsg
        fi
      else
        run ${pkgs.coreutils}/bin/env "PATH=$agmsg_path" \
          ${pkgs.bash}/bin/bash ${inputs.agmsg}/install.sh --cmd agmsg
      fi

      run ${pkgs.coreutils}/bin/chmod -R u+w "$agmsg_skill_dir"

      # The upstream updater renders SKILL.md with shell redirection. If an
      # interrupted update ever leaves it partial, restore the pinned Codex
      # template through an atomic rename before Codex scans the skill again.
      agmsg_skill="$agmsg_skill_dir/SKILL.md"
      if [[ "$(${pkgs.gnused}/bin/sed -n '1p' "$agmsg_skill" 2>/dev/null || true)" != "---" ]] || \
        [[ "$(${pkgs.gnused}/bin/sed -n '2p' "$agmsg_skill" 2>/dev/null || true)" != "name: agmsg" ]] || \
        [[ "$(${pkgs.gnused}/bin/sed -n '4p' "$agmsg_skill" 2>/dev/null || true)" != "---" ]]; then
        agmsg_skill_tmp="$agmsg_skill.home-manager"
        run ${pkgs.coreutils}/bin/rm -f "$agmsg_skill_tmp"
        run ${pkgs.coreutils}/bin/cp ${inputs.agmsg}/scripts/drivers/types/codex/template.md "$agmsg_skill_tmp"
        run ${pkgs.gnused}/bin/sed -i 's/__SKILL_NAME__/agmsg/g' "$agmsg_skill_tmp"
        run ${pkgs.coreutils}/bin/chmod 644 "$agmsg_skill_tmp"
        run ${pkgs.coreutils}/bin/mv -f "$agmsg_skill_tmp" "$agmsg_skill"
      fi
    '';

    # Agent settings contain mutable project trust, MCP, plugin, and permission
    # state. Merge only the declared defaults so activation does not replace
    # those host-local values or put them in the Nix store.
    activation.configureAgentDefaults = lib.hm.dag.entryAfter [ "installAgmsg" ] ''
      backup_dir="$HOME/.local/state/dotfiles-migration/agent-settings-before-nix-20260901"
      run ${pkgs.coreutils}/bin/mkdir -p "$backup_dir" "$HOME/.codex" "$HOME/.claude"
      run ${pkgs.coreutils}/bin/chmod 700 "$backup_dir" "$HOME/.codex" "$HOME/.claude"

      codex_config="$HOME/.codex/config.toml"
      codex_tmp="$codex_config.home-manager-agent-defaults"
      run ${pkgs.coreutils}/bin/rm -f "$codex_tmp"
      if [[ -e "$codex_config" ]]; then
        if [[ ! -e "$backup_dir/codex-config.toml" ]]; then
          run ${pkgs.coreutils}/bin/cp -p "$codex_config" "$backup_dir/codex-config.toml"
        fi
        run ${pkgs.coreutils}/bin/cp -p "$codex_config" "$codex_tmp"
      else
        run ${pkgs.coreutils}/bin/touch "$codex_tmp"
      fi

      # Permission profiles and the older sandbox settings are mutually
      # exclusive. Full access makes agmsg's workspace-only writable root
      # unnecessary, so remove the legacy keys after the agmsg installer runs.
      run ${pkgs.yq-go}/bin/yq -p=toml -o=toml -i '
        .default_permissions = "${codexDefaultPermissions}" |
        del(.sandbox_mode) |
        del(.sandbox_workspace_write)
      ' "$codex_tmp"
      run ${pkgs.coreutils}/bin/chmod 600 "$codex_tmp"
      if [[ ! -e "$codex_config" ]] || ! ${pkgs.diffutils}/bin/cmp -s "$codex_tmp" "$codex_config"; then
        run ${pkgs.coreutils}/bin/mv -f "$codex_tmp" "$codex_config"
      else
        run ${pkgs.coreutils}/bin/rm -f "$codex_tmp"
      fi

      claude_settings="$HOME/.claude/settings.json"
      claude_tmp="$claude_settings.home-manager-agent-defaults"
      run ${pkgs.coreutils}/bin/rm -f "$claude_tmp"
      if [[ -e "$claude_settings" ]]; then
        if [[ ! -e "$backup_dir/claude-settings.json" ]]; then
          run ${pkgs.coreutils}/bin/cp -p "$claude_settings" "$backup_dir/claude-settings.json"
        fi
        run ${pkgs.coreutils}/bin/cp -p "$claude_settings" "$claude_tmp"
      else
        run ${pkgs.coreutils}/bin/touch "$claude_tmp"
      fi

      run ${pkgs.yq-go}/bin/yq -p=json -o=json -i '
        .permissions.defaultMode = "${claudeDefaultPermissionMode}"
      ' "$claude_tmp"
      run ${pkgs.coreutils}/bin/chmod 600 "$claude_tmp"
      if [[ ! -e "$claude_settings" ]] || ! ${pkgs.diffutils}/bin/cmp -s "$claude_tmp" "$claude_settings"; then
        run ${pkgs.coreutils}/bin/mv -f "$claude_tmp" "$claude_settings"
      else
        run ${pkgs.coreutils}/bin/rm -f "$claude_tmp"
      fi
    '';
  };

  xdg.enable = true;

  home.file = {
    ".gitconfig" = {
      text = ''
        ${lib.optionalString personalGitIdentity ''
          [user]
            name = YuigaWada
            email = ${identity.email}
        ''}
        ${builtins.readFile ../../config/git/config}
      '';
      force = true;
    };
    ".p10k.zsh".source = ../../config/p10k/config.zsh;
    ".tmux.conf" = {
      force = true;
      text = ''
        ${builtins.readFile ../../config/tmux/tmux.conf}

        # The Nix profile is the source of zsh on both operating systems.
        set-option -g default-shell "${pkgs.zsh}/bin/zsh"
      '';
    };
  };

  programs.home-manager.enable = true;

  programs.fzf = {
    enable = true;
    enableZshIntegration = false;
  };

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = false;
    syntaxHighlighting.enable = false;

    history = {
      path = "${config.xdg.dataHome}/zsh/history";
      size = 2000;
      save = 1000;
      ignoreDups = false;
      ignoreSpace = false;
      share = false;
      # Timestamps are required for the requested recent-usage audit, but do
      # not alter interactive editing or key bindings.
      extended = true;
    };

    shellAliases = {
      autopep = "autopep8 --recursive --in-place --aggressive --aggressive .";
      cmd = "yuwd";
      e = "emacs -nw";
      emacs = "emacs -nw";
      gccxd = "g++ -std=c++17 -Wall -O2 -g -D_GLIBCXX_DEBUG";
      m = "yuwd";
      pdb = "python -m pdb -c c";
      pip = "pip3";
      python = "python3";
      rm = "rm -i";
      sucp = "rsync -av --progress";
      unico = "sed 's/\\\\u\\(....\\)/\\&#x\\1;/g' | nkf --numchar-input -w";
    };

    initContent = lib.mkOrder 1000 ''
      source ${pkgs.zsh-powerlevel10k}/share/zsh-powerlevel10k/powerlevel10k.zsh-theme
      [[ ! -r "$HOME/.p10k.zsh" ]] || source "$HOME/.p10k.zsh"

      typeset -g DOTFILES_WELCOME_ART=${../../config/zsh/welcome-art.txt}
      ${builtins.readFile ../shell/welcome.zsh}
      ${builtins.readFile ../../config/zsh/tmux.zsh}
      ${builtins.readFile ../shell/init.zsh}
    '';
  };

  news.display = "silent";
}
