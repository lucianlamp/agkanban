#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib/storage.sh"
source "$DIR/lib/agmsg.sh"

TEAM_OVERRIDE=""; AGENT_OVERRIDE=""; ID_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --team)  TEAM_OVERRIDE="$2";  shift 2 ;;
    --agent) AGENT_OVERRIDE="$2"; shift 2 ;;
    *) if [ -z "$ID_ARG" ]; then ID_ARG="$1"; else echo "agkanban delete: unexpected arg: $1" >&2; exit 2; fi; shift ;;
  esac
done
num="$(card_num "$ID_ARG")" || exit 2

ensure_db
agmsg_identity || true
team="${TEAM_OVERRIDE:-${AGK_TEAM:-}}"
[ -z "$team" ] && { echo "agkanban delete: team unresolved (join agmsg or pass --team)" >&2; exit 1; }
me="${AGENT_OVERRIDE:-${AGK_AGENT:-}}"
[ -z "$me" ] && { echo "agkanban delete: agent unresolved (join agmsg or pass --agent) — needed to verify you are the creator" >&2; exit 1; }
t="$(sql_escape "$team")"

# Authorization: only the card's creator may delete it (cooperative guard, identity
# from agmsg whoami). The 'Y' marker column distinguishes "no such card" from empty fields.
got="$(db_exec "SELECT 'Y', COALESCE(creator,'') FROM cards WHERE id=$num AND team='$t';")"
[ -z "$got" ] && { echo "agkanban delete: card-$num not found in team $team" >&2; exit 1; }
IFS='|' read -r _ creator <<EOF
$got
EOF
if [ -n "$creator" ] && [ "$creator" != "$me" ]; then
  echo "agkanban delete: only the creator ($creator) can delete card-$num (you are $me)" >&2
  exit 1
fi

# Delete the card, its event log, and clear any dangling dependency references.
db_exec "DELETE FROM cards WHERE id=$num AND team='$t';
         DELETE FROM card_events WHERE card_id=$num AND team='$t';
         UPDATE cards SET blocked_by=NULL WHERE blocked_by=$num AND team='$t';"
echo "card-$num deleted"
