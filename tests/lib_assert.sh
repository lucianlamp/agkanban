#!/usr/bin/env bash
# Minimal dependency-free assertion harness. Each failed assert increments ASSERT_FAILS.
ASSERT_FAILS=0

assert_eq() { # actual expected label
  if [ "$1" = "$2" ]; then
    echo "ok: $3"
  else
    echo "FAIL: $3 (expected [$2], got [$1])"
    ASSERT_FAILS=$((ASSERT_FAILS + 1))
  fi
}

assert_contains() { # haystack needle label
  case "$1" in
    *"$2"*) echo "ok: $3" ;;
    *) echo "FAIL: $3 (missing [$2] in [$1])"; ASSERT_FAILS=$((ASSERT_FAILS + 1)) ;;
  esac
}

assert_not_contains() { # haystack needle label
  case "$1" in
    *"$2"*) echo "FAIL: $3 (unexpected [$2] in [$1])"; ASSERT_FAILS=$((ASSERT_FAILS + 1)) ;;
    *) echo "ok: $3" ;;
  esac
}

finish() {
  if [ "$ASSERT_FAILS" -eq 0 ]; then
    echo "ALL PASS"; exit 0
  else
    echo "$ASSERT_FAILS assertion(s) FAILED"; exit 1
  fi
}
