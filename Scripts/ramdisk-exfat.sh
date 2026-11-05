#!/bin/zsh
#
# ramdisk-exfat.sh - create, inspect and remove a small ExFAT RAM disk.
#
# The RAM disk uses the same FSKit path as a USB drive, but no real hardware.
# The script records the device node it created in a state file and removes
# only that device. It refuses any device that does not look virtual.
#
# Usage:
#   ramdisk-exfat.sh create [size_mb] [name]
#   ramdisk-exfat.sh remove
#   ramdisk-exfat.sh status

set -euo pipefail

state_root="${TMPDIR:-/tmp}"
state_root="${state_root%/}"
state_file="${state_root}/usbverify-ramdisk.state"

usage() {
  print -r -- "Usage:"
  print -r -- "  ramdisk-exfat.sh create [size_mb] [name]"
  print -r -- "  ramdisk-exfat.sh remove"
  print -r -- "  ramdisk-exfat.sh status"
}

die() {
  print -u2 -r -- "ramdisk-exfat: $*"
  exit 1
}

# Device node used by the interrupt cleanup.
created_device=""

create_abort() {
  print -u2 -r -- "ramdisk-exfat: $1"
  if [[ -n ${created_device:-} ]]; then
    hdiutil detach "$created_device" >/dev/null 2>&1 || true
    created_device=""
  fi
  # create refuses to start when a state file exists, so any file here is ours.
  if [[ -f $state_file ]]; then
    rm -f -- "$state_file"
  fi
  exit 1
}

