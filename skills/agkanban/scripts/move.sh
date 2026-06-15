#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib/storage.sh"
source "$DIR/lib/agmsg.sh"
source "$DIR/lib/events.sh"

TEAM_OVERRIDE=""; ID_ARG=""; TO_COL=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --team) TEAM_OVERRIDE="$2"; shift 2 ;;
    *) if [ -z "$ID_ARG" ]; then ID_ARG="$1"; elif [ -z "$TO_COL" ]; then TO_COL="$1"; else echo "agkanban move: unexpected arg: $1" >&2; exit 2; fi; shift ;;
  esac
done
num="$(card_num "$ID_ARG")" || exit 2
case "$TO_COL" in todo|doing|review|done) ;; *) echo "agkanban move: column must be todo|doing|review|done" >&2; exit 2 ;; esac

ensure_db
agmsg_identity || true
actor="${AGK_AGENT:-}"
team="${TEAM_OVERRIDE:-${AGK_TEAM:-}}"
[ -z "$team" ] && { echo "agkanban move: team unresolved (join agmsg or pass --team)" >&2; exit 1; }

row="$(db_exec "SELECT col,title,COALESCE(assignee,''),COALESCE(reviewer,''),COALESCE(creator,'')
                FROM cards WHERE id=$num AND team='$(sql_escape "$team")';")"
[ -z "$row" ] && { echo "agkanban move: card-$num not found in team $team" >&2; exit 1; }
IFS='|' read -r from_col title assignee reviewer creator <<EOF
$row
EOF

now="$(db_now)"
db_exec "UPDATE cards SET col='$TO_COL', updated_at='$now' WHERE id=$num AND team='$(sql_escape "$team")';
         INSERT INTO card_events (card_id,team,actor,from_col,to_col,at)
         VALUES ($num,'$(sql_escape "$team")',$(sql_val "$actor"),'$from_col','$TO_COL','$now');"

fire_transition "$team" "$actor" "$num" "$title" "$TO_COL" "$assignee" "$reviewer" "$creator"
[ "$TO_COL" = "done" ] && fire_unblock "$team" "$actor" "$num"
echo "card-$num: $from_col -> $TO_COL"
