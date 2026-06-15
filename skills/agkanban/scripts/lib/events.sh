#!/usr/bin/env bash
# events.sh — fire notifications for column transitions.
# Assumes storage.sh and agmsg.sh are sourced first.

# Direct transition notification.
fire_transition() { # team actor card_id title to_col assignee reviewer creator
  local team="$1" actor="$2" card_id="$3" title="$4" to_col="$5" \
        assignee="$6" reviewer="$7" creator="$8"
  local ref="card-$card_id" rcpt
  case "$to_col" in
    doing)
      agmsg_send "$team" "$actor" "$assignee" "[agkanban] $ref start requested: $title" ;;
    review)
      rcpt="$reviewer"; [ -z "$rcpt" ] && rcpt="$creator"
      agmsg_send "$team" "$actor" "$rcpt" "[agkanban] $ref review requested: $title" ;;
    done)
      agmsg_send "$team" "$actor" "$creator" "[agkanban] $ref done: $title"
      if [ -n "$assignee" ] && [ "$assignee" != "$creator" ]; then
        agmsg_send "$team" "$actor" "$assignee" "[agkanban] $ref done: $title"
      fi ;;
  esac
}

# Unblock notification: sent to the assignee of cards waiting on the card that just finished.
fire_unblock() { # team actor done_id
  local team="$1" actor="$2" done_id="$3" rows dep_id dep_assignee
  rows="$(db_exec "SELECT id, COALESCE(assignee,'') FROM cards WHERE team='$(sql_escape "$team")' AND blocked_by=$done_id;")"
  [ -z "$rows" ] && return 0
  while IFS='|' read -r dep_id dep_assignee; do
    [ -z "$dep_id" ] && continue
    agmsg_send "$team" "$actor" "$dep_assignee" \
      "[agkanban] card-$dep_id unblocked (card-$done_id done)"
  done <<EOF
$rows
EOF
}
