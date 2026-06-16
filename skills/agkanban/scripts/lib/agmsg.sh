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

agmsg_session_id() {
  if [ -n "${AGK_SESSION_ID:-}" ]; then
    printf '%s' "$AGK_SESSION_ID"
  elif [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    printf '%s' "$CLAUDE_CODE_SESSION_ID"
  elif [ -n "${CODEX_THREAD_ID:-}" ]; then
    printf '%s' "$CODEX_THREAD_ID"
  fi
}

agmsg_identity_from_actas_lock() { # agmsg_home project type
  local home="$1" project="$2" type="$3"
  local sid lock_lib selected_team selected_agent team agent state
  sid="$(agmsg_session_id)"
  [ -n "$sid" ] || return 1
  [ -x "$home/scripts/identities.sh" ] || return 1
  lock_lib="$home/scripts/lib/actas-lock.sh"
  [ -f "$lock_lib" ] || return 1

  local SKILL_DIR="$home"
  # shellcheck disable=SC1090
  source "$lock_lib"

  while IFS=$'\t' read -r team agent; do
    [ -n "$team" ] || continue
    state="$(actas_lock_state "$team" "$agent" "$sid" 2>/dev/null || true)"
    [ "$state" = "mine" ] || continue
    if [ -n "${selected_agent:-}" ]; then
      return 1
    fi
    selected_team="$team"
    selected_agent="$agent"
  done < <(bash "$home/scripts/identities.sh" "$project" "$type" 2>/dev/null)

  [ -n "${selected_agent:-}" ] || return 1
  AGK_AGENT="$selected_agent"
  AGK_TEAM="$selected_team"
  return 0
}

# Identity resolution. On success, sets AGK_AGENT / AGK_TEAM and returns 0.
# - If AGK_AGENT/AGK_TEAM are already set in env, skips whoami (test/override seam).
# - Uses AGK_TYPE for agent type if set; otherwise omits it and lets whoami
#   auto-detect from the environment (codex for Codex, claude-code for Claude Code).
#   This allows the same script/hook to work correctly for both agents.
agmsg_identity() {
  if [ -n "${AGK_AGENT:-}" ] && [ -n "${AGK_TEAM:-}" ]; then return 0; fi
  local home out project type
  home="$(agmsg_home)" || return 1
  project="${AGKANBAN_PROJECT:-$(pwd)}"
  out="$(bash "$home/scripts/whoami.sh" "$project" ${AGK_TYPE:+"$AGK_TYPE"} 2>/dev/null)" || return 1
  AGK_AGENT="$(printf '%s\n' "$out" | sed -n 's/.*agent=\([^ ]*\).*/\1/p')"
  AGK_TEAM="$(printf '%s\n' "$out" | sed -n 's/.*teams=\([^, ]*\).*/\1/p')"
  if [ -n "$AGK_AGENT" ] && [ -n "$AGK_TEAM" ]; then return 0; fi
  type="$(printf '%s\n' "$out" | sed -n 's/.*type=\([^ ]*\).*/\1/p')"
  [ -n "$type" ] || type="${AGK_TYPE:-}"
  if [ -n "$type" ] && agmsg_identity_from_actas_lock "$home" "$project" "$type"; then
    return 0
  fi
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
