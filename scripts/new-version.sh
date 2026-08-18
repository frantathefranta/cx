#!/usr/bin/env bash
# Bootstrap the files needed to build a new Cumulus Linux version.
#
#   scripts/new-version.sh 5.12.0 [--from 5.11.5]
#
# Creates:
#   <minor>/sources.list      repo definition for the new suite
#   <minor>/trusted.gpg       copied from the source version
#   <minor>/packages          package names from the source version, re-pinned
#                             to the versions published for the new release
#   Dockerfile-<version>      copied from the source version with paths and
#                             version strings rewritten
#
# Nothing is overwritten unless --force is given.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=lib-versions.sh
. scripts/lib-versions.sh

NEW=""
FROM=""
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from)  FROM="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *)  NEW="$1"; shift ;;
  esac
done

[ -n "$NEW" ] || die "usage: scripts/new-version.sh <version> [--from <version>] [--force]"

head2 "validating $NEW against the upstream repository"
if ! version_exists "$NEW"; then
  bad "CumulusLinux-$NEW not found upstream"
  info "available versions:"
  list_versions | tail -20 | sed 's/^/        /'
  exit 1
fi
good "CumulusLinux-$NEW exists upstream"

[ -n "$FROM" ] || FROM=$(latest_local_version)
[ -n "$FROM" ] || die "no existing Dockerfile-* to copy from; pass --from"
[ -f "Dockerfile-$FROM" ] || die "Dockerfile-$FROM not found"
good "using Dockerfile-$FROM as the starting point"

NEW_DIR=$(minor_dir "$NEW")
OLD_DIR=$(minor_dir "$FROM")
DOCKERFILE="Dockerfile-$NEW"

if [ -e "$DOCKERFILE" ] && [ "$FORCE" != 1 ]; then
  die "$DOCKERFILE already exists (use --force to overwrite)"
fi

# ---------------------------------------------------------------- repo details
head2 "repository metadata"
DEB_RELEASE=$(debian_release "$NEW") || DEB_RELEASE=""
DEB_CODENAME=$(debian_codename "$NEW") || DEB_CODENAME=""
if [ -n "$DEB_RELEASE" ]; then
  good "built from Debian $DEB_RELEASE ($DEB_CODENAME)"
else
  warn "could not determine the Debian base (base-files missing from the repo?)"
fi

OLD_DEB_RELEASE=$(debian_release "$FROM" 2>/dev/null) || OLD_DEB_RELEASE=""
if [ -n "$OLD_DEB_RELEASE" ] && [ "$OLD_DEB_RELEASE" != "$DEB_RELEASE" ]; then
  info "note: $FROM was built from Debian $OLD_DEB_RELEASE, $NEW from $DEB_RELEASE"
fi

# ------------------------------------------------------------------- directory
head2 "creating $NEW_DIR/"
mkdir -p "$NEW_DIR"

# sources.list
if [ -e "$NEW_DIR/sources.list" ] && [ "$FORCE" != 1 ]; then
  warn "$NEW_DIR/sources.list exists, leaving it alone"
else
  cat > "$NEW_DIR/sources.list" <<EOF
# Cumulus Linux package repository
deb      $REPO_BASE CumulusLinux-$NEW cumulus upstream netq
deb-src  $REPO_BASE CumulusLinux-$NEW cumulus upstream netq

# This version of /etc/apt/sources.list is used if it is not provided by a
# package such as cumulus-archive-keyring.
EOF
  good "wrote $NEW_DIR/sources.list"
fi

# trusted.gpg
if [ -e "$NEW_DIR/trusted.gpg" ] && [ "$FORCE" != 1 ]; then
  warn "$NEW_DIR/trusted.gpg exists, leaving it alone"
elif [ -f "$OLD_DIR/trusted.gpg" ]; then
  cp "$OLD_DIR/trusted.gpg" "$NEW_DIR/trusted.gpg"
  good "copied trusted.gpg from $OLD_DIR/ (verify: signing keys do get rotated)"
else
  warn "no $OLD_DIR/trusted.gpg to copy - you must supply $NEW_DIR/trusted.gpg"
fi