create_disk() {
  local size_mb="${1:-512}"
  local name="${2:-USBVTEST}"
  local sectors
  local attach_out
  local device
  local waited=0

  if (( $# > 2 )); then
    die "create takes at most two arguments: [size_mb] [name]"
  fi

  if [[ ! $size_mb =~ '^[0-9]{1,7}$' ]]; then
    die "size_mb must be a whole number of megabytes, got: $size_mb"
  fi
  size_mb=$(( 10#$size_mb ))
  if (( size_mb < 1 || size_mb > 1048576 )); then
    die "size_mb must be between 1 and 1048576, got: $size_mb"
  fi

  if [[ ! $name =~ '^[A-Za-z0-9_]{1,11}$' ]]; then
    die "name must match ^[A-Za-z0-9_]{1,11}$, got: $name"
  fi

  if [[ -e $state_file ]]; then
    die "state file already exists: $state_file. Run 'ramdisk-exfat.sh remove' first."
  fi

  if [[ -e "/Volumes/$name" ]]; then
    die "a volume is already mounted at /Volumes/$name. Pick another name."
  fi

  sectors=$(( size_mb * 2048 ))

  trap 'create_abort "interrupted"' INT TERM

  if ! attach_out=$(hdiutil attach -nomount "ram://${sectors}"); then
    create_abort "hdiutil could not attach a RAM disk of ${size_mb} MB"
  fi

  device="${attach_out%%$'\n'*}"
  device="${device%%[[:space:]]*}"
  if [[ ! $device =~ '^/dev/disk[0-9]+$' ]]; then
    create_abort "hdiutil returned an unexpected device node: ${device:-<empty>}"
  fi
  created_device="$device"

  # Save the state before the format, so a crash still leaves a way to clean up.
  if ! print -r -- "$device" >| "$state_file"; then
    create_abort "could not write the state file: $state_file"
  fi

  if ! diskutil eraseVolume ExFAT "$name" "$device" >&2; then
    create_abort "diskutil could not format $device as ExFAT"
  fi

  # Wait briefly for the mount to appear after the format.
  while [[ ! -d "/Volumes/$name" && $waited -lt 50 ]]; do
    sleep 0.1
    waited=$(( waited + 1 ))
  done
  if [[ ! -d "/Volumes/$name" ]]; then
    create_abort "the new volume did not appear at /Volumes/$name"
  fi

  trap - INT TERM
  created_device=""

  print -r -- "MOUNT=/Volumes/$name"
  print -r -- "DEVICE=$device"
}

info_value() {
  local value
  value=$(print -r -- "${info_text:-}" | sed -n "s/^[[:space:]]*$1:[[:space:]]*//p")
  value=${value%%$'\n'*}
  # Drop trailing spaces from the field.
  print -r -- "${value%"${value##*[![:space:]]}"}"
}

plist_value() {
  print -r -- "${info_plist:-}" | plutil -extract "$1" raw -o - - 2>/dev/null
}

remove_disk() {
  local device
  local protocol
  local internal
  local virtual
  local disk_image
  local external
  local virtual_or_physical
  local internal_bool
  local is_virtual=0

  if [[ ! -f $state_file ]]; then
    die "no state file at $state_file, nothing to remove"
  fi

  device=$(tr -d '[:space:]' < "$state_file")
  if [[ -z $device ]]; then
    die "state file is empty: $state_file"
  fi
  if [[ ! $device =~ '^/dev/disk[0-9]+$' ]]; then
    die "state file does not hold a whole disk device node: $device"
  fi
  if [[ ! -e $device ]]; then
    die "device $device no longer exists. State file kept at $state_file."
  fi

  if ! info_text=$(LC_ALL=C diskutil info "$device" 2>&1); then
    die "diskutil info failed for $device. State file kept at $state_file."
  fi
  info_plist=$(LC_ALL=C diskutil info -plist "$device" 2>/dev/null) || info_plist=""

  protocol=$(info_value Protocol)
  internal=$(info_value Internal)
  virtual=$(info_value Virtual)
  disk_image=$(info_value "Disk Image")
  external=$(info_value External)

  # The state file must point at a virtual disk, never at real hardware.
  if [[ $protocol == "Virtual Interface" || $protocol == "Disk Image" || $virtual == Yes || $disk_image == Yes ]]; then
    is_virtual=1
  fi
  if (( ! is_virtual )); then
    die "refusing to remove $device: diskutil does not report it as a disk image or virtual device (protocol: ${protocol:-unknown})"
  fi

  # Cross-check the plist view when those keys are present.
  if virtual_or_physical=$(plist_value VirtualOrPhysical); then
    if [[ $virtual_or_physical == Physical ]]; then
      die "refusing to remove $device: diskutil reports VirtualOrPhysical=Physical"
    fi
    if [[ $virtual_or_physical != Virtual ]]; then
      die "refusing to remove $device: diskutil reports VirtualOrPhysical=${virtual_or_physical:-unknown}, expected Virtual"
    fi
  fi
  if internal_bool=$(plist_value Internal); then
    if [[ $internal_bool == true ]]; then
      die "refusing to remove $device: diskutil reports Internal=true"
    fi
  fi

  if ! LC_ALL=C diskutil unmountDisk force "$device" >&2; then
    print -u2 -r -- "ramdisk-exfat: warning: unmountDisk failed for $device, trying detach anyway"
  fi

  if ! hdiutil detach "$device" >&2; then
    die "could not detach $device. State file kept at $state_file."
  fi

  rm -f -- "$state_file"
  print -r -- "Removed RAM disk $device."
}

status_disk() {
  local device

  if [[ ! -f $state_file ]]; then
    print -r -- "No RAM disk state file at $state_file"
    return 0
  fi

  device=$(tr -d '[:space:]' < "$state_file")
  print -r -- "State file: $state_file"
  print -r -- "Device: ${device:-<empty>}"

  if [[ -n $device && $device =~ '^/dev/disk[0-9]+$' && -e $device ]]; then
    print -r -- "Device exists: yes"
    if LC_ALL=C diskutil info "$device" >/dev/null 2>&1; then
      print -r -- "diskutil info: ok"
    else
      print -r -- "diskutil info: failed"
    fi
  else
    print -r -- "Device exists: no"
  fi
}

command="${1:-}"
case "$command" in
  create)
    shift
    create_disk "$@"
    ;;
  remove)
    remove_disk
    ;;
  status)
    status_disk
    ;;
  -h|--help|help)
    usage
    ;;
  "")
    usage >&2
    exit 1
    ;;
  *)
    print -u2 -r -- "ramdisk-exfat: unknown command: $command"
    usage >&2
    exit 1
    ;;
esac
