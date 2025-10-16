{ pkgs
, suite ? "bookworm"
, architecture ? "amd64"
, variant ? "minbase"
, components ? [ "main" ]
, includePackages ? let
    packageGroups = import ./package-groups;
    allPackages = builtins.concatLists (builtins.attrValues packageGroups);
  in pkgs.lib.lists.unique allPackages
}:

pkgs.writeShellApplication {
  name = "helix-debian-bootstrap";

  runtimeInputs = with pkgs; [
    debootstrap
    util-linux
    coreutils
    gnutar
    gzip
  ];

  text = ''
    set -euo pipefail

    usage() {
      echo "Usage: $0 [--output DIR] [--hostname NAME] [--root-password PASSWORD]"
      echo ""
      echo "Creates a minimal Debian root filesystem tarball using debootstrap."
      echo "Defaults: --output ./artifacts, --hostname helix, --root-password helix"
    }

    # Defaults
    workdir="$PWD/artifacts"
    hostname="helix"
    root_password="helix"

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

    if [ "$(id -u)" -ne 0 ]; then
      echo "This helper needs root privileges. Re-run with sudo or as root." >&2
      exit 1
    fi

    rootfs="$workdir/rootfs"
    tarball="$workdir/helix-debian-${suite}-${architecture}.tar.gz"

    rm -rf "$rootfs"
    mkdir -p "$rootfs"

    echo ">> Bootstrapping Debian ${suite} (${architecture}) into $rootfs"
    debootstrap \
      --variant='${variant}' \
      --arch='${architecture}' \
      --components='${builtins.concatStringsSep "," components}' \
      --include='${builtins.concatStringsSep "," includePackages}' \
      '${suite}' "$rootfs" \
      'http://deb.debian.org/debian'

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

    if ! chroot "$rootfs" id helix >/dev/null 2>&1; then
      echo ">> Creating helix user"
      chroot "$rootfs" useradd -m -s /bin/bash -G sudo helix
      echo "helix:helix" | chroot "$rootfs" chpasswd
    fi

    chroot "$rootfs" apt-get clean >/dev/null 2>&1 || true

    echo ">> Producing rootfs tarball at $tarball"
    tar --numeric-owner --sort=name --xattrs --acls -C "$rootfs" -czf "$tarball" .

    echo "Root filesystem created at $tarball"
  '';
}
