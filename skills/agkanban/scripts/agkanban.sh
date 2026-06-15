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
  claim)  exec bash "$DIR/claim.sh" "$@" ;;
  show)   exec bash "$DIR/show.sh" "$@" ;;
  block)  exec bash "$DIR/block.sh" "$@" ;;
  # 意味的な遷移動詞（move <id> <col> の薄いラッパ）。列名を末尾に付けて move へ委譲。
  review) exec bash "$DIR/move.sh" "$@" review ;;
  done)   exec bash "$DIR/move.sh" "$@" done ;;
  reopen) exec bash "$DIR/move.sh" "$@" todo ;;
  # 汎用フォールバック（任意の列へ）。
  move)   exec bash "$DIR/move.sh" "$@" ;;
  mine)
    echo "agkanban: 'mine' は既定動作です。引数なしで 'agkanban' を実行してください。" >&2
    exit 2 ;;
  -h|--help|help)
    cat <<'USAGE'
agkanban — agmsg と組み合わせる kanban 型タスク管理
  agkanban                       自分の担当カード（doing/review）
  agkanban board                 team のボード全体
  agkanban add "<title>" [--assignee X] [--reviewer Y] [--body "..."] [--team T]
  agkanban claim <id> [--team T]    着手（doing・自分に割当）
  agkanban review <id> [--team T]   レビュー依頼（review）
  agkanban done <id> [--team T]     完了（done）
  agkanban reopen <id> [--team T]   差し戻し（todo）
  agkanban move <id> <todo|doing|review|done> [--team T]   汎用（任意の列へ）
  agkanban show <id> [--team T]
  agkanban block <id> --by <id2> [--team T]
USAGE
    ;;
  *) echo "agkanban: unknown subcommand: $sub" >&2; exit 2 ;;
esac
