# agkanban

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
scripts/agkanban.sh claim 1        # assignee=自分, doing へ（原子的）
scripts/agkanban.sh move 1 review  # reviewer へ自動通知
scripts/agkanban.sh                # 引数なし = 自分の担当（mine）
scripts/agkanban.sh board          # ボード全体
```

## How it works

- **状態**: `db/board.db`（team 単位）。`AGKANBAN_STORAGE_PATH` で差替可。
- **識別**: agmsg の `whoami.sh` から team/agent を借用（`AGMSG_HOME` / 兄弟ディレクトリ / `~/.agents/skills/agmsg` を探索）。
- **通知**: 列遷移時に agmsg の `send.sh` を発火（`AGMSG_SEND_CMD` で差替可・テスト用）。
- **delivery**: agmsg の turn/monitor/hook に相乗り。agkanban 独自の監視は持たない。

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
