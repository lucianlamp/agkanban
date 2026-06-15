---
name: agkanban
description: Use when coordinating multi-agent tasks across Claude Code / Codex with a kanban-style board that pairs with agmsg. Manage cards, claim work, move cards between todo/doing/review/done, and auto-notify teammates via agmsg on transitions. Triggers include "show my tasks", "claim a card", "move card to review", "add a task to the board", or any multi-agent task hand-off.
---

# agkanban

agmsg と組み合わせて使う kanban 型タスク状態管理。状態は team 単位の `board.db` に永続化し、
カードの列遷移時に agmsg 経由で関係者へ自動通知する。識別（team/agent）は agmsg から借用する。

## 前提

- agmsg が install 済みで、このプロジェクトで team に join していること（`/agmsg` で確認）。
- 未 join / agmsg 不在でもボード操作は動くが、通知はスキップされる。

## 使い方

すべて `scripts/agkanban.sh <subcommand>` を実行する。**引数なしで自分の担当カード（doing/review）を表示**する（専用の `mine` コマンドは持たない）。

| コマンド | 動作 |
|---|---|
| `scripts/agkanban.sh` | 自分の担当カード（doing/review） |
| `scripts/agkanban.sh board` | team のボード全体 |
| `scripts/agkanban.sh add "<title>" [--assignee X] [--reviewer Y] [--body "..."]` | カード追加（todo） |
| `scripts/agkanban.sh claim <id>` | 着手（doing・自分に割当、原子的） |
| `scripts/agkanban.sh review <id>` | レビュー依頼（review へ） |
| `scripts/agkanban.sh done <id>` | 完了（done へ） |
| `scripts/agkanban.sh reopen <id>` | 差し戻し（todo へ） |
| `scripts/agkanban.sh move <id> <todo\|doing\|review\|done>` | 汎用：任意の列へ（上記動詞のフォールバック） |
| `scripts/agkanban.sh show <id>` | カード詳細 + イベント履歴 |
| `scripts/agkanban.sh block <id> --by <id2>` | 依存設定 |

`claim`/`review`/`done`/`reopen` は遷移ごとの意図を表す動詞で、内部的には `move` と同じく列遷移＋agmsg 自動通知を行う。任意の列へ動かしたいときだけ `move` を使う。

複数 team に所属する場合は各コマンドに `--team <name>` を付ける。

## delivery（気づき）

agkanban は独自の監視を持たない。遷移で発火した通知は **agmsg の delivery（turn/monitor/hook）** が運ぶ。
カードは状態が永続するため、必要時に引数なし `agkanban` / `board` で pull すれば取りこぼさない。

### SessionStart 自動 pull（任意）

`hooks/session-start.sh` を Claude Code の SessionStart hook に登録すると、各セッション開始時に
自分の担当カードが自動で context に表示される（identity 未解決やカード無しのときは無音）。設定例
（`~/.claude/settings.json`）:

```json
"hooks": {
  "SessionStart": [
    { "hooks": [ { "type": "command",
      "command": "bash ~/.agents/skills/agkanban/hooks/session-start.sh" } ] }
  ]
}
```

## 通知マッピング

| 遷移 | 通知先 |
|---|---|
| → doing | assignee |
| → review | reviewer（無ければ creator） |
| → done | creator（+ assignee が別なら両方） |
| 依存先が done | 待ちカードの assignee |

自分自身宛の通知は送られない。
