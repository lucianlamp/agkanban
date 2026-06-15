#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

# 引数なし = 自分の担当カード（doing/review）。これが既定動作で、
# 別名の 'mine' サブコマンドは持たない（混乱防止のため一本化）。
if [ "$#" -eq 0 ]; then
  exec bash "$DIR/mine.sh"
fi

sub="$1"; shift
case "$sub" in
  board)  exec bash "$DIR/board.sh" "$@" ;;
  add)    exec bash "$DIR/add.sh" "$@" ;;
  move)   exec bash "$DIR/move.sh" "$@" ;;
  claim)  exec bash "$DIR/claim.sh" "$@" ;;
  show)   exec bash "$DIR/show.sh" "$@" ;;
  block)  exec bash "$DIR/block.sh" "$@" ;;
  mine)
    echo "agkanban: 'mine' は既定動作です。引数なしで 'agkanban' を実行してください。" >&2
    exit 2 ;;
  -h|--help|help)
    cat <<'USAGE'
agkanban — agmsg と組み合わせる kanban 型タスク管理
  agkanban                       自分の担当カード（doing/review）
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
