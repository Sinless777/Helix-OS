#!/usr/bin/env bash
set -euo pipefail

select_qemu_bin() {
  local candidate=""

  if [ -n "${QEMU_BIN:-}" ] && [ -x "${QEMU_BIN}" ]; then
    candidate="${QEMU_BIN}"
  elif [ -x /usr/bin/qemu-system-x86_64 ]; then
    candidate=/usr/bin/qemu-system-x86_64
  elif command -v qemu-system-x86_64 >/dev/null 2>&1; then
    candidate=$(command -v qemu-system-x86_64)
  fi

  # Avoid linuxbrew or snap builds which pull incompatible glibc
  if [ -n "$candidate" ]; then
    case "$candidate" in
      */.linuxbrew/*|/snap/*)
        if [ -x /usr/bin/qemu-system-x86_64 ]; then
          candidate=/usr/bin/qemu-system-x86_64
        fi
        ;;
    esac
  fi

  printf '%s' "$candidate"
}

qemu_bin="$(select_qemu_bin)"

if [ -z "$qemu_bin" ]; then
  echo "qemu-system-x86_64 not found. Install QEMU or set QEMU_BIN to a valid binary." >&2
  exit 1
fi

latest=$(ls -1t artifacts/helix-debian-*.iso 2>/dev/null | head -n1)
if [ -z "$latest" ]; then
  echo "No installer ISO found in artifacts/. Run task build first." >&2
  exit 1
fi

memory="${QEMU_MEMORY:-2048}"
cpus="${QEMU_CPUS:-2}"

accel_args=()
cpu_args=( -cpu qemu64 )
if [ "${ENABLE_KVM:-0}" != "0" ] && [ -c /dev/kvm ] && [ -w /dev/kvm ]; then
  accel_args=( -enable-kvm )
  cpu_args=( -cpu host )
elif [ -n "${QEMU_ACCEL:-}" ]; then
  accel_args=( -accel "${QEMU_ACCEL}" )
fi

display_args=()
if [ -n "${QEMU_DISPLAY:-}" ]; then
  display_args=( -display "${QEMU_DISPLAY}" )
elif [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
  display_args=( -display gtk )
else
  display_args=( -nographic -serial mon:stdio )
fi

extra_args=()
if [ -n "${QEMU_EXTRA_ARGS:-}" ]; then
  # shellcheck disable=SC2206
  extra_args=( ${QEMU_EXTRA_ARGS} )
fi

# Run QEMU with a trimmed environment to avoid snap/linuxbrew ld paths
safe_env=(env -i)
safe_env+=(PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
safe_env+=(LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu:/usr/lib:/lib")
safe_env+=(HOME="$HOME")
safe_env+=(TERM="${TERM:-xterm-256color}")
[ -n "${DISPLAY:-}" ] && safe_env+=(DISPLAY="$DISPLAY")
[ -n "${XAUTHORITY:-}" ] && safe_env+=(XAUTHORITY="$XAUTHORITY")
[ -n "${XDG_RUNTIME_DIR:-}" ] && safe_env+=(XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR")

echo "Launching $latest in QEMU (memory=${memory}MB, cpus=${cpus}) via $qemu_bin"
exec "${safe_env[@]}" "$qemu_bin" \
  -name "Helix Installer" \
  -m "${memory}" \
  -smp "${cpus}" \
  -cdrom "${latest}" \
  -boot d \
  "${cpu_args[@]}" \
  "${accel_args[@]}" \
  "${display_args[@]}" \
  "${extra_args[@]}"
