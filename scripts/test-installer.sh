#!/usr/bin/env bash
set -euo pipefail

latest=$(ls -1t artifacts/helix-debian-*.iso 2>/dev/null | head -n1)
if [ -z "$latest" ]; then
  echo "No installer ISO found in artifacts/. Run task build first." >&2
  exit 1
fi
if ! file "$latest" | grep -q 'ISO 9660'; then
  echo "$latest does not appear to be an ISO image" >&2
  exit 1
fi
if command -v isoinfo >/dev/null 2>&1; then
  if ! isoinfo -i "$latest" -f | grep -q '^/live/filesystem.squashfs$'; then
    echo "/live/filesystem.squashfs not found inside $latest" >&2
    exit 1
  fi
  if ! isoinfo -i "$latest" -f | grep -q '^/boot/grub/grub.cfg$'; then
    echo "/boot/grub/grub.cfg not found inside $latest" >&2
    exit 1
  fi
else
  if ! command -v xorriso >/dev/null 2>&1; then
    echo "Neither isoinfo nor xorriso found in PATH. Install genisoimage/cdrkit or xorriso to continue." >&2
    exit 1
  fi
  if ! xorriso -indev "$latest" -lsl /live/filesystem.squashfs >/dev/null 2>&1; then
    echo "/live/filesystem.squashfs not found inside $latest" >&2
    exit 1
  fi
  if ! xorriso -indev "$latest" -lsl /boot/grub/grub.cfg >/dev/null 2>&1; then
    echo "/boot/grub/grub.cfg not found inside $latest" >&2
    exit 1
  fi
fi
echo "Checked $latest: valid ISO with live filesystem and GRUB config."
