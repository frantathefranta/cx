#!/usr/bin/env bash
# Orchestrates the image test suite.
#
#   tests/run.sh [image-ref]
#
# Static tests run anywhere. Runtime tests need a native amd64 host, because
# systemd is unusable under qemu-user emulation; they are skipped otherwise
# unless FORCE_RUNTIME=1 is set.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

IMAGE="${1:-${IMAGE_REF:-docker.io/networkop/cx:5.11.5}}"
CONTAINER_CLI="${CONTAINER_CLI:-docker}"
export CONTAINER_CLI

if ! $CONTAINER_CLI image inspect "$IMAGE" >/dev/null 2>&1; then
  printf 'error: image %s not found locally. Build it first (make build).\n' "$IMAGE" >&2
  exit 1
fi

rc=0
./static.sh "$IMAGE" || rc=1

host_arch=$(uname -m)
image_arch=$($CONTAINER_CLI image inspect -f '{{.Architecture}}' "$IMAGE" 2>/dev/null)

emulated=0
case "$host_arch:$image_arch" in
  x86_64:amd64|amd64:amd64|aarch64:arm64|arm64:arm64) ;;
  *) emulated=1 ;;
esac

if [ "$emulated" = 1 ] && [ "${FORCE_RUNTIME:-0}" != "1" ]; then
  printf '\n== runtime tests ==\n'
  printf '  skip  host is %s but image is %s; systemd is not usable under qemu\n' "$host_arch" "$image_arch"
  printf '        emulation (systemctl cannot reach the bus). Run these on a\n'
  printf '        native %s host or in CI. Override with FORCE_RUNTIME=1.\n' "$image_arch"
else
  ./runtime.sh "$IMAGE" || rc=1
fi

exit $rc
