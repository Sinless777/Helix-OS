#!/usr/bin/env bash
#
# Helix OS base ISO bootstrap script.
# This file is templated by Nix: anything wrapped in @...@ is substituted at
# build time so you can customize behaviour from the derivation. Edit this file
# to tweak the bootstrap logic without touching the Nix expression.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Values supplied by Nix at substitution time.
optional_packages='@optionalPackagesString@'
host_kernel_pkg='@hostKernelPackage@'
debootstrap_exclude='@debootstrapExcludeString@'

usage() {
  cat <<'USAGE'
Usage: helix-os-base [--output DIR] [--hostname NAME] [--root-password PASSWORD] [--skip-optional]

Creates a bootable Debian-based installer ISO using debootstrap.
Defaults: --output ./artifacts, --hostname helix, --root-password helix
USAGE
}

# Default runtime configuration (overridable via CLI flags).
workdir="$PWD/artifacts"
hostname="helix"
root_password="helix"
install_optional=1

# Parse CLI flags early so we can fail fast on unknown options.
while [ $# -gt 0 ]; do
  case "$1" in
    --output)
      workdir="$2"
      shift 2
      ;;
    --hostname)
      hostname="$2"
      shift 2
      ;;
    --root-password)
      root_password="$2"
      shift 2
      ;;
    --skip-optional)
      install_optional=0
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

mkdir -p "$workdir"

# debootstrap + chroot require root; bail out with a helpful message otherwise.
if [ "$(id -u)" -ne 0 ]; then
  echo "This helper needs root privileges. Re-run with sudo or as root." >&2
  exit 1
fi

rootfs="$workdir/rootfs"
iso_dir="$workdir/iso"
iso_path="$workdir/helix-debian-@suite@-@architecture@.iso"

rm -rf "$rootfs" "$iso_dir" "$iso_path"
mkdir -p "$rootfs"

# Ensure we always unmount bind mounts created during the process.
cleanup_mounts() {
  set +e
  for mp in "$rootfs/dev/pts" "$rootfs/dev" "$rootfs/proc" "$rootfs/sys" "$rootfs/run" "$rootfs/tmp"; do
    if [ -e "$mp" ] && mountpoint -q "$mp" >/dev/null 2>&1; then
      umount -l "$mp"
    fi
  done
  set -e
}
trap cleanup_mounts EXIT

echo ">> Bootstrapping Debian @suite@ (@architecture@) into $rootfs"
# Skip the kernel meta-package during debootstrap so we can install it manually.
if [ -n "$debootstrap_exclude" ]; then
  debootstrap \
    --variant='@variant@' \
    --arch='@architecture@' \
    --components='@componentsString@' \
    --include='@includeString@' \
    --exclude="$debootstrap_exclude" \
    '@suite@' "$rootfs" \
    'http://deb.debian.org/debian'
else
  debootstrap \
    --variant='@variant@' \
    --arch='@architecture@' \
    --components='@componentsString@' \
    --include='@includeString@' \
    '@suite@' "$rootfs" \
    'http://deb.debian.org/debian'
fi

# Bind host pseudo-filesystems so chrooted apt invocations work correctly.
mkdir -p "$rootfs/proc" "$rootfs/sys" "$rootfs/dev/pts" "$rootfs/run" "$rootfs/tmp"
mount --bind /dev "$rootfs/dev"
mount --bind /dev/pts "$rootfs/dev/pts"
mount -t proc proc "$rootfs/proc"
mount -t sysfs sys "$rootfs/sys"
mount -t tmpfs tmpfs "$rootfs/run"
mount -t tmpfs tmpfs "$rootfs/tmp"

# Configure minimal networking/hostname information for the live environment.
echo ">> Configuring basic system files"
mkdir -p "$rootfs/etc"
echo "$hostname" > "$rootfs/etc/hostname"
cat > "$rootfs/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $hostname

# IPv6
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

mkdir -p "$rootfs/etc/systemd/system/getty@tty1.service.d"
cat > "$rootfs/etc/systemd/system/getty@tty1.service.d/override.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --noclear --autologin root %I \$TERM
EOF

echo "root:$root_password" | chroot "$rootfs" chpasswd
chroot "$rootfs" systemctl enable ssh.service >/dev/null 2>&1 || true

# Add a default non-root user if it doesn't already exist.
if ! chroot "$rootfs" id helix >/dev/null 2>&1; then
  echo ">> Creating helix user"
  chroot "$rootfs" useradd -m -s /bin/bash -G sudo helix
  echo "helix:helix" | chroot "$rootfs" chpasswd
fi

# systemd stores some core libraries in /usr/lib/...; copy them into /lib so
# PID 1 can find them during early boot. Also update the dynamic linker cache.
echo ">> Ensuring systemd runtime libraries are discoverable"
mkdir -p "$rootfs/etc/ld.so.conf.d"
cat > "$rootfs/etc/ld.so.conf.d/systemd.conf" <<'EOF'
/usr/lib/x86_64-linux-gnu/systemd
EOF
chroot "$rootfs" ldconfig
mkdir -p "$rootfs/lib/x86_64-linux-gnu"
for lib in "$rootfs"/usr/lib/x86_64-linux-gnu/systemd/libsystemd-*.so; do
  base="$(basename "$lib")"
  target="$rootfs/lib/x86_64-linux-gnu/$base"
  if [ -e "$target" ]; then
    rm -f "$target"
  fi
  cp -a "$lib" "$target"
