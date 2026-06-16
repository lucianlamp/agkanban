# agkanban

[![CI](https://github.com/lucianlamp/agkanban/actions/workflows/ci.yml/badge.svg)](https://github.com/lucianlamp/agkanban/actions/workflows/ci.yml)

Multi-agent kanban task board that pairs with **agmsg**. State lives in a
per-team SQLite board; moving a card auto-notifies teammates through agmsg (event-driven).
Built with bash + sqlite3 — no daemon, no network.

## Install

**skills.sh (recommended)** — installs globally to `~/.agents/skills`:

```bash
npx --yes skills add lucianlamp/agkanban -g -y
```

**gh CLI (alternative, preview)**:

```bash
gh skill install lucianlamp/agkanban agkanban --agent claude-code --scope user
```

> agkanban works best paired with agmsg. Install agmsg first and join your team.
> Board operations work without agmsg, but notifications are skipped.

## Quick start

```bash
scripts/agkanban.sh add "design API" --assignee codex --reviewer claude
scripts/agkanban.sh claim 1        # claim (doing, assign to self)
scripts/agkanban.sh review 1       # request review (auto-notifies reviewer)
scripts/agkanban.sh done 1         # mark done
scripts/agkanban.sh reopen 1       # reopen (back to todo)
scripts/agkanban.sh move 1 doing   # generic: move to any column (fallback for the above verbs)
scripts/agkanban.sh                # no args = your assigned cards (doing/review)
scripts/agkanban.sh board          # full board
```

> Use `claim`/`review`/`done`/`reopen` for intent-specific transitions; they all do column move + agmsg notification internally. Use `move <id> <col>` for arbitrary transitions.

> Running `agkanban` with no arguments is the only way to see your assigned cards. There is no separate `mine` command.

## How it works

- **State**: `db/board.db` (per team). Override with `AGKANBAN_STORAGE_PATH`.
- **Identity**: borrows team/agent from agmsg's `whoami.sh` (searches `AGMSG_HOME`, sibling directory, `~/.agents/skills/agmsg`).
- **Notifications**: fires agmsg's `send.sh` on column transitions (swappable via `AGMSG_SEND_CMD` for testing).
- **Delivery**: piggybacks on agmsg's turn/monitor/hook. agkanban has no dedicated monitor.

## Team usage (multi-agent)

agmsg — and therefore agkanban — is **local to a single machine** (a local SQLite store,
no network). "Team members" are the agents/sessions running on the same machine
(e.g. Claude Code and Codex, or several spawned roles). Cross-machine teams are not
supported.

**Setup (once per machine):** install agkanban into the shared skills tree
(`~/.agents/skills/agkanban`). Every local CLI agent that reads that tree — Claude Code
(via the `~/.claude/skills` symlink), Codex, Gemini (via `skills.external_dirs`) — can
then use it; there is no per-member install. Optionally register the SessionStart hook
per runtime (see below) so each member sees its cards automatically.

**Onboarding a member:** if the agent has already joined the agmsg team, it can use
agkanban as-is — there is no separate agkanban registration. Identity is borrowed from
agmsg, so each member runs agkanban **from the project it joined** (that is where
`whoami` resolves its agent/team).

**Workflow (leader → members):**

```bash
/agmsg team                                       # list member agent names
scripts/agkanban.sh add "implement X" --assignee codex --reviewer claude
scripts/agkanban.sh claim 1     # a member starts it (doing, assigned to self)
scripts/agkanban.sh review 1    # notifies the reviewer via agmsg
scripts/agkanban.sh done 1      # notifies creator / assignee
```

The board is per team, so all members share it. Members notice work via agmsg
notifications and `agkanban` (their assigned cards), then act on it. Use
`/agmsg spawn <type> <name>` to launch another agent in a tmux pane / terminal; with the
SessionStart hook it sees its cards on start.

**Gotchas:**
- Run agkanban from the project you joined to the team — otherwise `whoami` can't resolve
  your identity (`agent unresolved`); pass `--team`, or join that project.
- `--assignee` / `--reviewer` must match the exact agmsg agent names (`/agmsg team`).
- Single machine only — members on different machines do not share the board.

## Auto-pull (SessionStart hook, optional)

To have each agent automatically see its assigned cards at session start, register
`hooks/session-start.sh` as a Claude Code SessionStart hook. It stays silent when
identity is unresolved or there are no cards, so it is a no-op in projects that
don't use agkanban.

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
