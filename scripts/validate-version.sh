#!/usr/bin/env bash
# Static checks on a version's Dockerfile and supporting files, before building.
#
#   scripts/validate-version.sh 5.12.0
#
# Encodes the failure modes this repo has actually hit, so they are caught by
# reading files rather than by a 40-minute build.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=lib-versions.sh
. scripts/lib-versions.sh

VER="${1:?usage: scripts/validate-version.sh <version>}"
DOCKERFILE="Dockerfile-$VER"
DIR=$(minor_dir "$VER")
FAILURES=0
WARNINGS=0
fail() { bad "$*"; FAILURES=$((FAILURES+1)); }
soft() { warn "$*"; WARNINGS=$((WARNINGS+1)); }

printf '%sValidating %s%s\n' "$C_BOLD" "$VER" "$C_RESET"

head2 "files"
[ -f "$DOCKERFILE" ] || die "$DOCKERFILE not found (run scripts/new-version.sh $VER)"
good "$DOCKERFILE exists"

# Every COPY source must exist, or the build dies late and confusingly.
while read -r src; do
  [ -n "$src" ] || continue
  case "$src" in --*) continue ;; esac
  if [ -e "$src" ]; then good "COPY source present: $src"; else fail "COPY source missing: $src"; fi
done < <(awk '/^COPY /{for(i=2;i<NF;i++) print $i}' "$DOCKERFILE")

head2 "repository wiring"
if ! version_exists "$VER"; then
  fail "CumulusLinux-$VER does not exist upstream"
else
  good "CumulusLinux-$VER exists upstream"
fi

if [ -f "$DIR/sources.list" ]; then
  if grep -q "CumulusLinux-$VER\b" "$DIR/sources.list"; then
    good "$DIR/sources.list points at CumulusLinux-$VER"
  else
    fail "$DIR/sources.list does not reference CumulusLinux-$VER (stale copy?): $(grep -oE 'CumulusLinux-[0-9a-z.-]+' "$DIR/sources.list" | sort -u | tr '\n' ' ')"
  fi
else
  fail "$DIR/sources.list missing"
fi

[ -f "$DIR/trusted.gpg" ] && good "$DIR/trusted.gpg present" || fail "$DIR/trusted.gpg missing"

head2 "apt pinning (guards against Debian point-release drift)"
# A pin naming the wrong suite is silently inert, which is exactly how the
# openssh/cumulus-overrides breakage went unnoticed.
pin_line=$(grep -oE 'Pin: release n=CumulusLinux-[0-9a-z.-]+' "$DOCKERFILE" | head -1)
pin_file=$(grep -oE '/etc/apt/preferences\.d/[A-Za-z0-9._-]+' "$DOCKERFILE" | head -1)
if [ -z "$pin_line" ]; then
  soft "no apt pin found; Debian may ship newer packages than the Cumulus snapshot"
else
  if [ "$pin_line" = "Pin: release n=CumulusLinux-$VER" ]; then
    good "apt pin targets CumulusLinux-$VER"
  else
    fail "apt pin targets the wrong suite: '$pin_line' (should be CumulusLinux-$VER) - a stale pin does nothing"
  fi
  prio=$(grep -oE 'Pin-Priority: [0-9]+' "$DOCKERFILE" | head -1 | awk '{print $2}')
  if [ "${prio:-0}" -gt 1000 ]; then
    good "pin priority $prio permits the downgrades the snapshot requires"
  else
    fail "pin priority ${prio:-unset} is <= 1000, so apt will not downgrade to the Cumulus snapshot"
  fi
  # cumulus-overrides installs 20_prefer_cumulus at priority 991 and apt reads
  # preferences.d in lexical order, first match winning.
  base=$(basename "${pin_file:-unset}")
  if [ "$base" != "unset" ] && [ "$base" \< "20_prefer_cumulus" ]; then
    good "pin file '$base' sorts before 20_prefer_cumulus"
  else
    fail "pin file '$base' does not sort before 20_prefer_cumulus, so priority 991 wins instead"
  fi
fi

head2 "base image vs Cumulus snapshot"
from_line=$(grep -m1 '^FROM ' "$DOCKERFILE" | awk '{print $2}')
deb_rel=$(debian_release "$VER" 2>/dev/null)
deb_code=$(debian_codename "$VER" 2>/dev/null)
if [ -n "$deb_code" ] && [ "$deb_code" != "unknown" ]; then
  info "Cumulus $VER mirrors Debian $deb_rel ($deb_code)"
  case "$from_line" in
    *"$deb_code"*) good "FROM $from_line matches $deb_code" ;;
    *) fail "FROM $from_line does not look like $deb_code" ;;
  esac
else
  soft "could not determine the Debian base for $VER"
fi

head2 "package manifest"
if [ ! -f "$DIR/packages" ]; then
  fail "$DIR/packages missing"
else
  total=0; stale=0; first_stale=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in \#*) continue ;; esac
    total=$((total+1))
    name=${line%%=*}; pinned=${line#*=}
    [ "$name" != "$pinned" ] || continue      # unpinned entry, nothing to check
    actual=$(pkg_version "$VER" "$name")
    if [ -z "$actual" ]; then
      stale=$((stale+1)); [ -n "$first_stale" ] || first_stale="$name (absent from repo)"
    elif [ "$actual" != "$pinned" ]; then
      stale=$((stale+1)); [ -n "$first_stale" ] || first_stale="$name pinned $pinned, repo has $actual"
    fi
  done < "$DIR/packages"
  if [ "$stale" -eq 0 ]; then
    good "all $total pinned packages resolve in the $VER repo"
  else
    fail "$stale of $total pinned packages do not match the $VER repo (e.g. $first_stale)"
  fi

  # The openssh trap: openssh-server has a strict "Depends: openssh-client (= same
  # version)". Pinning only the client strands the server on the Debian version.
  if grep -q '^openssh-client=' "$DIR/packages"; then
    if grep -q '^openssh-server=' "$DIR/packages" || [ -n "$pin_line" ]; then
      good "openssh pinning is coherent (server pinned or apt pin present)"
    else
      fail "$DIR/packages pins openssh-client but not openssh-server, and there is no apt pin - cumulus-overrides will fail to install"
    fi
  fi
fi

head2 "container workarounds"
# Fixes that are not version-specific and should survive a version bump.
check_ref() {
  local pattern="$1" desc="$2" severity="${3:-soft}"
  if grep -q "$pattern" "$DOCKERFILE"; then
    good "$desc"
  elif [ "$severity" = fail ]; then
    fail "$desc - missing"
  else
    soft "$desc - missing (was needed for 5.11.5)"
  fi
}
check_ref 'fileops.patch'            'NVUE bind-mount fix (/etc/hosts, /etc/hostname)'
check_ref 'what-just-happened'       'what-just-happened stub or package handling'
check_ref 'forced_platform'          'platform hardcoded to cumulus_vx'
check_ref 'onie-sysinfo'             'onie-sysinfo spoofed'
check_ref 'switchd.service'          'switchd stubbed out'
check_ref 'ENTRYPOINT'               'ENTRYPOINT set' fail

printf '\n---------------------------------------------\n'
if [ "$FAILURES" -gt 0 ]; then
  printf '%s%d failure(s)%s, %d warning(s)\n' "$C_RED" "$FAILURES" "$C_RESET" "$WARNINGS"
  exit 1
fi
printf '%svalidation passed%s (%d warning(s))\n' "$C_GREEN" "$C_RESET" "$WARNINGS"
