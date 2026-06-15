#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib/storage.sh"
source "$DIR/lib/agmsg.sh"

TEAM_OVERRIDE=""; ID_ARG=""; BY_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --by)   BY_ARG="$2"; shift 2 ;;
    --team) TEAM_OVERRIDE="$2"; shift 2 ;;
    *) if [ -z "$ID_ARG" ]; then ID_ARG="$1"; else echo "agkanban block: unexpected arg: $1" >&2; exit 2; fi; shift ;;
  esac
done
num="$(card_num "$ID_ARG")" || exit 2
[ -z "$BY_ARG" ] && { echo "agkanban block: --by <id> required" >&2; exit 2; }
by="$(card_num "$BY_ARG")" || exit 2

ensure_db
agmsg_identity || true
team="${TEAM_OVERRIDE:-${AGK_TEAM:-}}"
[ -z "$team" ] && { echo "agkanban block: team unresolved (join agmsg or pass --team)" >&2; exit 1; }

now="$(db_now)"
changed="$(db_exec "UPDATE cards SET blocked_by=$by, updated_at='$now'
                    WHERE id=$num AND team='$(sql_escape "$team")'; SELECT changes();")"
[ "$changed" = "0" ] && { echo "agkanban block: card-$num not found in team $team" >&2; exit 1; }
echo "card-$num blocked by card-$by"
