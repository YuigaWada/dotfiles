{
  config,
  pkgs,
  ...
}:

{
  # The multi-user installer enables the daemon, but does not enable Flakes
  # for an individual non-NixOS user. Keep Flake commands usable without
  # repeating CLI feature flags.
  xdg.configFile."nix/nix.conf" = {
    text = ''
      experimental-features = nix-command flakes
    '';
  };

  targets.genericLinux.enable = true;
  home.sessionPath = [
    "${config.home.homeDirectory}/.local/state/nix/profiles/home-manager/home-path/bin"
    "/nix/var/nix/profiles/default/bin"
  ];
  home.sessionVariables.BROWSER = "google-chrome-stable";

  home.packages = with pkgs; [
    gcc
    ghostty.terminfo
    libnotify
    nvtopPackages.full
    pigz
    tailscale
    xclip
  ];

  systemd.user.services.agent-tools-update = {
    Unit.Description = "Update Codex and Claude Code from nixpkgs";
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.agent-tools-updater}/bin/update-agent-tools";
    };
  };

  systemd.user.timers.agent-tools-update = {
    Unit.Description = "Daily Codex and Claude Code update";
    Timer = {
      OnCalendar = "*-*-* 09:00:00";
      Persistent = true;
      Unit = "agent-tools-update.service";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # Ghostty sends TERM=xterm-ghostty through SSH and Eternal Terminal. Keep a
  # conventional per-user terminfo link as well as the profile entry so cursor
  # movement and line wrapping work even in sessions created before HM exports
  # TERMINFO_DIRS.
  home.file.".terminfo" = {
    source = "${pkgs.ghostty.terminfo}/share/terminfo";
    force = true;
  };

  programs.zsh.shellAliases = {
    copy = "xclip -selection clipboard";
    notif = "notify-send";
    oh = "xdg-open ./";
    open = "xdg-open";
    targz = "tar -I pigz -cf";
  };

  services.gpg-agent = {
    enable = true;
    pinentry.package = pkgs.pinentry-curses;
  };

  # This uses Home Manager's supported non-NixOS GPU integration. Activation
  # prints one sudo command when /run/opengl-driver needs to be provisioned.
  targets.genericLinux.gpu.enable = true;
}
