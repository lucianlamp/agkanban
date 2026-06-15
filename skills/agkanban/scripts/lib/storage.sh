#!/usr/bin/env bash
# storage.sh — board.db のパス解決と DB 実行ヘルパ。
# 解決順: AGKANBAN_STORAGE_PATH(env) > 既定 <skill>/db

agkanban_storage_dir() {
  if [ -n "${AGKANBAN_STORAGE_PATH:-}" ]; then
    printf '%s' "${AGKANBAN_STORAGE_PATH%/}"
    return
  fi
  local lib_dir skill_root
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  skill_root="$(cd "$lib_dir/../.." && pwd)"   # lib -> scripts -> skill root
  printf '%s/db' "$skill_root"
}

agkanban_db() { printf '%s/board.db' "$(agkanban_storage_dir)"; }

db_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

# 空なら NULL、それ以外は 'escaped' を返す（SQL リテラル生成用）
sql_val() {
  if [ -z "${1:-}" ]; then printf 'NULL'; else printf "'%s'" "$(sql_escape "$1")"; fi
}

# 1 回の sqlite3 プロセスで SQL を実行（複数文は同一接続 → changes() が有効）
db_exec() { sqlite3 -batch "$(agkanban_db)" "$1"; }

# DB が無ければ init-db.sh で作る
ensure_db() {
  local db; db="$(agkanban_db)"
  if [ ! -f "$db" ]; then
    mkdir -p "$(dirname "$db")"
    bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../init-db.sh"
  fi
}

# "card-12" / "12" を 12 に正規化。非数値は stderr + return 1
card_num() {
  local raw="${1#card-}"
  case "$raw" in
    ''|*[!0-9]*) echo "agkanban: invalid card id: $1" >&2; return 1 ;;
  esac
  printf '%s' "$raw"
}
