#!/usr/bin/env bash
# Boots the image with systemd and checks that the services netlab/containerlab
# rely on actually come up.
#
# REQUIRES a native amd64 host: under qemu-user emulation systemd starts but
# systemctl cannot reach it ("Transport endpoint is not connected"), because
# credential passing over the private AF_UNIX socket does not survive emulation.
#
# Usage: tests/runtime.sh <image-ref>
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib.sh
. ./lib.sh

IMAGE="${1:?usage: runtime.sh <image-ref>}"
NAME="${CX_TEST_NAME:-cx-runtime-test}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-120}"
PLATFORM_FLAG=${PLATFORM:+--platform $PLATFORM}

cleanup() { $CONTAINER_CLI rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

cex() { $CONTAINER_CLI exec "$NAME" "$@" 2>&1; }

printf 'Runtime tests: %s\n' "$IMAGE"

section "boot"
cleanup
# --privileged + a writable cgroup fs is what containerlab/netlab effectively give it.
# shellcheck disable=SC2086
if ! $CONTAINER_CLI run -d --name "$NAME" --privileged $PLATFORM_FLAG \
      --tmpfs /run --tmpfs /run/lock "$IMAGE" >/dev/null 2>&1; then
  nok "container starts"
  summary; exit 1
fi
ok "container starts"

state=""
deadline=$((SECONDS + BOOT_TIMEOUT))
while [ $SECONDS -lt $deadline ]; do
  state=$(cex systemctl is-system-running | tr -d '\r\n')
  case "$state" in
    running|degraded) break ;;
    *) sleep 3 ;;
  esac
done

case "$state" in
  running)  ok "systemd reached 'running' state" ;;
  degraded) ok "systemd reached 'degraded' state (normal in a container)" ;;
  *)        nok "systemd booted within ${BOOT_TIMEOUT}s" "last state: '$state'"
            printf '\n--- container logs ---\n%s\n' "$($CONTAINER_CLI logs "$NAME" 2>&1 | tail -20)"
            summary; exit 1 ;;
esac

section "failed units (informational)"
failed=$(cex systemctl list-units --state=failed --no-legend --no-pager | awk '{print $2}' | grep -v '^$' || true)
if [ -z "$failed" ]; then
  ok "no failed units"
else
  printf '  note: failed units present:\n'
  printf '%s\n' "$failed" | sed 's/^/        /'
fi

section "critical services"
# These are the units netlab/ansible and the Cumulus CLI actually depend on.
for unit in ssh frr nvued rsyslog; do
  st=$(cex systemctl is-active "$unit" | tr -d '\r\n')
  assert_eq "$unit is active" "active" "$st"
done

section "CLI surfaces"
assert_contains "vtysh responds" "$(cex vtysh -c 'show version')" "FRRouting"
assert_contains "NVUE CLI responds" "$(cex nv show system)" "build"
assert_contains "sshd is listening on :22" "$(cex ss -lnt)" ":22"

section "interface handling (netlab wires swp* links)"
# containerlab attaches veths named swp1, swp2, ... netlab then pushes config
# and expects ifupdown2 to bring them up.
cex ip link add swp1 type dummy >/dev/null
cex ip link set swp1 up >/dev/null
assert_contains "swp1 visible to iproute2" "$(cex ip -br link show swp1)" "swp1"

# The image enables a mgmt VRF by default (hacks/interfaces), so ifreload needs
# VRF support from the *host* kernel. Ubuntu ships vrf.ko in linux-modules-extra,
# which is absent on some minimal/VM kernels; without it ifreload -a fails with
# "mgmt: create failed ... Operation not supported" and ntpsec@mgmt.service dies.
if cex ip link add cx-vrf-probe type vrf table 999 >/dev/null 2>&1; then
  cex ip link del cx-vrf-probe >/dev/null 2>&1
  assert_cmd "ifreload -a succeeds" "$CONTAINER_CLI" exec "$NAME" ifreload -a
else
  skip "ifreload -a succeeds" "host kernel lacks VRF support; install linux-modules-extra-\$(uname -r) and modprobe vrf"
fi
assert_contains "NVUE sees swp1" "$(cex nv show interface)" "swp1"

section "NVUE config apply (netlab cumulus_nvue provisioning path)"
if out=$(cex nv set interface swp1 ip address 10.11.12.13/24) && \
   out=$(cex nv config apply --assume-yes); then
  ok "nv set + nv config apply succeeded"
  assert_contains "address applied to swp1" "$(cex ip -4 -br addr show swp1)" "10.11.12.13"
else
  nok "nv set + nv config apply succeeded" "$(printf '%s' "$out" | tail -5)"
fi

summary
