#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib/storage.sh"
source "$DIR/lib/agmsg.sh"

TEAM_OVERRIDE=""; ID_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --team) TEAM_OVERRIDE="$2"; shift 2 ;;
    *) if [ -z "$ID_ARG" ]; then ID_ARG="$1"; else echo "agkanban show: unexpected arg: $1" >&2; exit 2; fi; shift ;;
  esac
done
num="$(card_num "$ID_ARG")" || exit 2

ensure_db
agmsg_identity || true
team="${TEAM_OVERRIDE:-${AGK_TEAM:-}}"
[ -z "$team" ] && { echo "agkanban show: team unresolved (join agmsg or pass --team)" >&2; exit 1; }

row="$(db_exec "SELECT 'card-'||id||'  ['||col||']  '||title||char(10)||
                       'assignee: '||COALESCE(assignee,'-')||'   reviewer: '||COALESCE(reviewer,'-')||
                       '   creator: '||COALESCE(creator,'-')||
                       CASE WHEN blocked_by IS NOT NULL THEN char(10)||'blocked_by: card-'||blocked_by ELSE '' END||
                       CASE WHEN body IS NOT NULL THEN char(10)||char(10)||body ELSE '' END
                FROM cards WHERE id=$num AND team='$(sql_escape "$team")';")"
[ -z "$row" ] && { echo "agkanban show: card-$num not found in team $team" >&2; exit 1; }
printf '%s\n\n' "$row"
echo "## history"
db_exec "SELECT at||'  '||COALESCE(actor,'?')||'  '||from_col||'->'||to_col
         FROM card_events WHERE card_id=$num AND team='$(sql_escape "$team")' ORDER BY id;"
