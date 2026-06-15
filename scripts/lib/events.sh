#!/usr/bin/env bash
# events.sh — 列遷移に対応する通知の発火。
# storage.sh と agmsg.sh が先に source されている前提。

# 直接遷移の通知。
fire_transition() { # team actor card_id title to_col assignee reviewer creator
  local team="$1" actor="$2" card_id="$3" title="$4" to_col="$5" \
        assignee="$6" reviewer="$7" creator="$8"
  local ref="card-$card_id" rcpt
  case "$to_col" in
    doing)
      agmsg_send "$team" "$actor" "$assignee" "[agkanban] $ref 着手依頼: $title" ;;
    review)
      rcpt="$reviewer"; [ -z "$rcpt" ] && rcpt="$creator"
      agmsg_send "$team" "$actor" "$rcpt" "[agkanban] $ref review待ち: $title" ;;
    done)
      agmsg_send "$team" "$actor" "$creator" "[agkanban] $ref 完了: $title"
      if [ -n "$assignee" ] && [ "$assignee" != "$creator" ]; then
        agmsg_send "$team" "$actor" "$assignee" "[agkanban] $ref 完了: $title"
      fi ;;
  esac
}

# 依存解消通知: done になった card に blocked_by で紐づく待ちカードの assignee へ。
fire_unblock() { # team actor done_id
  local team="$1" actor="$2" done_id="$3" rows dep_id dep_assignee
  rows="$(db_exec "SELECT id, COALESCE(assignee,'') FROM cards WHERE team='$(sql_escape "$team")' AND blocked_by=$done_id;")"
  [ -z "$rows" ] && return 0
  while IFS='|' read -r dep_id dep_assignee; do
    [ -z "$dep_id" ] && continue
    agmsg_send "$team" "$actor" "$dep_assignee" \
      "[agkanban] card-$dep_id のブロック解除（card-$done_id 完了）"
  done <<EOF
$rows
EOF
}
