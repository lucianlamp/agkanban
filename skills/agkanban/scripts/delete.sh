#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib/storage.sh"
source "$DIR/lib/agmsg.sh"

TEAM_OVERRIDE=""; ID_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --team) TEAM_OVERRIDE="$2"; shift 2 ;;
    *) if [ -z "$ID_ARG" ]; then ID_ARG="$1"; else echo "agkanban delete: unexpected arg: $1" >&2; exit 2; fi; shift ;;
  esac
done
num="$(card_num "$ID_ARG")" || exit 2

ensure_db
agmsg_identity || true
team="${TEAM_OVERRIDE:-${AGK_TEAM:-}}"
[ -z "$team" ] && { echo "agkanban delete: team unresolved (join agmsg or pass --team)" >&2; exit 1; }
t="$(sql_escape "$team")"

# Delete the card; changes() reports whether it existed (same connection).
changed="$(db_exec "DELETE FROM cards WHERE id=$num AND team='$t'; SELECT changes();")"
if [ "$changed" = "0" ]; then
  echo "agkanban delete: card-$num not found in team $team" >&2
  exit 1
fi

# Clean up the card's event log and clear any dangling dependency references.
db_exec "DELETE FROM card_events WHERE card_id=$num AND team='$t';
         UPDATE cards SET blocked_by=NULL WHERE blocked_by=$num AND team='$t';"
echo "card-$num deleted"
