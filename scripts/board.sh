#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib/storage.sh"
source "$DIR/lib/agmsg.sh"

TEAM_OVERRIDE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --team) TEAM_OVERRIDE="$2"; shift 2 ;;
    *) echo "agkanban board: unexpected arg: $1" >&2; exit 2 ;;
  esac
done

ensure_db
agmsg_identity "${AGK_TYPE:-claude-code}" || true
team="${TEAM_OVERRIDE:-${AGK_TEAM:-}}"
[ -z "$team" ] && { echo "agkanban board: team unresolved (join agmsg or pass --team)" >&2; exit 1; }

echo "# board: $team"
for col in todo doing review done; do
  echo "## $col"
  db_exec "SELECT 'card-'||id||'  '||title||
                  CASE WHEN assignee IS NOT NULL THEN '  @'||assignee ELSE '' END
           FROM cards WHERE team='$(sql_escape "$team")' AND col='$col' ORDER BY id;"
done
