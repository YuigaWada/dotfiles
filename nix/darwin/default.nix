{
  inputs,
  self,
  identity,
  lib,
  pkgs,
  ...
}:

let
  username = identity.username;
  homeDirectory = identity.darwin.homeDirectory;
  loadYabaiScriptingAddition = pkgs.writeShellScript "load-yabai-scripting-addition" ''
    set -eu

    # The Dock starts after the system LaunchDaemons. Retry until the user
    # session exists, and reload only if this Dock has no SA payload mapped.
    username=${lib.escapeShellArg username}
    dock_pid="$(/usr/bin/pgrep -u "$username" -x Dock | /usr/bin/head -n 1 || true)"
    if [ -z "$dock_pid" ]; then
      exit 0
    fi
    if /usr/sbin/lsof -p "$dock_pid" 2>/dev/null |
      /usr/bin/grep -Fq '/Library/ScriptingAdditions/yabai.osax/Contents/Resources/payload.bundle/Contents/MacOS/payload'; then
      exit 0
    fi

    export SUDO_UID="$(/usr/bin/id -u "$username")"
    exec ${pkgs.yabai}/bin/yabai --load-sa
  '';
in
{
  nixpkgs.hostPlatform = identity.darwin.system;

  system = {
    primaryUser = username;
    stateVersion = 6;
    configurationRevision = self.rev or self.dirtyRev or null;

    # These two files must remain real files on the writable system volume:
    # macOS reads synthetic.conf before /nix exists, and diskutil reads fstab
    # for the APFS mount options. The official installer creates them once;
    # keep the required entries intact on every later nix-darwin activation.
    activationScripts.nixStoreBootArtifacts.text = ''
      nix_volume_info="$(/usr/sbin/diskutil info -plist /nix)"
      nix_volume_uuid="$(printf '%s' "$nix_volume_info" | /usr/bin/plutil -extract VolumeUUID raw -o - -)"

      if ! /usr/bin/grep -qx 'nix' /etc/synthetic.conf 2>/dev/null || \
        ! /usr/bin/grep -Eq '^run[[:space:]]+private/var/run$' /etc/synthetic.conf 2>/dev/null; then
        synthetic_tmp="$(/usr/bin/mktemp /tmp/nix-darwin-synthetic.XXXXXX)"
        if [[ -f /etc/synthetic.conf ]]; then
          /usr/bin/awk '
            $1 == "nix" || $1 == "run" { next }
            { print }
            END {
              print "nix"
              print "run\tprivate/var/run"
            }
          ' /etc/synthetic.conf >"$synthetic_tmp"
        else
          printf 'nix\nrun\tprivate/var/run\n' >"$synthetic_tmp"
        fi
        /usr/bin/install -o root -g wheel -m 0644 "$synthetic_tmp" /etc/synthetic.conf
        /bin/rm "$synthetic_tmp"
      fi

      if ! /usr/bin/grep -Eq "^UUID=$nix_volume_uuid[[:space:]]+/nix[[:space:]]+apfs[[:space:]]+rw" /etc/fstab 2>/dev/null; then
        fstab_tmp="$(/usr/bin/mktemp /tmp/nix-darwin-fstab.XXXXXX)"
        if [[ -f /etc/fstab ]]; then
          /usr/bin/awk '
            $1 !~ /^#/ && $2 == "/nix" { next }
            { print }
          ' /etc/fstab >"$fstab_tmp"
        fi
        printf 'UUID=%s /nix apfs rw,noauto,nobrowse,nosuid,noatime,owners\n' \
          "$nix_volume_uuid" >>"$fstab_tmp"
        /usr/bin/install -o root -g wheel -m 0644 "$fstab_tmp" /etc/fstab
        /bin/rm "$fstab_tmp"
      fi
    '';
  };

  users.users.${username} = {
    name = username;
    home = homeDirectory;
  };

  nix = {
    registry.nixpkgs.flake = inputs.nixpkgs;
    channel.enable = false;
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      auto-optimise-store = true;
      trusted-users = [
        "root"
        username
      ];
    };
    gc = {
      automatic = true;
      interval = {
        Weekday = 0;
        Hour = 3;
        Minute = 0;
      };
      options = "--delete-older-than 30d";
    };
  };

  programs.zsh.enable = true;
  environment.pathsToLink = [ "/share/zsh" ];

  # Keep macOS tiling and Space reordering from interfering with AeroSpace.
  system.defaults = {
    dock.mru-spaces = false;
    spaces.spans-displays = false;
    WindowManager = {
      GloballyEnabled = false;
      EnableStandardClickToShowDesktop = false;
      EnableTilingByEdgeDrag = false;
      EnableTopTilingByEdgeDrag = false;
      EnableTilingOptionAccelerator = false;
    };
  };

  services.aerospace.enable = true;
  # The service and binary come from Nix; the mutable configuration remains
  # in this repository and is linked into ~/.config by Home Manager.
  launchd.user.agents.aerospace.command =
    lib.mkForce "${pkgs.aerospace}/Applications/AeroSpace.app/Contents/MacOS/AeroSpace --config-path ${homeDirectory}/.config/aerospace/aerospace.toml";

  environment.systemPackages = [
    pkgs.yuwai-tabs
    pkgs.aerospace-actions
  ];

  services.tailscale.enable = true;

  # Only load yabai's Dock scripting addition. Do not start the yabai window
  # manager; native macOS Space shortcuts and gestures remain the controls.
  launchd.daemons.yabai-scripting-addition.serviceConfig = {
    Label = "org.nixos.yabai-scripting-addition";
    ProgramArguments = [ "${loadYabaiScriptingAddition}" ];
    RunAtLoad = true;
    StartInterval = 30;
  };

  # This plist is copied into /Library/LaunchDaemons as a real file, so it is
  # available before /nix is mounted. fstab is a real host file containing the
  # per-machine UUID, so the daemon does not depend on discovering a locked
  # volume by label. Both encrypted and unencrypted installs are supported.
  launchd.daemons.darwin-store.serviceConfig = {
    Label = "org.nixos.darwin-store";
    ProgramArguments = [
      "/bin/sh"
      "-c"
      ''
        if /sbin/mount | /usr/bin/grep -q ' on /nix '; then
          exit 0
        fi
        volume_uuid="$(/usr/bin/awk '$1 !~ /^#/ && $2 == "/nix" && $1 ~ /^UUID=/ { sub(/^UUID=/, "", $1); print $1; exit }' /etc/fstab)"
        [ -n "$volume_uuid" ] || exit 1
        if /usr/sbin/diskutil apfs listCryptoUsers -plist "$volume_uuid" | /usr/bin/grep -q APFSCryptoUserUUID; then
          /usr/bin/security find-generic-password -s "$volume_uuid" -w | /usr/sbin/diskutil apfs unlockVolume "$volume_uuid" -mountpoint /nix -stdinpassphrase
        else
          /usr/sbin/diskutil mount -mountPoint /nix "$volume_uuid"
        fi
      ''
    ];
    RunAtLoad = true;
  };
}
