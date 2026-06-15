# agkanban Design Document (v0)

- Date: 2026-06-15
- Status: design finalized / implementation plan pending
- Author: lucianlamp + Claude Code

## 1. Goal

Build a **kanban-style task state management skill** for multi-agent coordination
(Claude Code / Codex etc.) that pairs with agmsg for full value.

- agmsg = transport layer (volatile messages)
- agkanban = state layer (persistent board)

The two layers share only an identity space (team/agent), keeping responsibilities
separate while enabling "moving a card = notifications flow to stakeholders
automatically."

## 2. Design decisions (finalized)

| # | Issue | Decision | Rationale |
|---|---|---|---|
| 1 | Coupling to agmsg | **Event-driven coupling** | Card column transitions auto-fire agmsg messages. "Board moves → conversation flows." |
| 2 | Board scope | **Per team** (1 team = 1 board) | Aligns with agmsg's message scope; assignee = agmsg recipient name follows naturally. |
| 3 | Storage | **Independent DB `board.db`** (agmsg's messages.db is off-limits) | No fork of agmsg; stays loosely coupled. Respects the no-direct-DB-edit policy. |
| 4 | Placement | **`~/.agents/skills/agkanban/`** (= `~/.claude/skills/agkanban`, same inode via symlink) | Sibling of agmsg; relative-path resolution works stably from both namespaces. |
| 5 | Delivery (awareness) | **Piggyback on agmsg + on-demand pull** (no dedicated monitor/hook) | Push notifications carried by agmsg's turn/monitor/hook. State is persistent so pull never misses anything. |

## 3. Architecture

```
                 Shared identity space (team / agent)
                 ┌───────────────────────────────┐
   agkanban ─────┤  borrowed via whoami.sh        ├───── agmsg
  (state/persistent)  └───────────────────────────────┘   (transport/volatile)
       │                                                  │
   board.db (cards, card_events)                    messages.db
       │                                                  ▲
       └── column transition event ──→ events.sh ──→ send.sh ───────┘
                                          (swappable via AGMSG_SEND_CMD)
```

### 3.1 Identity borrowing

agkanban does not join teams itself. Each operation begins by calling agmsg's
identity resolution. The agmsg location is **probed robustly** (during development
`~/dev/agkanban` has no agmsg sibling):

```
agmsg search order (lib/agmsg.sh):
  1. $AGMSG_HOME (explicit env)
  2. <agkanban>/../agmsg          # production: sibling of ~/.agents/skills/agmsg
  3. ~/.agents/skills/agmsg
  4. ~/.claude/skills/agmsg       # symlink of 3, kept as fallback
  → if none found: fallback mode (§3.5)
```

The found agmsg is called as `scripts/whoami.sh "$(pwd)" <type>` to resolve identity.

- Single team resolved: use it as the target.
- Multiple teams: `--team <name>` is required (eliminates ambiguity).
- Not joined / no agmsg: fall through to §3.5 fallback.

Card `assignee` / `reviewer` / `creator` are **agmsg agent names** and serve directly
as agmsg message recipients.

### 3.2 Data model (board.db, WAL)

```sql
CREATE TABLE cards (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,  -- displayed as card-<id>
  team       TEXT NOT NULL,                      -- matches agmsg team
  title      TEXT NOT NULL,
  col        TEXT NOT NULL DEFAULT 'todo',       -- todo|doing|review|done
  assignee   TEXT,                               -- agmsg agent name (doing notification recipient)
  reviewer   TEXT,                               -- review notification recipient
  creator    TEXT,                               -- card creator (done notification recipient)
  blocked_by INTEGER,                            -- id of blocking card (optional)
  body       TEXT,                               -- description / acceptance criteria
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE card_events (                        -- audit log
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  card_id  INTEGER NOT NULL,
  team     TEXT NOT NULL,
  actor    TEXT,                                  -- agent that performed the action
  from_col TEXT,
  to_col   TEXT,
  at       TEXT NOT NULL
);

CREATE INDEX idx_cards_team_col ON cards(team, col);
CREATE INDEX idx_cards_assignee ON cards(team, assignee);
```

- Card IDs are unique integers across the DB. Display and message references use
  `card-<id>` (e.g. `card-12`). Reverse lookup strips the `card-` prefix.
- Columns are fixed to 4 values in v0: todo / doing / review / done.

### 3.3 Event → agmsg auto-fire (core)

On a column transition, `events.sh` consults a declarative mapping table and calls
`send.sh`. `from_agent` is the operator resolved via whoami.

| Transition | Recipient | Message body (example) |
|---|---|---|
| `* → doing` | `assignee` | `[agkanban] card-12 start requested: <title>` |
| `* → review` | `reviewer` (or `creator`) | `[agkanban] card-12 review requested: <title>` |
| `* → done` | `creator` (+ `assignee` if different) | `[agkanban] card-12 done: <title>` |
| `blocked_by` resolved (dependency done) | `assignee` of waiting card | `[agkanban] card-09 unblocked (card-done_id done)` |

- Message body always includes `card-<id>` → agmsg side can reverse-reference the card uniquely.
- If the recipient is unset (e.g. no assignee when moving to doing), skip the send and warn to stderr.
- Skip if the recipient equals the sender (noise suppression).

### 3.4 Delivery (awareness)

- **Push**: agkanban has no dedicated monitor. Fired agmsg messages are delivered by
  agmsg's existing delivery mechanisms (turn/monitor/hook).
- **Pull**: state is persistent; agents pull on demand.
  - `agkanban mine` (= no-arg default) — lists cards where you are assignee and col is
    `doing`/`review` (board-side equivalent of agmsg's turn mode; more reliable than
    message delivery).
  - `agkanban board` — full team board.

### 3.5 Concurrency, consistency, and fallback

- **claim conflict**: atomic conditional UPDATE ensures only one agent succeeds:
  ```sql
  UPDATE cards SET assignee=:me, col='doing', updated_at=:now
   WHERE id=:id AND team=:team AND (assignee IS NULL OR assignee=:me);
  ```
  Check `changes()` immediately after. 0 means "already claimed by someone else."
- **Source of truth**: board.db is the sole source of truth. agmsg messages are
  volatile signals only.
- **No agmsg / not joined**: if identity resolution or send.sh calls fail, **the
  board state transition still executes**. Only the notification is skipped, with a
  warning (kanban works standalone).

## 4. Command interface

Invoked via the `/agkanban` skill. Like agmsg: scripts only, no direct DB access.

```
/agkanban                          # no args = mine (your assigned cards)
/agkanban mine                     # cards where you are assignee in doing/review (= no-arg)
/agkanban add "<title>" [--assignee X] [--reviewer Y] [--body "..."]
/agkanban move <id> <column>       # ← triggers agmsg auto-fire
/agkanban claim <id>               # set assignee=self and move to doing (atomic)
/agkanban show <id>                # card detail + event history
/agkanban block <id> --by <id2>    # set dependency
/agkanban board                    # full team board (per-column listing)
```

**The default no-arg behavior is `mine`** (same philosophy as agmsg's "no args = see
your inbox" — show what's waiting for you first). Use `board` explicitly for the full
team board.

Pass `--team <name>` on each command when you belong to multiple teams.

## 5. Directory layout

Developed as a repo (root = skill itself), pushed to GitHub. Installing expands this
content to `~/.agents/skills/agkanban/`.

```
~/dev/agkanban/                  # git repo → github.com/lucianlamp/agkanban
├── SKILL.md                     # skill entry point (frontmatter + identity guidance + subcommand dispatch)
├── README.md                    # one-liner install (§9) + usage
├── LICENSE
├── .gitignore                   # db/ is runtime-generated; excluded from repo
├── scripts/
│   ├── lib/
│   │   ├── storage.sh           # board.db path resolution (env AGKANBAN_STORAGE_PATH > default <skill>/db)
│   │   ├── agmsg.sh             # agmsg discovery (§3.1), whoami resolution, send wrapper (AGMSG_SEND_CMD seam)
│   │   └── events.sh            # transition → notification mapping
│   ├── init-db.sh
│   ├── add.sh
│   ├── move.sh
│   ├── claim.sh
│   ├── mine.sh
│   ├── show.sh
│   ├── board.sh
│   └── block.sh
├── docs/
│   └── 2026-06-15-agkanban-design.md
└── tests/
    └── test_transitions.sh
```

- `db/board.db` is created at runtime by `init-db.sh` (not committed; in `.gitignore`).
- Development (`~/dev/agkanban`) and production (`~/.agents/skills/agkanban`) differ in
  path, but the agmsg discovery (§3.1) and storage path resolution (env takes priority)
  make both work.

## 6. Testing strategy

- **State transition unit tests**: run add → move → claim → block against a temp DB
  (`AGKANBAN_STORAGE_PATH=$(mktemp -d)`) and assert `cards` and `card_events` results.
- **claim conflict**: run two consecutive claims on the same card; verify first succeeds,
  second fails.
- **agmsg fire verification**: replace `AGMSG_SEND_CMD` with a recording script (appends
  args to a file), then assert that each transition sends to the correct recipient with
  a body containing `card-<id>`.
- **Fallback**: simulate agmsg not found; verify state transition succeeds and
  notification is skipped (warning only).

## 7. Out of scope (YAGNI)

Not built in v0. Add via a separate spec if needed.

- Web UI / dashboard (CLI pull commands are sufficient)
- priority / due date / label / estimate fields (v0 has minimal fields only)
- Cross-team or global boards
- agkanban-specific monitor / real-time push
- PR automation, ACP integration, worktree integration

## 8. Distribution and installation

Developed at `~/dev/agkanban` (git repo), pushed to `github.com/lucianlamp/agkanban`.
The repo starts private and is made public later (install verification uses the local
path from §3.1 in the meantime).

One-liner install in README (**skills.sh primary + gh cli alternative**):

```bash
# primary: skills.sh (auto-places in ~/.agents/skills; tracks updates)
npx --yes skills add lucianlamp/agkanban -g -y

# alternative: gh cli (preview feature; --scope user puts it in ~/.claude/skills = ~/.agents/skills)
gh skill install lucianlamp/agkanban --agent claude-code --scope user
```

- Both methods require a root `SKILL.md` with correct frontmatter (`name` / `description`).
  A single skill repo can support both by placing SKILL.md at the root.
- After installation the skill lands at `~/.agents/skills/agkanban/` (sibling of agmsg),
  which matches search order entries 2/3 in §3.1.
- Prerequisite: agmsg (`~/.agents/skills/agmsg`) installed. Without it, agkanban runs in
  fallback mode (no notifications). README states "works best paired with agmsg."

## 9. Open issues

None (all major decisions finalized). Implementation-time details are handled in the
implementation plan.
