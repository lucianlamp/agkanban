#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

# Windows PowerShell shim handoff: when called as `--argv-file <path>`, the file holds
# one base64-encoded argument per line (UTF-8 safe across the PowerShell->bash boundary).
# Decode them into the positional parameters, then dispatch normally.
if [ "${1:-}" = "--argv-file" ]; then
  argv_file="${2:?--argv-file needs a path}"; shift 2
  decoded=()
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [ -z "$line" ] && continue
    decoded+=("$(printf '%s' "$line" | base64 -d)")
  done < "$argv_file"
  if [ "${#decoded[@]}" -gt 0 ]; then set -- "${decoded[@]}" "$@"; fi
fi

# No args (or only identity flags) = your assigned cards (doing/review).
# Collect leading --agent/--team flags so `agkanban --agent alice` dispatches to mine.
_MINE_FLAGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent|--team) _MINE_FLAGS+=("$1" "$2"); shift 2 ;;
    *) break ;;
  esac
done
if [ "$#" -eq 0 ]; then
  exec bash "$DIR/mine.sh" "${_MINE_FLAGS[@]+"${_MINE_FLAGS[@]}"}"
fi

sub="$1"; shift
case "$sub" in
  board)  exec bash "$DIR/board.sh" "$@" ;;
  add)    exec bash "$DIR/add.sh" "$@" ;;
  claim)  exec bash "$DIR/claim.sh" "$@" ;;
  show)   exec bash "$DIR/show.sh" "$@" ;;
  block)  exec bash "$DIR/block.sh" "$@" ;;
  edit)   exec bash "$DIR/edit.sh" "$@" ;;
  delete|rm) exec bash "$DIR/delete.sh" "$@" ;;
  # Semantic transition verbs (thin wrappers over move <id> <col>). Append column name and delegate to move.
  review) exec bash "$DIR/move.sh" "$@" review ;;
  done)   exec bash "$DIR/move.sh" "$@" done ;;
  reopen) exec bash "$DIR/move.sh" "$@" todo ;;
  # Generic fallback (move to any column).
  move)   exec bash "$DIR/move.sh" "$@" ;;
  mine)
    echo "agkanban: 'mine' is the default — just run 'agkanban' with no arguments." >&2
    exit 2 ;;
  -h|--help|help)
    cat <<'USAGE'
agkanban — kanban task management paired with agmsg
  agkanban                       your open cards (todo/doing/review)
  agkanban board                 full team board
  agkanban add "<title>" [--assignee X] [--reviewer Y] [--body "..."] [--team T]
  agkanban claim <id> [--team T] [--agent A]    claim (doing, assign to self)
  agkanban review <id> [--team T]               request review (move to review)
  agkanban done <id> [--team T]                 mark done
  agkanban reopen <id> [--team T]               reopen (back to todo)
  agkanban move <id> <todo|doing|review|done> [--team T]   generic (any column)
  agkanban show <id> [--team T]
  agkanban block <id> --by <id2> [--team T]
  agkanban edit <id> [--title T] [--assignee X] [--reviewer Y] [--body "..."] [--team T] [--agent A]
  agkanban delete <id> [--team T] [--agent A]   permanently delete a card (alias: rm)
  agkanban [--agent A]                          your open cards (no args; --agent overrides identity)
USAGE
    ;;
  *) echo "agkanban: unknown subcommand: $sub" >&2; exit 2 ;;
esac
