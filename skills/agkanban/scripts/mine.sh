#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib/storage.sh"
source "$DIR/lib/agmsg.sh"

TEAM_OVERRIDE=""; AGENT_OVERRIDE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --team)  TEAM_OVERRIDE="$2";  shift 2 ;;
    --agent) AGENT_OVERRIDE="$2"; shift 2 ;;
    *) echo "agkanban mine: unexpected arg: $1" >&2; exit 2 ;;
  esac
done

ensure_db
agmsg_identity || true
me="${AGENT_OVERRIDE:-${AGK_AGENT:-}}"
team="${TEAM_OVERRIDE:-${AGK_TEAM:-}}"
[ -z "$me" ] && { echo "agkanban mine: agent unresolved (join agmsg or pass --agent)" >&2; exit 1; }
[ -z "$team" ] && { echo "agkanban mine: team unresolved (join agmsg or pass --team)" >&2; exit 1; }

rows="$(db_exec "SELECT 'card-'||id||'  ['||col||']  '||title
         FROM cards
         WHERE team='$(sql_escape "$team")' AND assignee='$(sql_escape "$me")'
           AND col IN ('todo','doing','review')
         ORDER BY CASE col WHEN 'doing' THEN 0 WHEN 'review' THEN 1 ELSE 2 END, id;")"

echo "# mine: $me @ $team (open: todo/doing/review)"
if [ -z "$rows" ]; then
  echo "(no open cards)"
  exit 0
fi
printf '%s\n' "$rows"

# Call to action: this is a prompt to work the cards, not just report them.
cat <<'EOF'

→ ACT ON THESE NOW — do not just list or summarize them.
  RULE: before doing ANY work on a [todo] card assigned to you, CLAIM it first
  (claim moves it to doing and notifies the team it is in progress). Never start a
  todo card unclaimed. For each card:
  - read details first:  bash scripts/agkanban.sh show <id>
  - [todo]   claim BEFORE starting work:    bash scripts/agkanban.sh claim <id>
  - [doing]  keep going; when ready:         bash scripts/agkanban.sh review <id>
  - [review] perform the review, then:       bash scripts/agkanban.sh done <id>   (or report a blocker to the requester via agmsg)
EOF
