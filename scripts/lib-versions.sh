#!/usr/bin/env bash
# Shared helpers for querying the Cumulus package repository.
#
# Sourced by new-version.sh and validate-version.sh.

REPO_BASE="${REPO_BASE:-https://download.nvidia.com/cumulus/apt.cumulusnetworks.com/repo}"
COMPONENTS="${COMPONENTS:-cumulus upstream netq}"
CACHE_DIR="${CACHE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.cache/repo}"

if [ -t 1 ]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_BOLD=""; C_RESET=""
fi

info() { printf '  %s\n' "$*"; }
good() { printf '  %sok%s   %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '  %swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
bad()  { printf '  %sFAIL%s %s\n' "$C_RED" "$C_RESET" "$*"; }
head2(){ printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET"; }

die() { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# minor_dir 5.12.0 -> 5.12   (version dirs in this repo are per minor release)
minor_dir() { printf '%s' "$1" | cut -d. -f1,2; }

# list_versions -> all CumulusLinux-* suites published upstream
list_versions() {
  curl -sf "$REPO_BASE/dists/" 2>/dev/null \
    | grep -oE 'CumulusLinux-[0-9][0-9.]*' \
    | sed 's/^CumulusLinux-//' \
    | sort -uV
}

# version_exists <version>
version_exists() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' "$REPO_BASE/dists/CumulusLinux-$1/Release")
  [ "$code" = "200" ]
}

# fetch_packages <version> <component> -> path to decompressed Packages file
fetch_packages() {
  local ver="$1" comp="$2"
  local out="$CACHE_DIR/$ver-$comp.Packages"
  if [ ! -s "$out" ]; then
    mkdir -p "$CACHE_DIR"
    curl -sf "$REPO_BASE/dists/CumulusLinux-$ver/$comp/binary-amd64/Packages.gz" 2>/dev/null \
      | gunzip > "$out.tmp" 2>/dev/null && mv "$out.tmp" "$out" || { rm -f "$out.tmp"; return 1; }
  fi
  printf '%s' "$out"
}

# pkg_index <version> -> path to a "<name> <version>" index, built once per version.
# Later components win, matching the order they appear in sources.list.
pkg_index() {
  local ver="$1"
  local index="$CACHE_DIR/$ver.index"
  local f c
  if [ ! -s "$index" ]; then
    mkdir -p "$CACHE_DIR"
    : > "$index.tmp"
    for c in $COMPONENTS; do
      f=$(fetch_packages "$ver" "$c") || continue
      awk '
        /^Package: / {name=$2; next}
        /^Version: / {if (name != "") {print name, $2; name=""}}
      ' "$f" >> "$index.tmp"
    done
    [ -s "$index.tmp" ] || { rm -f "$index.tmp"; return 1; }
    mv "$index.tmp" "$index"
  fi
  printf '%s' "$index"
}

# pkg_version <version> <package> -> version string, empty if absent
pkg_version() {
  local index
  index=$(pkg_index "$1") || return 1
  awk -v P="$2" '$1==P {print $2; exit}' "$index"
}

# debian_release <version> -> e.g. 12.13, derived from base-files (12.4+deb12u13)
debian_release() {
  local bf; bf=$(pkg_version "$1" base-files)
  [ -n "$bf" ] || return 1
  # 12.4+deb12u13 -> major 12, point 13
  local major point
  major=$(printf '%s' "$bf" | sed -nE 's/.*\+deb([0-9]+)u.*/\1/p')
  point=$(printf '%s' "$bf" | sed -nE 's/.*\+deb[0-9]+u([0-9]+).*/\1/p')
  [ -n "$major" ] && printf '%s.%s' "$major" "$point"
}

# debian_codename <version> -> bookworm / trixie / ...
debian_codename() {
  local rel major; rel=$(debian_release "$1") || return 1
  major=${rel%%.*}
  case "$major" in
    10) printf 'buster'   ;;
    11) printf 'bullseye' ;;
    12) printf 'bookworm' ;;
    13) printf 'trixie'   ;;
    *)  printf 'unknown'  ;;
  esac
}

# latest_local_version -> highest Dockerfile-<ver> present in the repo
latest_local_version() {
  ls Dockerfile-* 2>/dev/null | sed 's/^Dockerfile-//' | sort -V | tail -1
}
