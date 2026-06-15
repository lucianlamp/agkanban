#!/usr/bin/env bash
# storage.sh — board.db path resolution and DB exec helpers.
# Resolution order: AGKANBAN_STORAGE_PATH(env) > default <skill>/db

agkanban_storage_dir() {
  if [ -n "${AGKANBAN_STORAGE_PATH:-}" ]; then
    printf '%s' "${AGKANBAN_STORAGE_PATH%/}"
    return
  fi
  local lib_dir skill_root
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  skill_root="$(cd "$lib_dir/../.." && pwd)"   # lib → scripts → skill root
  printf '%s/db' "$skill_root"
}

agkanban_db() { printf '%s/board.db' "$(agkanban_storage_dir)"; }

db_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

# Returns NULL for empty, or 'escaped' for non-empty (SQL literal generation)
sql_val() {
  if [ -z "${1:-}" ]; then printf 'NULL'; else printf "'%s'" "$(sql_escape "$1")"; fi
}

# Run SQL in a single sqlite3 process (multiple statements share one connection → changes() works)
db_exec() { sqlite3 -batch "$(agkanban_db)" "$1"; }

# Create DB via init-db.sh if it does not exist
ensure_db() {
  local db; db="$(agkanban_db)"
  if [ ! -f "$db" ]; then
    mkdir -p "$(dirname "$db")"
    bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../init-db.sh"
  fi
}

# Normalize "card-12" / "12" to 12. Non-numeric input prints to stderr and returns 1.
card_num() {
  local raw="${1#card-}"
  case "$raw" in
    ''|*[!0-9]*) echo "agkanban: invalid card id: $1" >&2; return 1 ;;
  esac
  printf '%s' "$raw"
}
