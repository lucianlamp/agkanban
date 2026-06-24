#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib/storage.sh"
source "$DIR/lib/agmsg.sh"

TEAM_OVERRIDE=""; AGENT_OVERRIDE=""; ID_ARG=""
TITLE=""; ASSIGNEE=""; REVIEWER=""; BODY=""
TITLE_SET=0; ASSIGNEE_SET=0; REVIEWER_SET=0; BODY_SET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --title)    TITLE="$2";    TITLE_SET=1;    shift 2 ;;
    --assignee) ASSIGNEE="$2"; ASSIGNEE_SET=1; shift 2 ;;
    --reviewer) REVIEWER="$2"; REVIEWER_SET=1; shift 2 ;;
    --body)     BODY="$2";     BODY_SET=1;     shift 2 ;;
    --team)     TEAM_OVERRIDE="$2";  shift 2 ;;
    --agent)    AGENT_OVERRIDE="$2"; shift 2 ;;
    *) if [ -z "$ID_ARG" ]; then ID_ARG="$1"; else echo "agkanban edit: unexpected arg: $1" >&2; exit 2; fi; shift ;;
  esac
done
num="$(card_num "$ID_ARG")" || exit 2
[ "$TITLE_SET" = 1 ] && [ -z "$TITLE" ] && { echo "agkanban edit: --title cannot be empty" >&2; exit 2; }
if [ "$TITLE_SET$ASSIGNEE_SET$REVIEWER_SET$BODY_SET" = "0000" ]; then
  echo "agkanban edit: nothing to update (pass --title/--assignee/--reviewer/--body)" >&2
  exit 2
fi

ensure_db
agmsg_identity || true
team="${TEAM_OVERRIDE:-${AGK_TEAM:-}}"
[ -z "$team" ] && { echo "agkanban edit: team unresolved (join agmsg or pass --team)" >&2; exit 1; }
me="${AGENT_OVERRIDE:-${AGK_AGENT:-}}"
[ -z "$me" ] && { echo "agkanban edit: agent unresolved (join agmsg or pass --agent) — needed to verify permission" >&2; exit 1; }
t="$(sql_escape "$team")"

# Authorization: the creator or the assignee may edit (cooperative guard, identity from
# agmsg whoami). The 'Y' marker column distinguishes "no such card" from empty fields.
got="$(db_exec "SELECT 'Y', COALESCE(creator,''), COALESCE(assignee,'') FROM cards WHERE id=$num AND team='$t';")"
[ -z "$got" ] && { echo "agkanban edit: card-$num not found in team $team" >&2; exit 1; }
IFS='|' read -r _ creator assignee <<EOF
$got
EOF
if [ -n "$creator" ] && [ "$me" != "$creator" ] && [ "$me" != "$assignee" ]; then
  echo "agkanban edit: only the creator ($creator) or assignee (${assignee:-none}) can edit card-$num (you are $me)" >&2
  exit 1
fi

# Build the SET clause from only the fields that were passed.
# An empty value clears the field (NULL) — except title, which must be non-empty.
sets=""
append() { if [ -n "$sets" ]; then sets="$sets, "; fi; sets="$sets$1=$2"; }
[ "$TITLE_SET" = 1 ]    && append title    "$(sql_val "$TITLE")"
[ "$ASSIGNEE_SET" = 1 ] && append assignee "$(sql_val "$ASSIGNEE")"
[ "$REVIEWER_SET" = 1 ] && append reviewer "$(sql_val "$REVIEWER")"
[ "$BODY_SET" = 1 ]     && append body     "$(sql_val "$BODY")"

now="$(db_now)"
changed="$(db_exec "UPDATE cards SET $sets, updated_at='$now' WHERE id=$num AND team='$t'; SELECT changes();")"
if [ "$changed" = "0" ]; then
  echo "agkanban edit: card-$num not found in team $team" >&2
  exit 1
fi
echo "card-$num updated"
