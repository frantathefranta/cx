#!/usr/bin/env bash
# Offline checks against the built image. These do NOT boot systemd, so they
# work everywhere, including under qemu emulation on Apple Silicon.
#
# Usage: tests/static.sh <image-ref>
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib.sh
. ./lib.sh

IMAGE="${1:?usage: static.sh <image-ref>}"
PLATFORM_FLAG=${PLATFORM:+--platform $PLATFORM}

# Run a shell snippet inside the image (bypassing the /sbin/init entrypoint).
in_image() {
  # shellcheck disable=SC2086
  $CONTAINER_CLI run --rm $PLATFORM_FLAG --entrypoint bash "$IMAGE" -c "$1" 2>/dev/null
}

printf 'Static image tests: %s\n' "$IMAGE"

section "image metadata"
entrypoint=$($CONTAINER_CLI inspect -f '{{json .Config.Entrypoint}}' "$IMAGE" 2>/dev/null)
assert_contains "entrypoint is /sbin/init" "$entrypoint" "/sbin/init"

section "package database consistency"
# apt-get check prints nothing extra when the dependency tree is satisfiable.
check_out=$(in_image 'apt-get check 2>&1 | grep -iE "unmet|broken|E:" || true')
assert_eq "apt-get check reports no unmet/broken dependencies" "" "$check_out"

# Anything not in state 'ii' (installed/configured) is suspect. 'rc' (removed,
# config files left) is benign and expected for systemd-timesyncd.
badpkgs=$(in_image "dpkg-query -W -f='\${Package} \${db:Status-Abbrev}\n' 2>/dev/null | awk '\$2!=\"ii\" && \$2!=\"rc\" {print \$1\" \"\$2}'")
assert_eq "no half-installed/unconfigured packages" "" "$badpkgs"

section "openssh version coherence (regression: cumulus-overrides dependency)"
# openssh-server has a strict "Depends: openssh-client (= <same version>)".
# Debian point releases drift ahead of the frozen Cumulus snapshot, which used
# to strand the server at a newer version and break cumulus-overrides.
read -r sv cv fv <<<"$(in_image "dpkg-query -W -f='\${Version} ' openssh-server openssh-client openssh-sftp-server 2>/dev/null")"
assert_eq "openssh-server matches openssh-client" "$cv" "$sv"
assert_eq "openssh-sftp-server matches openssh-client" "$cv" "$fv"

# The pin must sort before 20_prefer_cumulus (installed by cumulus-overrides at
# priority 991); apt reads preferences.d alphabetically and first match wins.
pin_first=$(in_image 'ls /etc/apt/preferences.d/ | sort | head -1')
assert_eq "cumulus snapshot pin sorts first in preferences.d" "00_cumulus_snapshot" "$pin_first"
pin_prio=$(in_image "apt-cache policy openssh-server 2>/dev/null | awk '/download.nvidia.com/ {print \$1; exit}'")
assert_eq "cumulus repo outranks debian for openssh-server" "1001" "$pin_prio"

# The whole point of the pin: the installed version must come from the Cumulus
# snapshot, not from whatever Debian has drifted to.
installed_ssh=$(in_image "dpkg-query -W -f='\${Version}' openssh-server")
cumulus_ssh=$(in_image "apt-cache madison openssh-server 2>/dev/null | awk '/download.nvidia.com/ {print \$3; exit}'")
assert_eq "installed openssh-server is the Cumulus snapshot version" "$cumulus_ssh" "$installed_ssh"

section "required packages"
for pkg in cumulus-overrides switchd cumulus-tools frr ifupdown2 python3-nvue nvue-addons openssh-server; do
  ver=$(in_image "dpkg-query -W -f='\${Version}' $pkg 2>/dev/null")
  if [ -n "$ver" ]; then ok "$pkg installed ($ver)"; else nok "$pkg installed"; fi
done

section "required binaries"
for bin in vtysh ifreload nv nvued switchd sshd ip; do
  path=$(in_image "command -v $bin")
  if [ -n "$path" ]; then ok "$bin present ($path)"; else nok "$bin present"; fi
