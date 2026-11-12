#!/bin/bash
set -euo pipefail

assume_yes=false

usage() {
  cat <<EOF
usage: $0 [--yes]

Restore the macOS boot artifacts that mount an existing Nix Store at /nix.
The script preserves unrelated synthetic.conf and fstab entries and does not
reinstall Nix or modify the store volume.

  --yes  Apply the displayed changes without an interactive confirmation.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --yes) assume_yes=true ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
  esac
  shift
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This repair is only for macOS." >&2
  exit 1
fi

if [[ "$(id -u)" -eq 0 ]]; then
  echo "Run this script as your normal user; it invokes sudo only where required." >&2
  exit 1
fi

dotfiles_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
volume_ref=""

for candidate in /nix "/Volumes/Nix Store" "Nix Store"; do
  if /usr/sbin/diskutil info "$candidate" >/dev/null 2>&1; then
    volume_ref="$candidate"
    break
  fi
done

if [[ -z "$volume_ref" ]]; then
  echo "The existing APFS volume named 'Nix Store' was not found; refusing to create or delete a volume." >&2
  exit 1
fi

volume_info="$(/usr/sbin/diskutil info -plist "$volume_ref")"
volume_device="$(printf '%s' "$volume_info" | /usr/bin/plutil -extract DeviceIdentifier raw -o - -)"
volume_uuid="$(printf '%s' "$volume_info" | /usr/bin/plutil -extract VolumeUUID raw -o - -)"
volume_name="$(printf '%s' "$volume_info" | /usr/bin/plutil -extract VolumeName raw -o - -)"

if [[ "$volume_name" != "Nix Store" ]]; then
  echo "Resolved volume has the unexpected name '$volume_name'; refusing to continue." >&2
  exit 1
fi

case "$volume_uuid" in
????????-????-????-????-????????????) ;;
*)
  echo "Resolved volume has an invalid UUID: $volume_uuid" >&2
  exit 1
  ;;
esac

mount_type="unencrypted"
if /usr/sbin/diskutil apfs listCryptoUsers -plist "$volume_device" |
  /usr/bin/grep -q APFSCryptoUserUUID; then
  mount_type="encrypted"
  if ! /usr/bin/security find-generic-password -s "$volume_uuid" \
    /Library/Keychains/System.keychain >/dev/null 2>&1; then
    cat >&2 <<EOF
The Nix Store is encrypted, but its unlock credential was not found in the
System keychain (service: $volume_uuid). Nothing was changed.
EOF
    exit 1
  fi
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/repair-nix-volume.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

synthetic_source=/etc/synthetic.conf
synthetic_next="$scratch/synthetic.conf"
if [[ -f "$synthetic_source" ]]; then
  /usr/bin/awk '
    $1 == "nix" || $1 == "run" { next }
    { print }
    END {
      print "nix"
      print "run\tprivate/var/run"
    }
  ' "$synthetic_source" >"$synthetic_next"
else
  printf 'nix\nrun\tprivate/var/run\n' >"$synthetic_next"
fi

fstab_source=/etc/fstab
fstab_next="$scratch/fstab"
if [[ -f "$fstab_source" ]]; then
  /usr/bin/awk '
    $1 !~ /^#/ && $2 == "/nix" { next }
    { print }
  ' "$fstab_source" >"$fstab_next"
else
  : >"$fstab_next"
fi
printf 'UUID=%s /nix apfs rw,noauto,nobrowse,nosuid,noatime,owners\n' \
  "$volume_uuid" >>"$fstab_next"

mount_daemon=/Library/LaunchDaemons/org.nixos.darwin-store.plist
mount_daemon_next="$scratch/org.nixos.darwin-store.plist"

if [[ "$mount_type" == "encrypted" ]]; then
  mount_command="/usr/bin/security find-generic-password -s '$volume_uuid' -w | /usr/sbin/diskutil apfs unlockVolume '$volume_uuid' -mountpoint '/nix' -stdinpassphrase"
  cat >"$mount_daemon_next" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>RunAtLoad</key>
  <true/>
  <key>Label</key>
  <string>org.nixos.darwin-store</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>$mount_command</string>
  </array>
</dict>
</plist>
EOF
else
  cat >"$mount_daemon_next" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>RunAtLoad</key>
  <true/>
  <key>Label</key>
  <string>org.nixos.darwin-store</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/sbin/diskutil</string>
    <string>mount</string>
    <string>-mountPoint</string>
    <string>/nix</string>
    <string>$volume_uuid</string>
  </array>
</dict>
</plist>
EOF
fi

/usr/bin/plutil -lint "$mount_daemon_next" >/dev/null

printf 'Existing Nix Store found:\n'
printf '  device:     %s\n' "$volume_device"
printf '  UUID:       %s\n' "$volume_uuid"
printf '  encryption: %s\n' "$mount_type"
printf '\nThe following boot artifacts will be restored:\n'
printf '  /etc/synthetic.conf             (/nix and /run mappings)\n'
printf '  /etc/fstab                      (Nix Store mount options)\n'
printf '  %s  (boot-time unlock/mount)\n' "$mount_daemon"
printf 'The Nix Store itself will not be modified. A reboot is required afterward.\n'

if [[ "$assume_yes" != true ]]; then
  if [[ ! -t 0 ]]; then
    echo "Cannot confirm without a terminal; re-run with --yes." >&2
    exit 2
  fi
  read -r -p "Apply this repair? [y/N] " reply
  case "${reply:-n}" in
  y | Y | yes | YES) ;;
  *)
    echo "Aborted without making changes."
    exit 1
    ;;
  esac
fi

backup_dir="$HOME/.local/state/dotfiles-migration/nix-volume-repair-$(date +%Y%m%d-%H%M%S)"
/bin/mkdir -p "$backup_dir"

backup_file() {
  source_path="$1"
  backup_name="$2"
  if [[ -e "$source_path" || -L "$source_path" ]]; then
    /bin/cp -pP "$source_path" "$backup_dir/$backup_name"
  else
    /usr/bin/touch "$backup_dir/$backup_name.was-absent"
  fi
}

backup_file "$synthetic_source" synthetic.conf
backup_file "$fstab_source" fstab
backup_file "$mount_daemon" org.nixos.darwin-store.plist
backup_file "$HOME/.zshrc" home.zshrc

sudo -v
sudo /usr/bin/install -o root -g wheel -m 0644 "$synthetic_next" "$synthetic_source"
sudo /usr/bin/install -o root -g wheel -m 0644 "$fstab_next" "$fstab_source"
sudo /usr/bin/install -o root -g wheel -m 0644 "$mount_daemon_next" "$mount_daemon"

# Keep a real, non-store bootstrap file so zsh can explain or recover from a
# missing /nix mount instead of following a dangling Home Manager symlink.
/usr/bin/install -m 0644 "$dotfiles_dir/.zshrc" "$HOME/.zshrc"

printf '\nRepair installed. Backups: %s\n' "$backup_dir"
printf 'Reboot macOS now, then run: yuwd switch && yuwd doctor\n'
