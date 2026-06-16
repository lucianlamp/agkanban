#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib/storage.sh"
source "$DIR/lib/agmsg.sh"

TEAM_OVERRIDE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --team) TEAM_OVERRIDE="$2"; shift 2 ;;
    *) echo "agkanban mine: unexpected arg: $1" >&2; exit 2 ;;
  esac
done

ensure_db
agmsg_identity || true
me="${AGK_AGENT:-}"
team="${TEAM_OVERRIDE:-${AGK_TEAM:-}}"
[ -z "$me" ] && { echo "agkanban mine: agent unresolved (join agmsg)" >&2; exit 1; }
[ -z "$team" ] && { echo "agkanban mine: team unresolved (join agmsg or pass --team)" >&2; exit 1; }

echo "# mine: $me @ $team (open: todo/doing/review)"
db_exec "SELECT 'card-'||id||'  ['||col||']  '||title
         FROM cards
         WHERE team='$(sql_escape "$team")' AND assignee='$(sql_escape "$me")'
           AND col IN ('todo','doing','review')
         ORDER BY CASE col WHEN 'doing' THEN 0 WHEN 'review' THEN 1 ELSE 2 END, id;"