done
# Not on PATH, but the Dockerfile stubs it and Cumulus tooling calls it by path.
assert_eq "decode-syseeprom stub is executable" \
  "yes" "$(in_image 'test -x /usr/cumulus/bin/decode-syseeprom && echo yes')"

section "container platform spoofing"
assert_contains "onie-sysinfo reports cumulus_vx docker platform" \
  "$(in_image 'onie-sysinfo')" "x86-cumulus_vx-docker"
assert_contains "python platform hardcoded to cumulus_vx" \
  "$(in_image 'grep -o "forced_platform=\"cumulus_vx\"" /usr/lib/python3/dist-packages/cumulus/platforms/__init__.py')" \
  'forced_platform="cumulus_vx"'
assert_eq "ports.conf exists (needed by 'show configuration commands')" \
  "yes" "$(in_image 'test -f /etc/cumulus/ports.conf && echo yes')"

section "container hacks applied"
assert_eq "rsyslog.conf is a regular file, not a symlink (AppArmor)" \
  "yes" "$(in_image 'test -f /etc/rsyslog.conf && ! test -L /etc/rsyslog.conf && echo yes')"
assert_eq "ZTP disabled" \
  "yes" "$(in_image 'test ! -e /etc/systemd/system/multi-user.target.wants/ztp.service && echo yes')"
assert_eq "smond disabled" \
  "yes" "$(in_image 'test ! -e /etc/systemd/system/multi-user.target.wants/smond.service && echo yes')"
# Boot-time startup-apply is redundant when netlab pushes config after boot, and
# it accounted for roughly half the boot time.
assert_eq "nvue-startup not enabled at boot (netlab applies config itself)" \
  "yes" "$(in_image 'test ! -e /etc/systemd/system/multi-user.target.wants/nvue-startup.service && echo yes')"
assert_eq "nvued still enabled (NVUE CLI/API must work)" \
  "yes" "$(in_image 'test -e /etc/systemd/system/multi-user.target.wants/nvued.service && echo yes')"
assert_contains "switchd stubbed out (no real ASIC in a container)" \
  "$(in_image 'grep ^ExecStart /lib/systemd/system/switchd.service')" "tail -f /dev/null"
assert_contains "aclinit stubbed out" \
  "$(in_image 'grep ^ExecStart /lib/systemd/system/aclinit.service')" "ExecStart=true"
assert_eq "mgmt vrf interfaces file installed" \
  "yes" "$(in_image 'grep -q mgmt /etc/network/interfaces && echo yes')"

section "netlab / containerlab expectations"
# netlab drives Cumulus 5.x through NVUE; NCLU ('net') was removed in 5.x, so a
# missing 'net' binary means the netlab device type must be cumulus_nvue.
if [ -n "$(in_image 'command -v net')" ]; then
  ok "NCLU 'net' present (netlab device type 'cumulus' viable)"
else
  skip "NCLU 'net' absent - use netlab device type 'cumulus_nvue'" "expected on 5.x"
fi
assert_eq "sshd config permits root login (netlab/ansible access)" \
  "yes" "$(in_image 'grep -qE "^PermitRootLogin yes" /etc/ssh/sshd_config && echo yes')"
assert_eq "cumulus user exists" \
  "yes" "$(in_image 'id cumulus >/dev/null 2>&1 && echo yes')"

# netlab enables individual FRR daemons via /etc/frr/daemons; the binaries have
# to exist for the routing modules (ospf, bgp, ...) to work.
assert_eq "/etc/frr/daemons present (netlab toggles daemons here)" \
  "yes" "$(in_image 'test -f /etc/frr/daemons && echo yes')"
for d in zebra ospfd ospf6d bgpd staticd; do
  if [ -n "$(in_image "test -x /usr/lib/frr/$d && echo yes")" ]; then
    ok "frr daemon $d available"
  else
    nok "frr daemon $d available"
  fi
done

summary
