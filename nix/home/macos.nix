{
  pkgs,
  config,
  identity,
  lib,
  ...
}:

let
  mediaanalysisdAffectedProductVersion = "15.3";
  mediaanalysisdAffectedBuildVersion = "24D60";
in
{
  home.sessionVariables.BROWSER = "open";

  # Do not expose app bundles that may be carried by transitive CLI
  # dependencies in ~/Applications.
  targets.darwin.linkApps.enable = false;

  home.packages = with pkgs; [
    mediaanalysisd-cleanup
    nowplaying-cli
    switchaudio-osx
  ];

  launchd.agents.agent-tools-update = {
    enable = true;
    config = {
      ProgramArguments = [ "${pkgs.agent-tools-updater}/bin/update-agent-tools" ];
      ProcessType = "Background";
      StartCalendarInterval = [
        {
          Hour = 9;
          Minute = 0;
        }
      ];
      StandardOutPath = "${identity.darwin.homeDirectory}/Library/Logs/agent-tools-update.log";
      StandardErrorPath = "${identity.darwin.homeDirectory}/Library/Logs/agent-tools-update-error.log";
    };
  };

  # macOS 15.3 (24D60) can let mediaanalysisd recreate a very large container.
  # Stop applying the workaround automatically as soon as macOS is updated.
  launchd.agents.mediaanalysisd-cleanup = {
    enable = true;
    config = {
      ProgramArguments = [
        "${pkgs.mediaanalysisd-cleanup}/bin/cleanup-mediaanalysisd"
        "--expected-product-version"
        mediaanalysisdAffectedProductVersion
        "--expected-build-version"
        mediaanalysisdAffectedBuildVersion
        "--container-path"
        "${identity.darwin.homeDirectory}/Library/Containers/com.apple.mediaanalysisd"
      ];
      ProcessType = "Background";
      StartCalendarInterval = [
        {
          Weekday = 0;
          Hour = 4;
          Minute = 0;
        }
      ];
      StandardOutPath = "${identity.darwin.homeDirectory}/Library/Logs/mediaanalysisd-cleanup.log";
      StandardErrorPath = "${identity.darwin.homeDirectory}/Library/Logs/mediaanalysisd-cleanup-error.log";
    };
  };

  home.activation.installYuwaiTabs =
    lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "linkGeneration" ]
      ''
        if [[ ! -v DRY_RUN ]]; then
          ${pkgs.bash}/bin/bash ${../../scripts/install-yuwai-tabs.sh} \
            ${pkgs.yuwai-tabs} ${identity.darwin.homeDirectory}
          /bin/launchctl bootout "gui/$UID/com.yuigawada.yuwai-tabs" 2>/dev/null || true
          /bin/launchctl disable "gui/$UID/com.yuigawada.yuwai-tabs"
          /bin/launchctl kickstart -k "gui/$UID/org.nix-community.home.yuwai-tabs" 2>/dev/null || true
        fi
      '';

  launchd.agents.yuwai-tabs = {
    enable = true;
    config = {
      ProgramArguments = [
        "${identity.darwin.homeDirectory}/Applications/Yuwai Tabs.app/Contents/MacOS/yuwai-tabs"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 10;
      StandardOutPath = "${identity.darwin.homeDirectory}/Library/Logs/yuwai-tabs.log";
      StandardErrorPath = "${identity.darwin.homeDirectory}/Library/Logs/yuwai-tabs.log";
    };
  };

  xdg.configFile."aerospace/aerospace.toml" = {
    force = true;
    source = config.lib.file.mkOutOfStoreSymlink "${identity.darwin.homeDirectory}/.zsh/config/aerospace/aerospace.toml";
  };

  # Ghostty itself remains host-managed, while Home Manager owns the config
  # link at the path used by the macOS application.
  home.file."Library/Application Support/com.mitchellh.ghostty/config" = {
    force = true;
    source = ../../config/ghostty/config;
  };

  programs.zsh.shellAliases = {
    code = "open -a 'Visual Studio Code'";
    copy = "pbcopy";
    mosh = "LC_CTYPE=ja_JP.UTF-8 mosh";
    oh = "open ./";
  };
}