done
chroot "$rootfs" ldconfig

echo ">> Updating package index"
chroot "$rootfs" apt-get update

# Install kernel meta-package with fallbacks so we always end up with something bootable.
echo ">> Installing kernel package ($host_kernel_pkg) with fallback handling"
kernel_installed=0
if chroot "$rootfs" apt-get install -y --no-install-recommends "$host_kernel_pkg"; then
  kernel_installed=1
else
  echo "!! Failed to install $host_kernel_pkg, trying dependency fallback" >&2
  chroot "$rootfs" apt-get install -f -y >/dev/null 2>&1 || true
  fallback_kernel=$(chroot "$rootfs" sh -c "apt-cache depends $host_kernel_pkg 2>/dev/null | awk '/Depends: / {print \$2}' | head -n1")
  if [ -n "$fallback_kernel" ] && [ "$fallback_kernel" != "$host_kernel_pkg" ]; then
    echo ">> Attempting fallback kernel package: $fallback_kernel"
    if chroot "$rootfs" apt-get install -y --no-install-recommends "$fallback_kernel"; then
      kernel_installed=1
    else
      chroot "$rootfs" apt-get install -f -y >/dev/null 2>&1 || true
    fi
  fi
fi

if [ "$kernel_installed" -ne 1 ]; then
  fallback_kernel=$(chroot "$rootfs" sh -c "apt-cache search '^linux-image-[0-9].*-amd64$' | awk '{print \$1}' | sort -V | tail -n1")
  if [ -n "$fallback_kernel" ]; then
    echo ">> Attempting generic kernel package: $fallback_kernel"
    if chroot "$rootfs" apt-get install -y --no-install-recommends "$fallback_kernel"; then
      kernel_installed=1
    else
      chroot "$rootfs" apt-get install -f -y >/dev/null 2>&1 || true
    fi
  fi
fi

if [ "$kernel_installed" -ne 1 ]; then
  echo "Failed to install a kernel package; aborting." >&2
  exit 1
fi

# Optional packages are best-effort: record failures but continue building.
if [ "$install_optional" -eq 1 ] && [ -n "$optional_packages" ]; then
  echo ">> Attempting to install optional packages (best effort)"
  failed_file="$workdir/failed-optional-packages.txt"
  rm -f "$failed_file"
  failed_any=0
  for pkg in $optional_packages; do
    if ! chroot "$rootfs" apt-get install -y --no-install-recommends "$pkg"; then
      echo "!! Failed to install optional package: $pkg" >&2
      failed_any=1
      echo "$pkg" >> "$failed_file"
      chroot "$rootfs" apt-get install -f -y >/dev/null 2>&1 || true
    fi
  done
  if [ "$failed_any" -eq 1 ]; then
    echo "Some optional packages could not be installed. See $failed_file for details."
  else
    rm -f "$failed_file"
  fi
fi

# Some optional packages enable background services that do not make sense
# in the live installer environment (they fail noisily when no containers
# are configured). Disable them to keep the boot clean.
disable_unit_if_exists() {
  local unit="$1"
  if systemctl --root="$rootfs" list-unit-files "$unit" >/dev/null 2>&1; then
    systemctl --root="$rootfs" disable "$unit" >/dev/null 2>&1 || true
    systemctl --root="$rootfs" mask "$unit" >/dev/null 2>&1 || true
  fi
}
disable_unit_if_exists "podman-auto-update.service"
disable_unit_if_exists "podman-auto-update.timer"
disable_unit_if_exists "podman-restart.service"

chroot "$rootfs" apt-get clean >/dev/null 2>&1 || true

cleanup_mounts

# Recreate top-level mount points so the live initramfs can bind over them later.
for dir in dev proc sys run tmp; do
  mkdir -p "$rootfs/$dir"
done

# Build the compressed live filesystem while excluding transient/bind directories.
echo ">> Creating squashfs from root filesystem"
mkdir -p "$iso_dir/live"
kernel_image=$(basename "$(find "$rootfs/boot" -maxdepth 1 -type f -name 'vmlinuz-*' | sort | tail -n1)")
initrd_image=$(basename "$(find "$rootfs/boot" -maxdepth 1 -type f -name 'initrd.img-*' | sort | tail -n1)")

if [ -z "$kernel_image" ] || [ -z "$initrd_image" ]; then
  echo "Unable to locate kernel or initramfs in $rootfs/boot" >&2
  exit 1
fi

cp "$rootfs/boot/$kernel_image" "$iso_dir/live/vmlinuz"
cp "$rootfs/boot/$initrd_image" "$iso_dir/live/initrd.img"

mksquashfs "$rootfs" "$iso_dir/live/filesystem.squashfs" -comp xz -wildcards \
  -e boot

# Minimal GRUB configuration with both graphical console and serial output.
mkdir -p "$iso_dir/boot/grub"
cat > "$iso_dir/boot/grub/grub.cfg" <<'EOF'
set default=0
set timeout=5

menuentry "Helix OS Live" {
  linux /live/vmlinuz boot=live console=tty0 console=ttyS0,115200n8
  initrd /live/initrd.img
}
EOF

echo ">> Generating installer ISO at $iso_path"
grub-mkrescue -o "$iso_path" "$iso_dir" >/dev/null

echo "Installer ISO created at $iso_path"
