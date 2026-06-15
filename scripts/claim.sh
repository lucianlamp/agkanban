#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib/storage.sh"
source "$DIR/lib/agmsg.sh"
source "$DIR/lib/events.sh"

TEAM_OVERRIDE=""; ID_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --team) TEAM_OVERRIDE="$2"; shift 2 ;;
    *) if [ -z "$ID_ARG" ]; then ID_ARG="$1"; else echo "agkanban claim: unexpected arg: $1" >&2; exit 2; fi; shift ;;
  esac
done
num="$(card_num "$ID_ARG")" || exit 2

ensure_db
agmsg_identity "${AGK_TYPE:-claude-code}" || true
me="${AGK_AGENT:-}"
team="${TEAM_OVERRIDE:-${AGK_TEAM:-}}"
[ -z "$me" ] && { echo "agkanban claim: agent unresolved (join agmsg)" >&2; exit 1; }
[ -z "$team" ] && { echo "agkanban claim: team unresolved (join agmsg or pass --team)" >&2; exit 1; }

# 遷移前情報（タイトル・元列）。存在しないなら not found。
row="$(db_exec "SELECT col,title,COALESCE(reviewer,''),COALESCE(creator,'') FROM cards WHERE id=$num AND team='$(sql_escape "$team")';")"
[ -z "$row" ] && { echo "agkanban claim: card-$num not found in team $team" >&2; exit 1; }
IFS='|' read -r from_col title reviewer creator <<EOF
$row
EOF

# 原子的 claim: 同一接続で UPDATE と changes() を実行。
now="$(db_now)"
changed="$(db_exec "UPDATE cards SET assignee='$(sql_escape "$me")', col='doing', updated_at='$now'
                    WHERE id=$num AND team='$(sql_escape "$team")' AND (assignee IS NULL OR assignee='$(sql_escape "$me")');
                    SELECT changes();")"
if [ "$changed" = "0" ]; then
  echo "agkanban: card-$num already claimed by someone else" >&2
  exit 1
fi

db_exec "INSERT INTO card_events (card_id,team,actor,from_col,to_col,at)
         VALUES ($num,'$(sql_escape "$team")','$(sql_escape "$me")','$from_col','doing','$now');"
fire_transition "$team" "$me" "$num" "$title" "doing" "$me" "$reviewer" "$creator"
echo "card-$num claimed by $me (doing)"
