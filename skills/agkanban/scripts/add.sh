#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib/storage.sh"
source "$DIR/lib/agmsg.sh"

TITLE=""; ASSIGNEE=""; REVIEWER=""; BODY=""; TEAM_OVERRIDE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --assignee) ASSIGNEE="$2"; shift 2 ;;
    --reviewer) REVIEWER="$2"; shift 2 ;;
    --body)     BODY="$2"; shift 2 ;;
    --team)     TEAM_OVERRIDE="$2"; shift 2 ;;
    *) if [ -z "$TITLE" ]; then TITLE="$1"; shift; else echo "agkanban add: unexpected arg: $1" >&2; exit 2; fi ;;
  esac
done
[ -z "$TITLE" ] && { echo "agkanban add: title required" >&2; exit 2; }

ensure_db
agmsg_identity || true   # 未解決でも creator 空で続行可
creator="${AGK_AGENT:-}"
team="${TEAM_OVERRIDE:-${AGK_TEAM:-}}"
[ -z "$team" ] && { echo "agkanban add: team unresolved (join agmsg or pass --team)" >&2; exit 1; }

now="$(db_now)"
id="$(db_exec "INSERT INTO cards (team,title,col,assignee,reviewer,creator,body,created_at,updated_at)
         VALUES ('$(sql_escape "$team")','$(sql_escape "$TITLE")','todo',
                 $(sql_val "$ASSIGNEE"),$(sql_val "$REVIEWER"),$(sql_val "$creator"),
                 $(sql_val "$BODY"),'$now','$now');
         SELECT last_insert_rowid();")"
echo "card-$id added to $team (todo)"
