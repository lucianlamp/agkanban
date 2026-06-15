#!/usr/bin/env bash
# agmsg.sh — agmsg の探索・識別解決・送信ラッパ。
# storage.sh が先に source されている前提（db_exec 等は使わない）。

# agmsg のインストール先を探索（見つからなければ return 1）
agmsg_home() {
  if [ -n "${AGMSG_HOME:-}" ] && [ -f "$AGMSG_HOME/scripts/whoami.sh" ]; then
    printf '%s' "$AGMSG_HOME"; return 0
  fi
  local lib_dir skill_root c
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  skill_root="$(cd "$lib_dir/../.." && pwd)"
  for c in "$skill_root/../agmsg" "$HOME/.agents/skills/agmsg" "$HOME/.claude/skills/agmsg"; do
    if [ -f "$c/scripts/whoami.sh" ]; then (cd "$c" && pwd); return 0; fi
  done
  return 1
}

# 識別解決。成功で AGK_AGENT / AGK_TEAM を設定し return 0。
# - 既に AGK_AGENT/AGK_TEAM が env で設定済みなら whoami を呼ばない（テスト/override seam）。
# - agent type は AGK_TYPE が設定されていればそれを使い、未設定なら whoami に渡さず
#   環境から自動判定させる（Codex なら codex、Claude Code なら claude-code）。
#   これにより同一スクリプト/hook が両エージェントで正しく動く。
agmsg_identity() {
  if [ -n "${AGK_AGENT:-}" ] && [ -n "${AGK_TEAM:-}" ]; then return 0; fi
  local home out
  home="$(agmsg_home)" || return 1
  out="$(bash "$home/scripts/whoami.sh" "$(pwd)" ${AGK_TYPE:+"$AGK_TYPE"} 2>/dev/null)" || return 1
  AGK_AGENT="$(printf '%s\n' "$out" | sed -n 's/.*agent=\([^ ]*\).*/\1/p')"
  AGK_TEAM="$(printf '%s\n' "$out" | sed -n 's/.*teams=\([^, ]*\).*/\1/p')"
  [ -n "$AGK_AGENT" ] && [ -n "$AGK_TEAM" ]
}

# 通知送信。宛先が空 or 送信者自身ならスキップ。
# AGMSG_SEND_CMD があればそれを使い、無ければ agmsg の send.sh。
# agmsg 不在/失敗時は警告を出して握りつぶす（状態遷移は止めない）。
agmsg_send() { # team from to body
  local team="$1" from="$2" to="$3" body="$4"
  [ -z "$to" ] && return 0
  [ "$to" = "$from" ] && return 0
  if [ -n "${AGMSG_SEND_CMD:-}" ]; then
    "$AGMSG_SEND_CMD" "$team" "$from" "$to" "$body" \
      || echo "agkanban: notify to $to failed (skipped)" >&2
    return 0
  fi
  local home
  if ! home="$(agmsg_home)"; then
    echo "agkanban: agmsg not found; skipped notify to $to" >&2
    return 0
  fi
  bash "$home/scripts/send.sh" "$team" "$from" "$to" "$body" >/dev/null 2>&1 \
    || echo "agkanban: notify to $to failed (skipped)" >&2
  return 0
}
