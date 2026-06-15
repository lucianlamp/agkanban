#!/usr/bin/env bash
# SessionStart hook for agkanban.
#
# Surfaces the current agent's assigned cards (doing/review) at session start,
# so each agent automatically sees its board without being asked.
#
# Stays SILENT (no output, exit 0) when:
#   - the skill scripts are missing,
#   - identity can't be resolved (project not joined to an agmsg team), or
#   - the agent has no in-progress cards.
# This keeps it quiet in projects that don't use agkanban/agmsg.
#
# On success it prints plain text to stdout, which Claude Code injects into the
# session as additional context (same mechanism agmsg's session-start hook uses).
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # hooks -> skill root
AGK="$SKILL_DIR/scripts/agkanban.sh"
[ -f "$AGK" ] || exit 0

# No-arg agkanban == "my cards". Non-zero exit means identity unresolved → quiet.
out="$(bash "$AGK" 2>/dev/null)" || exit 0

# Count actual card rows (header line has no "card-"). No cards → quiet.
n="$(printf '%s\n' "$out" | grep -c 'card-')" || n=0
[ "${n:-0}" -eq 0 ] && exit 0

printf 'agkanban — あなたの担当カード（セッション開始時の自動確認）:\n%s\n' "$out"
exit 0
