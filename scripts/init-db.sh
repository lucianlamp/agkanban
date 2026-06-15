#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
DB="$(agkanban_db)"
mkdir -p "$(dirname "$DB")"

if [ ! -f "$DB" ]; then
  sqlite3 "$DB" <<'SQL'
PRAGMA journal_mode=WAL;

CREATE TABLE cards (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  team       TEXT NOT NULL,
  title      TEXT NOT NULL,
  col        TEXT NOT NULL DEFAULT 'todo',
  assignee   TEXT,
  reviewer   TEXT,
  creator    TEXT,
  blocked_by INTEGER,
  body       TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE card_events (
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  card_id  INTEGER NOT NULL,
  team     TEXT NOT NULL,
  actor    TEXT,
  from_col TEXT,
  to_col   TEXT,
  at       TEXT NOT NULL
);

CREATE INDEX idx_cards_team_col ON cards(team, col);
CREATE INDEX idx_cards_assignee ON cards(team, assignee);
SQL
fi
