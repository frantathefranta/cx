#!/usr/bin/env bash
# Minimal assertion helpers shared by the test scripts.

PASS=0
FAIL=0
SKIP=0
FAILED_TESTS=()

if [ -t 1 ]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_RESET=""
fi

CONTAINER_CLI="${CONTAINER_CLI:-docker}"

ok()   { PASS=$((PASS+1)); printf '  %sok%s   %s\n' "$C_GREEN" "$C_RESET" "$1"; }
nok()  { FAIL=$((FAIL+1)); FAILED_TESTS+=("$1"); printf '  %sFAIL%s %s\n' "$C_RED" "$C_RESET" "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }
skip() { SKIP=$((SKIP+1)); printf '  %sskip%s %s%s\n' "$C_YELLOW" "$C_RESET" "$1" "${2:+ ($2)}"; }
section() { printf '\n== %s ==\n' "$1"; }

# assert_eq <description> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "expected '$2', got '$3'"; fi
}

# assert_contains <description> <haystack> <needle>
assert_contains() {
  case "$2" in
    *"$3"*) ok "$1" ;;
    *)      nok "$1" "expected to contain '$3', got: $(printf '%s' "$2" | head -c 200)" ;;
  esac
}

# assert_cmd <description> <command...>  -- passes if command exits 0
assert_cmd() {
  local desc="$1"; shift
  local out
  if out=$("$@" 2>&1); then ok "$desc"; else nok "$desc" "$(printf '%s' "$out" | tail -3)"; fi
}

summary() {
  printf '\n---------------------------------------------\n'
  printf 'passed: %d   failed: %d   skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
  if [ "$FAIL" -gt 0 ]; then
    printf '%sfailing tests:%s\n' "$C_RED" "$C_RESET"
    for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
    return 1
  fi
  return 0
}
