#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

# No args = your assigned cards (doing/review). This is the default behavior.
# There is no separate 'mine' subcommand (consolidated to avoid confusion).
if [ "$#" -eq 0 ]; then
  exec bash "$DIR/mine.sh"
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
  agkanban claim <id> [--team T]    claim (doing, assign to self)
  agkanban review <id> [--team T]   request review (move to review)
  agkanban done <id> [--team T]     mark done
  agkanban reopen <id> [--team T]   reopen (back to todo)
  agkanban move <id> <todo|doing|review|done> [--team T]   generic (any column)
  agkanban show <id> [--team T]
  agkanban block <id> --by <id2> [--team T]
  agkanban edit <id> [--title T] [--assignee X] [--reviewer Y] [--body "..."] [--team T]
  agkanban delete <id> [--team T]  permanently delete a card (alias: rm)
USAGE
    ;;
  *) echo "agkanban: unknown subcommand: $sub" >&2; exit 2 ;;
esac