# ------------------------------------------------------------------- packages
head2 "regenerating $NEW_DIR/packages"
if [ -e "$NEW_DIR/packages" ] && [ "$FORCE" != 1 ]; then
  warn "$NEW_DIR/packages exists, leaving it alone"
elif [ ! -f "$OLD_DIR/packages" ]; then
  warn "no $OLD_DIR/packages to derive from - populate $NEW_DIR/packages manually"
else
  missing=()
  kept=0
  : > "$NEW_DIR/packages.tmp"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name=${line%%=*}
    ver=$(pkg_version "$NEW" "$name")
    if [ -n "$ver" ]; then
      printf '%s=%s\n' "$name" "$ver" >> "$NEW_DIR/packages.tmp"
      kept=$((kept+1))
    else
      missing+=("$name")
    fi
  done < "$OLD_DIR/packages"
  mv "$NEW_DIR/packages.tmp" "$NEW_DIR/packages"
  good "wrote $NEW_DIR/packages ($kept packages re-pinned for $NEW)"
  if [ ${#missing[@]} -gt 0 ]; then
    warn "${#missing[@]} package(s) from $OLD_DIR/packages are not in the $NEW repo and were dropped:"
    printf '        %s\n' "${missing[@]}"
  fi
fi

# ------------------------------------------------------------------ Dockerfile
head2 "creating $DOCKERFILE"
# Portable sed: BSD sed has no \b, so anchor on characters that actually occur.
# Dots are escaped so they are not treated as "any character".
esc() { printf '%s' "$1" | sed 's/\./\\./g'; }
FROM_ESC=$(esc "$FROM")
OLD_DIR_ESC=$(esc "$OLD_DIR")

# Order matters: rewrite the full version first (5.11.5 -> 5.12.0), so the
# remaining bare "5.11" occurrences are unambiguously minor-version references.
sed -e "s|$FROM_ESC|$NEW|g" \
    -e "s|$OLD_DIR_ESC/|$NEW_DIR/|g" \
    -e "s|\.$OLD_DIR_ESC\([[:space:]]\)|.$NEW_DIR\1|g" \
    -e "s|\.$OLD_DIR_ESC\$|.$NEW_DIR|" \
    "Dockerfile-$FROM" > "$DOCKERFILE"
good "wrote $DOCKERFILE (from Dockerfile-$FROM)"

# Anything still naming the old version is either a stale comment or a rewrite
# this script failed to make. Either way the human needs to look at it.
leftovers=$(grep -n "$OLD_DIR_ESC\|$FROM_ESC" "$DOCKERFILE" || true)
if [ -n "$leftovers" ]; then
  warn "lines still referencing $FROM/$OLD_DIR - review them:"
  printf '        %s\n' "$leftovers" | head -20
else
  good "no stale references to $FROM/$OLD_DIR remain"
fi

# version-suffixed hacks referenced by the new Dockerfile, e.g. hacks/foo.5.12
head2 "version-specific hack files"
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  if [ -f "$ref" ]; then
    good "$ref present"
  else
    old_ref=${ref%".$NEW_DIR"}".$OLD_DIR"
    if [ -f "$old_ref" ]; then
      cp "$old_ref" "$ref"
      good "created $ref (copied from $old_ref - review it)"
    else
      bad "$ref referenced by $DOCKERFILE but missing, and no $old_ref to copy"
    fi
  fi
done < <(grep -oE "hacks/[A-Za-z0-9._-]+\.$NEW_DIR" "$DOCKERFILE" | sort -u)

head2 "next steps"
cat <<EOF
  1. Review $DOCKERFILE - version-specific hacks rarely survive unchanged.
  2. Run the validator:      make validate VERSION=$NEW
  3. Build:                  make build TAG=$NEW
  4. Test:                   make test TAG=$NEW
EOF
[ -n "$DEB_CODENAME" ] && cat <<EOF

  Cumulus $NEW mirrors Debian $DEB_RELEASE ($DEB_CODENAME). Check the FROM line
  in $DOCKERFILE points at a matching $DEB_CODENAME base image; the validator
  reports how far the base image has drifted from the Cumulus snapshot.
EOF
