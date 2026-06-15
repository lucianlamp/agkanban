#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
sub="${1:-mine}"        # 引数なし = mine
[ "$#" -gt 0 ] && shift

case "$sub" in
  mine)   exec bash "$DIR/mine.sh" "$@" ;;
  board)  exec bash "$DIR/board.sh" "$@" ;;
  add)    exec bash "$DIR/add.sh" "$@" ;;
  move)   exec bash "$DIR/move.sh" "$@" ;;
  claim)  exec bash "$DIR/claim.sh" "$@" ;;
  show)   exec bash "$DIR/show.sh" "$@" ;;
  block)  exec bash "$DIR/block.sh" "$@" ;;
  -h|--help|help)
    cat <<'USAGE'
agkanban — agmsg と組み合わせる kanban 型タスク管理
  agkanban                       自分の担当カード（= mine）
  agkanban mine                  自分の doing/review カード
  agkanban board                 team のボード全体
  agkanban add "<title>" [--assignee X] [--reviewer Y] [--body "..."] [--team T]
  agkanban move <id> <todo|doing|review|done> [--team T]
  agkanban claim <id> [--team T]
  agkanban show <id> [--team T]
  agkanban block <id> --by <id2> [--team T]
USAGE
    ;;
  *) echo "agkanban: unknown subcommand: $sub" >&2; exit 2 ;;
esac
