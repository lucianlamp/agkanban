#!/usr/bin/env bash
# agmsg.sh — agmsg discovery, identity resolution, send wrapper.
# Assumes storage.sh is sourced first (db_exec etc. are not used here).

# Locate the agmsg installation (returns 1 if not found)
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

# Identity resolution. On success, sets AGK_AGENT / AGK_TEAM and returns 0.
# - If AGK_AGENT/AGK_TEAM are already set in env, skips whoami (test/override seam).
# - Uses AGK_TYPE for agent type if set; otherwise omits it and lets whoami
#   auto-detect from the environment (codex for Codex, claude-code for Claude Code).
#   This allows the same script/hook to work correctly for both agents.
agmsg_identity() {
  if [ -n "${AGK_AGENT:-}" ] && [ -n "${AGK_TEAM:-}" ]; then return 0; fi
  local home out
  home="$(agmsg_home)" || return 1
  out="$(bash "$home/scripts/whoami.sh" "$(pwd)" ${AGK_TYPE:+"$AGK_TYPE"} 2>/dev/null)" || return 1
  AGK_AGENT="$(printf '%s\n' "$out" | sed -n 's/.*agent=\([^ ]*\).*/\1/p')"
  AGK_TEAM="$(printf '%s\n' "$out" | sed -n 's/.*teams=\([^, ]*\).*/\1/p')"
  [ -n "$AGK_AGENT" ] && [ -n "$AGK_TEAM" ]
}

# Send notification. Skip if recipient is empty or equals sender.
# Uses AGMSG_SEND_CMD if set, otherwise agmsg's send.sh.
# On agmsg absence or failure, warns and swallows the error (does not abort state transition).
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
