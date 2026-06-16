#!/usr/bin/env bash
# storage.sh — board.db path resolution and DB exec helpers.
# Resolution order: AGKANBAN_STORAGE_PATH(env) > default ~/.agkanban
#
# The board lives OUTSIDE the skill directory so reinstalling/updating the skill (which
# replaces the skill dir) never destroys your cards. Older versions stored it in
# <skill>/db; ensure_db migrates that legacy board on first run if it is still present.

agkanban_storage_dir() {
  if [ -n "${AGKANBAN_STORAGE_PATH:-}" ]; then
    printf '%s' "${AGKANBAN_STORAGE_PATH%/}"
    return
  fi
  printf '%s/.agkanban' "${HOME:?HOME is required}"
}

agkanban_db() { printf '%s/board.db' "$(agkanban_storage_dir)"; }

# Legacy in-skill board location (pre ~/.agkanban default), for one-time migration.
agkanban_legacy_db() {
  local lib_dir skill_root
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  skill_root="$(cd "$lib_dir/../.." && pwd)"   # lib → scripts → skill root
  printf '%s/db/board.db' "$skill_root"
}

db_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

# Returns NULL for empty, or 'escaped' for non-empty (SQL literal generation)
sql_val() {
  if [ -z "${1:-}" ]; then printf 'NULL'; else printf "'%s'" "$(sql_escape "$1")"; fi
}

# Run SQL in a single sqlite3 process (multiple statements share one connection → changes() works)
db_exec() { sqlite3 -batch "$(agkanban_db)" "$1"; }

# Create DB via init-db.sh if it does not exist. If a legacy in-skill board exists and the
# new location does not, migrate it (move) so existing cards survive the relocation.
ensure_db() {
  local db legacy; db="$(agkanban_db)"
  [ -f "$db" ] && return 0
  mkdir -p "$(dirname "$db")"
  legacy="$(agkanban_legacy_db)"
  if [ -f "$legacy" ] && [ "$legacy" != "$db" ]; then
    mv "$legacy" "$db" 2>/dev/null && return 0
  fi
  bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../init-db.sh"
}

# Normalize "card-12" / "12" to 12. Non-numeric input prints to stderr and returns 1.
card_num() {
  local raw="${1#card-}"
  case "$raw" in
    ''|*[!0-9]*) echo "agkanban: invalid card id: $1" >&2; return 1 ;;
  esac
  printf '%s' "$raw"
}
