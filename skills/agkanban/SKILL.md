---
name: agkanban
description: Use when coordinating multi-agent tasks across Claude Code / Codex with a kanban-style board that pairs with agmsg. Manage cards, claim work, move cards between todo/doing/review/done, and auto-notify teammates via agmsg on transitions. Triggers include "show my tasks", "claim a card", "move card to review", "add a task to the board", or any multi-agent task hand-off.
---

# agkanban

Kanban-style task state management designed to pair with agmsg. State is persisted in a
per-team `board.db`; card column transitions auto-notify stakeholders via agmsg.
Identity (team/agent) is borrowed from agmsg.

## Prerequisites

- agmsg installed and the project joined to a team (`/agmsg` to verify).
- Board operations work without joining / without agmsg, but notifications are skipped.

## Usage

All commands run as `scripts/agkanban.sh <subcommand>`. **No arguments shows your assigned cards (doing/review)** (there is no separate `mine` command).

| Command | Action |
|---|---|
| `scripts/agkanban.sh` | Your assigned cards (doing/review) |
| `scripts/agkanban.sh board` | Full team board |
| `scripts/agkanban.sh add "<title>" [--assignee X] [--reviewer Y] [--body "..."]` | Add card (todo) |
| `scripts/agkanban.sh claim <id>` | Claim (doing, assign to self, atomic) |
| `scripts/agkanban.sh review <id>` | Request review (move to review) |
| `scripts/agkanban.sh done <id>` | Mark done |
| `scripts/agkanban.sh reopen <id>` | Reopen (back to todo) |
| `scripts/agkanban.sh move <id> <todo\|doing\|review\|done>` | Generic: move to any column (fallback for the above verbs) |
| `scripts/agkanban.sh show <id>` | Card detail + event history |
| `scripts/agkanban.sh block <id> --by <id2>` | Set dependency |

`claim`/`review`/`done`/`reopen` are intent-specific transition verbs; internally they
perform the same column move + agmsg auto-notification as `move`. Use `move` only when
you need to target an arbitrary column.

Pass `--team <name>` on each command when you belong to multiple teams.

In a team, `--assignee` / `--reviewer` are agmsg agent names (list them with `/agmsg team`),
and the board + notifications are shared with teammate agents on the same machine. Run
agkanban from the project you joined so `whoami` can resolve your identity.

## Delivery (awareness)

agkanban has no dedicated monitor. Notifications fired on transitions are delivered by
**agmsg's delivery mechanism (turn/monitor/hook)**. Because state is persistent, running
`agkanban` / `board` on demand is sufficient to catch up without missing anything.

### SessionStart auto-pull (optional)

Register `hooks/session-start.sh` as a Claude Code SessionStart hook to automatically
surface your assigned cards in context at every session start (silent when identity is
unresolved or there are no cards). Example config (`~/.claude/settings.json`):

```json
"hooks": {
  "SessionStart": [
    { "hooks": [ { "type": "command",
      "command": "bash ~/.agents/skills/agkanban/hooks/session-start.sh" } ] }
  ]
}
```

## Notification mapping

| Transition | Recipient |
|---|---|
| → doing | assignee |
| → review | reviewer (falls back to creator) |
| → done | creator (+ assignee if different) |
| dependency done | assignee of the waiting card |

Notifications to yourself are suppressed.
