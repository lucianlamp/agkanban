# agkanban

[![CI](https://github.com/lucianlamp/agkanban/actions/workflows/ci.yml/badge.svg)](https://github.com/lucianlamp/agkanban/actions/workflows/ci.yml)

Multi-agent kanban task board that pairs with **[agmsg](https://github.com/fujibee/agmsg)**. State lives in
`~/.agkanban/board.db`; moving a card auto-notifies teammates through agmsg (event-driven).
Built with bash + sqlite3 — no daemon, no network.

## Install

**skills.sh (recommended)** — target the agents you use with repeated `-a` (add `-a codex`
etc. for others):

```bash
npx --yes skills add lucianlamp/agkanban -g -a claude-code -a codex -y
```

> Always include **`-a claude-code`**: Claude Code only reads `~/.claude/skills` by default,
> so it must be installed there (the `~/.claude/skills → ~/.agents/skills` symlink is
> environment-specific, not standard). Each `-a <agent>` installs to that agent's own skills
> dir. Add `--copy` to copy files instead of symlinking (more reliable on Windows, where
> symlinks need privileges).
>
> A bare `npx skills add ... -g` (all detected agents) also works but may print a harmless
> *"PromptScript does not support global skill installation"* line — `PromptScript` is a
> project-only target and is simply skipped (see vercel-labs/skills#1352).

**gh CLI (alternative)** — single agent, or a custom dir (`--dir` overrides
`--agent`/`--scope`):

```bash
gh skill install lucianlamp/agkanban agkanban --agent claude-code --scope user
# or into the shared tree next to agmsg:
gh skill install lucianlamp/agkanban agkanban --dir "$HOME/.agents/skills/agkanban"
```

## Update

```bash
# skills.sh — update the installed skill to the latest version
npx --yes skills update agkanban -g -y

# gh CLI
gh skill update
```

> On **Windows**, `skills update` can report *"Failed to update"* if the install uses
> symlinks (creating symlinks needs Developer Mode / admin). Refresh with a copy-based
> re-install instead — `npx --yes skills add lucianlamp/agkanban -g -a claude-code -a codex --copy -y`
> — or `gh skill install lucianlamp/agkanban agkanban --agent claude-code --scope user --force`
> (gh copies files). Updates from a **private** repo also fail (`Failed to fetch tree`); the repo must be public.

> agkanban works best paired with agmsg. Install agmsg first and join your team.
> Board operations work without agmsg, but notifications are skipped.

## Quick start

On Windows / PowerShell / Codex, invoke the installed PowerShell profile function from the
project directory. It delegates to Git Bash; do not use WSL `bash`:

```powershell
agkanban add "design API" --assignee codex --reviewer claude
agkanban claim 1
agkanban review 1
agkanban done 1
agkanban
agkanban board
```

On Unix / Git Bash, invoke through `bash` (skill installers don't preserve the execute
bit):

```bash
bash scripts/agkanban.sh add "design API" --assignee codex --reviewer claude
bash scripts/agkanban.sh claim 1        # claim (doing, assign to self)
bash scripts/agkanban.sh review 1       # request review (auto-notifies reviewer)
bash scripts/agkanban.sh done 1         # mark done
bash scripts/agkanban.sh reopen 1       # reopen (back to todo)
bash scripts/agkanban.sh move 1 doing   # generic: move to any column (fallback for the above verbs)
bash scripts/agkanban.sh edit 1 --body "target: src/x.ts; AC: tests pass"   # edit card fields
bash scripts/agkanban.sh delete 1       # permanently delete a card (alias: rm)
bash scripts/agkanban.sh                # no args = your open cards (todo/doing/review)
bash scripts/agkanban.sh board          # full board
```

> Use `claim`/`review`/`done`/`reopen` for intent-specific transitions; they all do column move + agmsg notification internally. Use `move <id> <col>` for arbitrary transitions.

> Running `agkanban` with no arguments is the only way to see your assigned cards. There is no separate `mine` command.

> The no-args output (and the SessionStart hook) is a **call to act**, not just a status
> list: it instructs the agent to work each card (read `show`, `claim` a todo, do the work,
> move to `review`/`done`, or report blockers). Agents proceed instead of only reporting.

## How it works

- **State**: `~/.agkanban/board.db` (per team), kept outside the skill dir so reinstalling
  /updating the skill never wipes your cards. Override with `AGKANBAN_STORAGE_PATH`. A board
  from the old in-skill `<skill>/db` location is auto-migrated on first run.
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
/agmsg team                                            # list member agent names
bash scripts/agkanban.sh add "implement X" --assignee codex --reviewer claude
bash scripts/agkanban.sh claim 1     # a member starts it (doing, assigned to self)
bash scripts/agkanban.sh review 1    # notifies the reviewer via agmsg
bash scripts/agkanban.sh done 1      # notifies creator / assignee
```

The board is per team, so all members share it. Members notice work via agmsg
notifications and `agkanban` (their assigned cards), then act on it. Use
`/agmsg spawn <type> <name>` to launch another agent in a tmux pane / terminal; with the
SessionStart hook it sees its cards on start.

**Gotchas:**
- Run agkanban from the project you joined to the team — otherwise `whoami` can't resolve
  your identity (`agent unresolved`); pass `--team`, or join that project.
- `--assignee` / `--reviewer` must match the exact agmsg agent names (`/agmsg team`).
- For real task cards, put the target files/paths and acceptance criteria in `--body`. The
  notification carries only the title, so without a body the assignee/reviewer can't tell
  what to act on (they read it via `show`).
- `delete` is **creator-only** and `edit` is **creator-or-assignee** — a cooperative guard
  based on your agmsg identity (not cryptographic auth). Cards with no recorded creator are
  editable/deletable by anyone (avoids lockout).
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

## Sandbox

agkanban writes **outside the project**: the board at `~/.agkanban/`, and (when a
transition fires a notification) agmsg's store at `~/.agents/skills/agmsg/`. Under a
sandbox that only permits workspace writes, declare these as writable roots or
`add`/`claim`/`move`/notify will fail.

**Claude Code** (`~/.claude/settings.json`):

```json
"sandbox": {
  "filesystem": {
    "allowWrite": ["~/.agkanban/", "~/.agents/skills/agmsg/"]
  }
}
```

**Codex** — run `workspace-write` and add the data dirs (repeat `--add-dir`):

```bash
codex --sandbox workspace-write \
  --add-dir "$HOME/.agkanban" --add-dir "$HOME/.agents/skills/agmsg"
```

Persistent equivalent in `~/.codex/config.toml`:

```toml
[sandbox_workspace_write]
writable_roots = ["~/.agkanban", "~/.agents/skills/agmsg"]
```

Or use `--sandbox danger-full-access`. A `read-only` sandbox cannot run agkanban's write
commands. (Verified: under `workspace-write` without these roots, `agkanban add` fails with
*"unable to open database file"*; adding the storage root fixes it.)

## Windows

agkanban runs on Windows through **Git Bash**, with a thin PowerShell launcher
(`scripts/windows/agkanban.ps1`) that hands commands to the Bash dispatcher over a
UTF-8-safe base64 argv file — no logic is reimplemented in PowerShell (mirrors
[agmsg PR #128](https://github.com/fujibee/agmsg/pull/128)). See
[`docs/windows.md`](docs/windows.md) for setup, the optional `agkanban` profile function,
agent-type selection, and SessionStart hooks on Windows.

## Test

```bash
bash tests/test_transitions.sh
```

## Repo layout

The installable skill lives under `skills/agkanban/` (matches `skills/*/SKILL.md`,
which both `skills.sh` and `gh skill install` discover). Once installed it lands at
`~/.agents/skills/agkanban/`, where the Quick start commands above are run as
`bash scripts/agkanban.sh …` from within the skill directory.

## License

MIT
