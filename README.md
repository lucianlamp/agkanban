# agkanban

[![CI](https://github.com/lucianlamp/agkanban/actions/workflows/ci.yml/badge.svg)](https://github.com/lucianlamp/agkanban/actions/workflows/ci.yml)

Multi-agent kanban task board that pairs with **agmsg**. State lives in a
per-team SQLite board; moving a card auto-notifies teammates through agmsg (event-driven).
Built with bash + sqlite3 — no daemon, no network.

## Install

**skills.sh（推奨）** — `~/.agents/skills` にグローバル install:

```bash
npx --yes skills add lucianlamp/agkanban -g -y
```

**gh CLI（代替, preview）**:

```bash
gh skill install lucianlamp/agkanban agkanban --agent claude-code --scope user
```

> agkanban は agmsg と併用して真価を発揮します。先に agmsg を install し、team に join してください。
> agmsg 不在でもボード操作は動きますが、通知はスキップされます。

## Quick start

```bash
scripts/agkanban.sh add "design API" --assignee codex --reviewer claude
scripts/agkanban.sh claim 1        # 着手（doing・自分に割当）
scripts/agkanban.sh review 1       # レビュー依頼（reviewer へ自動通知）
scripts/agkanban.sh done 1         # 完了（done）
scripts/agkanban.sh reopen 1       # 差し戻し（todo）
scripts/agkanban.sh move 1 doing   # 汎用：任意の列へ（上記動詞のフォールバック）
scripts/agkanban.sh                # 引数なし = 自分の担当カード（doing/review）
scripts/agkanban.sh board          # ボード全体
```

> 遷移は `claim`/`review`/`done`/`reopen` の動詞が直観的な入口。内部はすべて列遷移＋agmsg 通知で、`move <id> <列>` は任意遷移のフォールバック。

> 引数なしの `agkanban` が「自分の担当」を表示する唯一の入口。専用の `mine` コマンドは無い。

## How it works

- **状態**: `db/board.db`（team 単位）。`AGKANBAN_STORAGE_PATH` で差替可。
- **識別**: agmsg の `whoami.sh` から team/agent を借用（`AGMSG_HOME` / 兄弟ディレクトリ / `~/.agents/skills/agmsg` を探索）。
- **通知**: 列遷移時に agmsg の `send.sh` を発火（`AGMSG_SEND_CMD` で差替可・テスト用）。
- **delivery**: agmsg の turn/monitor/hook に相乗り。agkanban 独自の監視は持たない。

## Auto-pull (SessionStart hook, optional)

各エージェントがセッション開始時に自分の担当カードを自動で見るには、`hooks/session-start.sh`
を Claude Code の SessionStart hook に登録する。identity 未解決やカード無しのときは無音なので、
agkanban を使わないプロジェクトでは何も起きない。

`~/.claude/settings.json`:

```json
"hooks": {
  "SessionStart": [
    { "hooks": [ { "type": "command",
      "command": "bash ~/.agents/skills/agkanban/hooks/session-start.sh" } ] }
  ]
}
```

## Test

```bash
bash skills/agkanban/tests/test_transitions.sh
```

## Repo layout

The installable skill lives under `skills/agkanban/` (matches `skills/*/SKILL.md`,
which both `skills.sh` and `gh skill install` discover). Once installed it lands at
`~/.agents/skills/agkanban/`, where the Quick start commands above are run as
`scripts/agkanban.sh …` from within the skill directory.

## License

MIT
