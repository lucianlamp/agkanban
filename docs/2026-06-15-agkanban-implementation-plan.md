# agkanban Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `agkanban`, a kanban-style task state management skill in bash + sqlite3 that pairs with agmsg for full value, distributable via GitHub.

**Architecture:** State persisted in independent DB `board.db` (per team). Card column transitions call agmsg's `send.sh` to auto-notify stakeholders (event-driven coupling). Identity (team/agent) borrowed from agmsg. Push notifications piggyback on agmsg's delivery; agkanban provides only a pull command (no args = `mine`).

**Tech Stack:** bash, sqlite3 (WAL), git, gh (distribution). Tests use a dependency-free bash assertion harness.

**Design reference:** `docs/2026-06-15-agkanban-design.md`

---

## File Structure

Development repo `~/dev/agkanban` (root is the skill itself).

| File | Responsibility |
|---|---|
| `SKILL.md` | Skill entry point. Identity resolution guidance + subcommand dispatch instructions. |
| `README.md` | One-liner install (skills.sh primary + gh alternative) + usage. |
| `LICENSE` | MIT |
| `.gitignore` | Excludes `db/` (runtime-generated). |
| `scripts/agkanban.sh` | Dispatcher (no-arg = mine). Execs into each subcommand. |
| `scripts/lib/storage.sh` | board.db path resolution, DB exec helper, SQL escape, timestamp, card id parse. |
| `scripts/lib/agmsg.sh` | agmsg discovery, identity resolution (whoami), send wrapper (`AGMSG_SEND_CMD` seam). |
| `scripts/lib/events.sh` | Transition → notification mapping and fire. |
| `scripts/init-db.sh` | Schema creation. |
| `scripts/add.sh` | Add card (todo). |
| `scripts/move.sh` | Column transition + event fire. |
| `scripts/claim.sh` | Atomic claim (assignee=self, move to doing). |
| `scripts/mine.sh` | Your doing/review cards (the no-arg default). |
| `scripts/show.sh` | Card detail + event history. |
| `scripts/board.sh` | Full team board. |
| `scripts/block.sh` | Set dependency. |
| `tests/lib_assert.sh` | Test assertion harness. |
| `tests/test_transitions.sh` | Tests for transitions, claim, notifications, and fallback. |

**Key design seams (testability):**
- `AGKANBAN_STORAGE_PATH` — swap board.db location (tests use a temp dir)
- `AGMSG_SEND_CMD` — swap the notification send command (tests use a recording script)
- `AGK_AGENT` / `AGK_TEAM` — if pre-set, skip whoami call (test stub)

---

## Task 1: Test harness

**Files:**
- Create: `tests/lib_assert.sh`

- [ ] **Step 1: Write the assertion harness**

`tests/lib_assert.sh`:

```bash
#!/usr/bin/env bash
# Minimal dependency-free assertion harness. Each failed assert increments ASSERT_FAILS.
ASSERT_FAILS=0

assert_eq() { # actual expected label
  if [ "$1" = "$2" ]; then
    echo "ok: $3"
  else
    echo "FAIL: $3 (expected [$2], got [$1])"
    ASSERT_FAILS=$((ASSERT_FAILS + 1))
  fi
}

assert_contains() { # haystack needle label
  case "$1" in
    *"$2"*) echo "ok: $3" ;;
    *) echo "FAIL: $3 (missing [$2] in [$1])"; ASSERT_FAILS=$((ASSERT_FAILS + 1)) ;;
  esac
}

assert_not_contains() { # haystack needle label
  case "$1" in
    *"$2"*) echo "FAIL: $3 (unexpected [$2] in [$1])"; ASSERT_FAILS=$((ASSERT_FAILS + 1)) ;;
    *) echo "ok: $3" ;;
  esac
}

finish() {
  if [ "$ASSERT_FAILS" -eq 0 ]; then
    echo "ALL PASS"; exit 0
  else
    echo "$ASSERT_FAILS assertion(s) FAILED"; exit 1
  fi
}
```

- [ ] **Step 2: Syntax check**

Run: `bash -n tests/lib_assert.sh`
Expected: no output, exit 0

- [ ] **Step 3: Commit**

```bash
git add tests/lib_assert.sh
git commit -m "test: add minimal bash assertion harness"
```

---

## Task 2: storage library

**Files:**
- Create: `scripts/lib/storage.sh`

- [ ] **Step 1: Write storage.sh**

`scripts/lib/storage.sh`:

```bash
#!/usr/bin/env bash
# storage.sh — board.db path resolution and DB exec helpers.
# Resolution order: AGKANBAN_STORAGE_PATH(env) > default <skill>/db

agkanban_storage_dir() {
  if [ -n "${AGKANBAN_STORAGE_PATH:-}" ]; then
    printf '%s' "${AGKANBAN_STORAGE_PATH%/}"
    return
  fi
  local lib_dir skill_root
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  skill_root="$(cd "$lib_dir/../.." && pwd)"   # lib -> scripts -> skill root
  printf '%s/db' "$skill_root"
}

agkanban_db() { printf '%s/board.db' "$(agkanban_storage_dir)"; }

db_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

# Returns NULL for empty, or 'escaped' for non-empty (SQL literal generation)
sql_val() {
  if [ -z "${1:-}" ]; then printf 'NULL'; else printf "'%s'" "$(sql_escape "$1")"; fi
}

# Run SQL in a single sqlite3 process (multiple statements share one connection → changes() works)
db_exec() { sqlite3 -batch "$(agkanban_db)" "$1"; }

# Create DB via init-db.sh if it does not exist
ensure_db() {
  local db; db="$(agkanban_db)"
  if [ ! -f "$db" ]; then
    mkdir -p "$(dirname "$db")"
    bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../init-db.sh"
  fi
}

# Normalize "card-12" / "12" to 12. Non-numeric input prints to stderr and returns 1.
card_num() {
  local raw="${1#card-}"
  case "$raw" in
    ''|*[!0-9]*) echo "agkanban: invalid card id: $1" >&2; return 1 ;;
  esac
  printf '%s' "$raw"
}
```

- [ ] **Step 2: Syntax check and helper smoke test**

Run:
```bash
bash -n scripts/lib/storage.sh && \
bash -c 'source scripts/lib/storage.sh; echo "$(sql_val "")|$(sql_val "a'\''b")|$(card_num card-7)"'
```
Expected: `NULL|'a''b'|7`

- [ ] **Step 3: Commit**

```bash
git add scripts/lib/storage.sh
git commit -m "feat: add storage lib (db path, sql helpers, card id parse)"
```

---

## Task 3: Schema initialization

**Files:**
- Create: `scripts/init-db.sh`
- Test: `tests/test_transitions.sh` (scaffold in this task; extended in subsequent tasks)

- [ ] **Step 1: Write a failing test (DB init)**

`tests/test_transitions.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib_assert.sh"

# --- Isolated environment ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export AGKANBAN_STORAGE_PATH="$TMP"
export AGK_TEST_SENT="$TMP/sent.log"
: > "$AGK_TEST_SENT"

# Notification recorder (appends team|from|to|body per line)
cat > "$TMP/recorder.sh" <<'REC'
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$AGK_TEST_SENT"
REC
chmod +x "$TMP/recorder.sh"
export AGMSG_SEND_CMD="$TMP/recorder.sh"

# Identity stub (skip whoami)
export AGK_AGENT="alice"
export AGK_TEAM="dev"

AGK="$ROOT/scripts/agkanban.sh"

# --- Task 3: DB init ---
bash "$ROOT/scripts/init-db.sh"
tables="$(sqlite3 "$TMP/board.db" ".tables")"
assert_contains "$tables" "cards" "init-db creates cards table"
assert_contains "$tables" "card_events" "init-db creates card_events table"

finish
```

- [ ] **Step 2: Run test and confirm failure**

Run: `bash tests/test_transitions.sh`
Expected: FAIL (`init-db.sh` does not exist yet, so `cards`/`card_events` are absent)

- [ ] **Step 3: Write init-db.sh**

`scripts/init-db.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
DB="$(agkanban_db)"
mkdir -p "$(dirname "$DB")"

if [ ! -f "$DB" ]; then
  sqlite3 "$DB" <<'SQL'
PRAGMA journal_mode=WAL;

CREATE TABLE cards (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  team       TEXT NOT NULL,
  title      TEXT NOT NULL,
  col        TEXT NOT NULL DEFAULT 'todo',
  assignee   TEXT,
  reviewer   TEXT,
  creator    TEXT,
  blocked_by INTEGER,
  body       TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE card_events (
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  card_id  INTEGER NOT NULL,
  team     TEXT NOT NULL,
  actor    TEXT,
  from_col TEXT,
  to_col   TEXT,
  at       TEXT NOT NULL
);

CREATE INDEX idx_cards_team_col ON cards(team, col);
CREATE INDEX idx_cards_assignee ON cards(team, assignee);
SQL
fi
```

- [ ] **Step 4: Run test and confirm success**

Run: `bash tests/test_transitions.sh`
Expected: `ok: init-db creates cards table` / `ok: init-db creates card_events table` / `ALL PASS`

- [ ] **Step 5: Commit**

```bash
git add scripts/init-db.sh tests/test_transitions.sh tests/lib_assert.sh
git commit -m "feat: add board.db schema (init-db) with passing test"
```

---

## Task 4: agmsg library (discovery, identity, send)

**Files:**
- Create: `scripts/lib/agmsg.sh`

- [ ] **Step 1: Write agmsg.sh**

`scripts/lib/agmsg.sh`:

```bash
#!/usr/bin/env bash
# agmsg.sh — agmsg discovery, identity resolution, send wrapper.
# Assumes storage.sh is sourced first (db_exec etc. are not used here).

# Locate the agmsg installation (returns 1 if not found)
agmsg_home() {
  if [ -n "${AGMSG_HOME:-}" ] && [ -f "$AGMSG_HOME/scripts/whoami.sh" ]; then
    printf '%s' "$AGMSG_HOME"; return 0
  fi
  local lib_dir skill_root c
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  skill_root="$(cd "$lib_dir/../.." && pwd)"
  for c in "$skill_root/../agmsg" "$HOME/.agents/skills/agmsg" "$HOME/.claude/skills/agmsg"; do
    if [ -f "$c/scripts/whoami.sh" ]; then (cd "$c" && pwd); return 0; fi
  done
  return 1
}

# Identity resolution. On success, sets AGK_AGENT / AGK_TEAM and returns 0.
# If both are already set in env, skips whoami (test/override seam).
agmsg_identity() {
  if [ -n "${AGK_AGENT:-}" ] && [ -n "${AGK_TEAM:-}" ]; then return 0; fi
  local type="${1:-claude-code}" home out
  home="$(agmsg_home)" || return 1
  out="$(bash "$home/scripts/whoami.sh" "$(pwd)" "$type" 2>/dev/null)" || return 1
  AGK_AGENT="$(printf '%s\n' "$out" | sed -n 's/.*agent=\([^ ]*\).*/\1/p')"
  AGK_TEAM="$(printf '%s\n' "$out" | sed -n 's/.*teams=\([^, ]*\).*/\1/p')"
  [ -n "$AGK_AGENT" ] && [ -n "$AGK_TEAM" ]
}

# Send notification. Skip if recipient is empty or equals sender.
# Uses AGMSG_SEND_CMD if set, otherwise agmsg's send.sh.
# On agmsg absence or failure, warns and swallows the error (does not abort state transition).
agmsg_send() { # team from to body
  local team="$1" from="$2" to="$3" body="$4"
  [ -z "$to" ] && return 0
  [ "$to" = "$from" ] && return 0
  if [ -n "${AGMSG_SEND_CMD:-}" ]; then
    "$AGMSG_SEND_CMD" "$team" "$from" "$to" "$body" \
      || echo "agkanban: notify to $to failed (skipped)" >&2
    return 0
  fi
  local home
  if ! home="$(agmsg_home)"; then
    echo "agkanban: agmsg not found; skipped notify to $to" >&2
    return 0
  fi
  bash "$home/scripts/send.sh" "$team" "$from" "$to" "$body" >/dev/null 2>&1 \
    || echo "agkanban: notify to $to failed (skipped)" >&2
  return 0
}
```

- [ ] **Step 2: Syntax check and send seam smoke test**

Run:
```bash
bash -n scripts/lib/agmsg.sh && \
TMPL="$(mktemp)" && \
bash -c 'source scripts/lib/agmsg.sh
  export AGMSG_SEND_CMD="/bin/sh -c"  # dummy (confirm it is not called)
  unset AGMSG_SEND_CMD
  # recipient == sender → skip (no output)
  REC="'"$TMPL"'"; export AGMSG_SEND_CMD="$(command -v printf)"
  agmsg_send dev alice alice "self" ; echo "self-skip-ok"'
```
Expected: ends with `self-skip-ok` (self-send skipped, printf not called)

- [ ] **Step 3: Commit**

```bash
git add scripts/lib/agmsg.sh
git commit -m "feat: add agmsg lib (discovery, identity, send wrapper)"
```

---

## Task 5: events library (transition → notification)

**Files:**
- Create: `scripts/lib/events.sh`

- [ ] **Step 1: Write events.sh**

`scripts/lib/events.sh`:

```bash
#!/usr/bin/env bash
# events.sh — fire notifications for column transitions.
# Assumes storage.sh and agmsg.sh are sourced first.

# Direct transition notification.
fire_transition() { # team actor card_id title to_col assignee reviewer creator
  local team="$1" actor="$2" card_id="$3" title="$4" to_col="$5" \
        assignee="$6" reviewer="$7" creator="$8"
  local ref="card-$card_id" rcpt
  case "$to_col" in
    doing)
      agmsg_send "$team" "$actor" "$assignee" "[agkanban] $ref start requested: $title" ;;
    review)
      rcpt="$reviewer"; [ -z "$rcpt" ] && rcpt="$creator"
      agmsg_send "$team" "$actor" "$rcpt" "[agkanban] $ref review requested: $title" ;;
    done)
      agmsg_send "$team" "$actor" "$creator" "[agkanban] $ref done: $title"
      if [ -n "$assignee" ] && [ "$assignee" != "$creator" ]; then
        agmsg_send "$team" "$actor" "$assignee" "[agkanban] $ref done: $title"
      fi ;;
  esac
}

# Unblock notification: sent to the assignee of cards waiting on the card that just finished.
fire_unblock() { # team actor done_id
  local team="$1" actor="$2" done_id="$3" rows dep_id dep_assignee
  rows="$(db_exec "SELECT id, COALESCE(assignee,'') FROM cards WHERE team='$(sql_escape "$team")' AND blocked_by=$done_id;")"
  [ -z "$rows" ] && return 0
  while IFS='|' read -r dep_id dep_assignee; do
    [ -z "$dep_id" ] && continue
    agmsg_send "$team" "$actor" "$dep_assignee" \
      "[agkanban] card-$dep_id unblocked (card-$done_id done)"
  done <<EOF
$rows
EOF
}
```

- [ ] **Step 2: Syntax check**

Run: `bash -n scripts/lib/events.sh`
Expected: no output, exit 0

- [ ] **Step 3: Commit**

```bash
git add scripts/lib/events.sh
git commit -m "feat: add events lib (transition + unblock notifications)"
```

---

## Task 6: Dispatcher + add

**Files:**
- Create: `scripts/agkanban.sh`, `scripts/add.sh`
- Modify: `tests/test_transitions.sh` (append add tests)

- [ ] **Step 1: Append a failing test (add)**

Insert before `finish` in `tests/test_transitions.sh`:

```bash
# --- Task 6: add ---
out="$(bash "$AGK" add "first task" --assignee bob --reviewer carol)"
assert_contains "$out" "card-1" "add returns card-1"
row="$(sqlite3 "$TMP/board.db" "SELECT team,col,assignee,reviewer,creator,title FROM cards WHERE id=1;")"
assert_eq "$row" "dev|todo|bob|carol|alice|first task" "add inserts row (todo, creator=alice)"
```

- [ ] **Step 2: Run test and confirm failure**

Run: `bash tests/test_transitions.sh`
Expected: FAIL (`agkanban.sh` / `add.sh` do not exist yet)

- [ ] **Step 3: Write the dispatcher**

`scripts/agkanban.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
sub="${1:-mine}"        # no args = mine
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
agkanban — kanban task management paired with agmsg
  agkanban                       your assigned cards (= mine)
  agkanban mine                  your doing/review cards
  agkanban board                 full team board
  agkanban add "<title>" [--assignee X] [--reviewer Y] [--body "..."] [--team T]
  agkanban move <id> <todo|doing|review|done> [--team T]
  agkanban claim <id> [--team T]
  agkanban show <id> [--team T]
  agkanban block <id> --by <id2> [--team T]
USAGE
    ;;
  *) echo "agkanban: unknown subcommand: $sub" >&2; exit 2 ;;
esac
```

- [ ] **Step 4: Write add.sh**

`scripts/add.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib/storage.sh"
source "$DIR/lib/agmsg.sh"

TITLE=""; ASSIGNEE=""; REVIEWER=""; BODY=""; TEAM_OVERRIDE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --assignee) ASSIGNEE="$2"; shift 2 ;;
    --reviewer) REVIEWER="$2"; shift 2 ;;
    --body)     BODY="$2"; shift 2 ;;
    --team)     TEAM_OVERRIDE="$2"; shift 2 ;;
    *) if [ -z "$TITLE" ]; then TITLE="$1"; shift; else echo "agkanban add: unexpected arg: $1" >&2; exit 2; fi ;;
  esac
done
[ -z "$TITLE" ] && { echo "agkanban add: title required" >&2; exit 2; }

ensure_db
agmsg_identity "${AGK_TYPE:-claude-code}" || true   # if unresolved, creator is left empty and we continue
creator="${AGK_AGENT:-}"
team="${TEAM_OVERRIDE:-${AGK_TEAM:-}}"
[ -z "$team" ] && { echo "agkanban add: team unresolved (join agmsg or pass --team)" >&2; exit 1; }

now="$(db_now)"
db_exec "INSERT INTO cards (team,title,col,assignee,reviewer,creator,body,created_at,updated_at)
         VALUES ('$(sql_escape "$team")','$(sql_escape "$TITLE")','todo',
                 $(sql_val "$ASSIGNEE"),$(sql_val "$REVIEWER"),$(sql_val "$creator"),
                 $(sql_val "$BODY"),'$now','$now');"
id="$(db_exec "SELECT last_insert_rowid();")"
echo "card-$id added to $team (todo)"
```

- [ ] **Step 5: Run test and confirm success**

Run: `bash tests/test_transitions.sh`
Expected: `ok: add returns card-1` / `ok: add inserts row (todo, creator=alice)` / `ALL PASS`

- [ ] **Step 6: Commit**

```bash
git add scripts/agkanban.sh scripts/add.sh tests/test_transitions.sh
git commit -m "feat: add dispatcher and add subcommand"
```

---

## Task 7: board (listing)

**Files:**
- Create: `scripts/board.sh`
- Modify: `tests/test_transitions.sh`

- [ ] **Step 1: Append a failing test (board)**

Insert before `finish`:

```bash
# --- Task 7: board ---
out="$(bash "$AGK" board)"
assert_contains "$out" "todo" "board shows todo column"
assert_contains "$out" "card-1" "board lists card-1"
assert_contains "$out" "first task" "board shows title"
```

- [ ] **Step 2: Run test and confirm failure**

Run: `bash tests/test_transitions.sh`
Expected: FAIL (`board.sh` does not exist yet)

- [ ] **Step 3: Write board.sh**

`scripts/board.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib/storage.sh"
source "$DIR/lib/agmsg.sh"

TEAM_OVERRIDE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --team) TEAM_OVERRIDE="$2"; shift 2 ;;
    *) echo "agkanban board: unexpected arg: $1" >&2; exit 2 ;;
  esac
done

ensure_db
agmsg_identity "${AGK_TYPE:-claude-code}" || true
team="${TEAM_OVERRIDE:-${AGK_TEAM:-}}"
[ -z "$team" ] && { echo "agkanban board: team unresolved (join agmsg or pass --team)" >&2; exit 1; }

echo "# board: $team"
for col in todo doing review done; do
  echo "## $col"
  db_exec "SELECT 'card-'||id||'  '||title||
                  CASE WHEN assignee IS NOT NULL THEN '  @'||assignee ELSE '' END
           FROM cards WHERE team='$(sql_escape "$team")' AND col='$col' ORDER BY id;"
done
```

- [ ] **Step 4: Run test and confirm success**

Run: `bash tests/test_transitions.sh`
Expected: `ok: board shows todo column` / `ok: board lists card-1` / `ok: board shows title` / `ALL PASS`

- [ ] **Step 5: Commit**

```bash
git add scripts/board.sh tests/test_transitions.sh
git commit -m "feat: add board subcommand"
```

---

## Task 8: move + event fire

**Files:**
- Create: `scripts/move.sh`
- Modify: `tests/test_transitions.sh`

- [ ] **Step 1: Append failing tests (move and notifications)**

Insert before `finish`:

```bash
# --- Task 8: move + notifications ---
: > "$AGK_TEST_SENT"
bash "$AGK" move 1 doing >/dev/null      # card-1 assignee=bob
sent="$(cat "$AGK_TEST_SENT")"
assert_contains "$sent" "dev|alice|bob|" "move->doing notifies assignee"
assert_contains "$sent" "card-1 start requested" "doing message has card ref + label"
col="$(sqlite3 "$TMP/board.db" "SELECT col FROM cards WHERE id=1;")"
assert_eq "$col" "doing" "move updates column to doing"
ev="$(sqlite3 "$TMP/board.db" "SELECT from_col||'->'||to_col FROM card_events WHERE card_id=1 ORDER BY id DESC LIMIT 1;")"
assert_eq "$ev" "todo->doing" "move logs card_event"

: > "$AGK_TEST_SENT"
bash "$AGK" move 1 review >/dev/null     # reviewer=carol
assert_contains "$(cat "$AGK_TEST_SENT")" "dev|alice|carol|" "move->review notifies reviewer"

: > "$AGK_TEST_SENT"
bash "$AGK" move 1 done >/dev/null        # creator=alice(=actor,skip), assignee=bob
sent="$(cat "$AGK_TEST_SENT")"
assert_contains "$sent" "dev|alice|bob|" "move->done notifies assignee (creator=self skipped)"
assert_contains "$sent" "card-1 done" "done message has card ref + label"

# no reviewer set: notify creator
bash "$AGK" add "no reviewer" --assignee bob >/dev/null   # card-2 creator=alice
: > "$AGK_TEST_SENT"
bash "$AGK" move 2 review >/dev/null
assert_contains "$(cat "$AGK_TEST_SENT")" "dev|alice|alice|" "review w/o reviewer falls back to creator"
```

Note: the last assertion is for creator=alice=actor=alice, which hits `agmsg_send`'s
self-send skip. **It is intentionally skipped**, so `alice|alice` never appears in
`sent.log`. Update the test to match actual behavior:

```bash
# Replace the last 2 lines of the block above with:
: > "$AGK_TEST_SENT"
bash "$AGK" move 2 review >/dev/null
assert_eq "$(cat "$AGK_TEST_SENT")" "" "review w/o reviewer -> creator==self -> skipped (no send)"
```

- [ ] **Step 2: Run test and confirm failure**

Run: `bash tests/test_transitions.sh`
Expected: FAIL (`move.sh` does not exist yet)

- [ ] **Step 3: Write move.sh**

`scripts/move.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib/storage.sh"
source "$DIR/lib/agmsg.sh"
source "$DIR/lib/events.sh"

TEAM_OVERRIDE=""; ID_ARG=""; TO_COL=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --team) TEAM_OVERRIDE="$2"; shift 2 ;;
    *) if [ -z "$ID_ARG" ]; then ID_ARG="$1"; elif [ -z "$TO_COL" ]; then TO_COL="$1"; else echo "agkanban move: unexpected arg: $1" >&2; exit 2; fi; shift ;;
  esac
done
num="$(card_num "$ID_ARG")" || exit 2
case "$TO_COL" in todo|doing|review|done) ;; *) echo "agkanban move: column must be todo|doing|review|done" >&2; exit 2 ;; esac

ensure_db
agmsg_identity "${AGK_TYPE:-claude-code}" || true
actor="${AGK_AGENT:-}"
team="${TEAM_OVERRIDE:-${AGK_TEAM:-}}"
[ -z "$team" ] && { echo "agkanban move: team unresolved (join agmsg or pass --team)" >&2; exit 1; }

row="$(db_exec "SELECT col,title,COALESCE(assignee,''),COALESCE(reviewer,''),COALESCE(creator,'')
                FROM cards WHERE id=$num AND team='$(sql_escape "$team")';")"
[ -z "$row" ] && { echo "agkanban move: card-$num not found in team $team" >&2; exit 1; }
IFS='|' read -r from_col title assignee reviewer creator <<EOF
$row
EOF

now="$(db_now)"
db_exec "UPDATE cards SET col='$TO_COL', updated_at='$now' WHERE id=$num AND team='$(sql_escape "$team")';
         INSERT INTO card_events (card_id,team,actor,from_col,to_col,at)
         VALUES ($num,'$(sql_escape "$team")',$(sql_val "$actor"),'$from_col','$TO_COL','$now');"

fire_transition "$team" "$actor" "$num" "$title" "$TO_COL" "$assignee" "$reviewer" "$creator"
[ "$TO_COL" = "done" ] && fire_unblock "$team" "$actor" "$num"
echo "card-$num: $from_col -> $TO_COL"
```

- [ ] **Step 4: Run test and confirm success**

Run: `bash tests/test_transitions.sh`
Expected: all added move assertions show `ok:` / `ALL PASS`

- [ ] **Step 5: Commit**

```bash
git add scripts/move.sh tests/test_transitions.sh
git commit -m "feat: add move subcommand with event-driven agmsg notifications"
```

---

## Task 9: claim (atomic)

**Files:**
- Create: `scripts/claim.sh`
- Modify: `tests/test_transitions.sh`

- [ ] **Step 1: Append failing tests (claim and conflict)**

Insert before `finish`:

```bash
# --- Task 9: claim + conflict ---
bash "$AGK" add "claimable" >/dev/null    # card-3, assignee=NULL
: > "$AGK_TEST_SENT"
out="$(AGK_AGENT=bob AGK_TEAM=dev bash "$AGK" claim 3)"
assert_contains "$out" "card-3" "claim by bob succeeds"
row="$(sqlite3 "$TMP/board.db" "SELECT col,assignee FROM cards WHERE id=3;")"
assert_eq "$row" "doing|bob" "claim sets doing + assignee=bob"
assert_contains "$(cat "$AGK_TEST_SENT")" "dev|bob|bob|" "claim self-assign -> self -> skipped"

# Second claim by carol fails (bob already holds it)
set +e
out2="$(AGK_AGENT=carol AGK_TEAM=dev bash "$AGK" claim 3 2>&1)"
rc=$?
set -e
assert_eq "$rc" "1" "second claim by carol exits 1"
assert_contains "$out2" "already claimed" "second claim reports conflict"
```

Note: `claim self-assign -> self -> skipped` — assignee=bob, actor=bob, so the send is
skipped as self-notification. Expected value is empty. Update to match actual behavior:

```bash
# Replace the claim notification assertion above with:
assert_eq "$(cat "$AGK_TEST_SENT")" "" "claim self-assign -> actor==assignee -> no send"
```

- [ ] **Step 2: Run test and confirm failure**

Run: `bash tests/test_transitions.sh`
Expected: FAIL (`claim.sh` does not exist yet)

- [ ] **Step 3: Write claim.sh**

`scripts/claim.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib/storage.sh"
source "$DIR/lib/agmsg.sh"
source "$DIR/lib/events.sh"

TEAM_OVERRIDE=""; ID_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --team) TEAM_OVERRIDE="$2"; shift 2 ;;
    *) if [ -z "$ID_ARG" ]; then ID_ARG="$1"; else echo "agkanban claim: unexpected arg: $1" >&2; exit 2; fi; shift ;;
  esac
done
num="$(card_num "$ID_ARG")" || exit 2

ensure_db
agmsg_identity "${AGK_TYPE:-claude-code}" || true
me="${AGK_AGENT:-}"
team="${TEAM_OVERRIDE:-${AGK_TEAM:-}}"
[ -z "$me" ] && { echo "agkanban claim: agent unresolved (join agmsg)" >&2; exit 1; }
[ -z "$team" ] && { echo "agkanban claim: team unresolved (join agmsg or pass --team)" >&2; exit 1; }

# Pre-transition data (title, current column). If missing: not found.
row="$(db_exec "SELECT col,title,COALESCE(reviewer,''),COALESCE(creator,'') FROM cards WHERE id=$num AND team='$(sql_escape "$team")';")"
[ -z "$row" ] && { echo "agkanban claim: card-$num not found in team $team" >&2; exit 1; }
IFS='|' read -r from_col title reviewer creator <<EOF
$row
EOF

# Atomic claim: run UPDATE and changes() in the same connection.
now="$(db_now)"
changed="$(db_exec "UPDATE cards SET assignee='$(sql_escape "$me")', col='doing', updated_at='$now'
                    WHERE id=$num AND team='$(sql_escape "$team")' AND (assignee IS NULL OR assignee='$(sql_escape "$me")');
                    SELECT changes();")"
if [ "$changed" = "0" ]; then
  echo "agkanban: card-$num already claimed by someone else" >&2
  exit 1
fi

db_exec "INSERT INTO card_events (card_id,team,actor,from_col,to_col,at)
         VALUES ($num,'$(sql_escape "$team")','$(sql_escape "$me")','$from_col','doing','$now');"
fire_transition "$team" "$me" "$num" "$title" "doing" "$me" "$reviewer" "$creator"
echo "card-$num claimed by $me (doing)"
```

- [ ] **Step 4: Run test and confirm success**

Run: `bash tests/test_transitions.sh`
Expected: all claim assertions show `ok:` / `ALL PASS`

- [ ] **Step 5: Commit**

```bash
git add scripts/claim.sh tests/test_transitions.sh
git commit -m "feat: add atomic claim subcommand"
```

---

## Task 10: mine (no-arg default)

**Files:**
- Create: `scripts/mine.sh`
- Modify: `tests/test_transitions.sh`

- [ ] **Step 1: Append failing tests (mine and no-arg identical behavior)**

Insert before `finish`:

```bash
# --- Task 10: mine (no-arg = mine) ---
# bob has card-1(done) and card-3(doing). Only doing/review are listed → card-3 only.
mine_bob="$(AGK_AGENT=bob AGK_TEAM=dev bash "$AGK" mine)"
assert_contains "$mine_bob" "card-3" "mine lists bob's doing card"
assert_not_contains "$mine_bob" "card-1" "mine excludes done card"
# no-arg is identical to mine
noarg_bob="$(AGK_AGENT=bob AGK_TEAM=dev bash "$AGK")"
assert_eq "$noarg_bob" "$mine_bob" "no-arg behaves like mine"
```

- [ ] **Step 2: Run test and confirm failure**

Run: `bash tests/test_transitions.sh`
Expected: FAIL (`mine.sh` does not exist yet)

- [ ] **Step 3: Write mine.sh**

`scripts/mine.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib/storage.sh"
source "$DIR/lib/agmsg.sh"

TEAM_OVERRIDE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --team) TEAM_OVERRIDE="$2"; shift 2 ;;
    *) echo "agkanban mine: unexpected arg: $1" >&2; exit 2 ;;
  esac
done

ensure_db
agmsg_identity "${AGK_TYPE:-claude-code}" || true
me="${AGK_AGENT:-}"
team="${TEAM_OVERRIDE:-${AGK_TEAM:-}}"
[ -z "$me" ] && { echo "agkanban mine: agent unresolved (join agmsg)" >&2; exit 1; }
[ -z "$team" ] && { echo "agkanban mine: team unresolved (join agmsg or pass --team)" >&2; exit 1; }

echo "# mine: $me @ $team (doing/review)"
db_exec "SELECT 'card-'||id||'  ['||col||']  '||title
         FROM cards
         WHERE team='$(sql_escape "$team")' AND assignee='$(sql_escape "$me")'
           AND col IN ('doing','review')
         ORDER BY col, id;"
```

- [ ] **Step 4: Run test and confirm success**

Run: `bash tests/test_transitions.sh`
Expected: all mine assertions show `ok:` / `ALL PASS`

- [ ] **Step 5: Commit**

```bash
git add scripts/mine.sh tests/test_transitions.sh
git commit -m "feat: add mine subcommand (also the no-arg default)"
```

---

## Task 11: show (detail + history)

**Files:**
- Create: `scripts/show.sh`
- Modify: `tests/test_transitions.sh`

- [ ] **Step 1: Append a failing test (show)**

Insert before `finish`:

```bash
# --- Task 11: show ---
out="$(bash "$AGK" show 1)"
assert_contains "$out" "card-1" "show prints card id"
assert_contains "$out" "first task" "show prints title"
assert_contains "$out" "todo->doing" "show prints event history"
```

- [ ] **Step 2: Run test and confirm failure**

Run: `bash tests/test_transitions.sh`
Expected: FAIL (`show.sh` does not exist yet)

- [ ] **Step 3: Write show.sh**

`scripts/show.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib/storage.sh"
source "$DIR/lib/agmsg.sh"

TEAM_OVERRIDE=""; ID_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --team) TEAM_OVERRIDE="$2"; shift 2 ;;
    *) if [ -z "$ID_ARG" ]; then ID_ARG="$1"; else echo "agkanban show: unexpected arg: $1" >&2; exit 2; fi; shift ;;
  esac
done
num="$(card_num "$ID_ARG")" || exit 2

ensure_db
agmsg_identity "${AGK_TYPE:-claude-code}" || true
team="${TEAM_OVERRIDE:-${AGK_TEAM:-}}"
[ -z "$team" ] && { echo "agkanban show: team unresolved (join agmsg or pass --team)" >&2; exit 1; }

row="$(db_exec "SELECT 'card-'||id||'  ['||col||']  '||title||char(10)||
                       'assignee: '||COALESCE(assignee,'-')||'   reviewer: '||COALESCE(reviewer,'-')||
                       '   creator: '||COALESCE(creator,'-')||
                       CASE WHEN blocked_by IS NOT NULL THEN char(10)||'blocked_by: card-'||blocked_by ELSE '' END||
                       CASE WHEN body IS NOT NULL THEN char(10)||char(10)||body ELSE '' END
                FROM cards WHERE id=$num AND team='$(sql_escape "$team")';")"
[ -z "$row" ] && { echo "agkanban show: card-$num not found in team $team" >&2; exit 1; }
printf '%s\n\n' "$row"
echo "## history"
db_exec "SELECT at||'  '||COALESCE(actor,'?')||'  '||from_col||'->'||to_col
         FROM card_events WHERE card_id=$num AND team='$(sql_escape "$team")' ORDER BY id;"
```

- [ ] **Step 4: Run test and confirm success**

Run: `bash tests/test_transitions.sh`
Expected: all show assertions show `ok:` / `ALL PASS`

- [ ] **Step 5: Commit**

```bash
git add scripts/show.sh tests/test_transitions.sh
git commit -m "feat: add show subcommand (detail + event history)"
```

---

## Task 12: block + unblock notification + fallback

**Files:**
- Create: `scripts/block.sh`
- Modify: `tests/test_transitions.sh`

- [ ] **Step 1: Append failing tests (block / unblock / fallback)**

Insert before `finish`:

```bash
# --- Task 12: block + unblock ---
bash "$AGK" add "blocker" --assignee bob >/dev/null     # card-4
bash "$AGK" add "waiter"  --assignee carol >/dev/null    # card-5
bash "$AGK" block 5 --by 4 >/dev/null
bb="$(sqlite3 "$TMP/board.db" "SELECT blocked_by FROM cards WHERE id=5;")"
assert_eq "$bb" "4" "block sets blocked_by"

: > "$AGK_TEST_SENT"
bash "$AGK" move 4 done >/dev/null                       # card-4 done -> unblock card-5
sent="$(cat "$AGK_TEST_SENT")"
assert_contains "$sent" "dev|alice|carol|" "unblock notifies waiter's assignee"
assert_contains "$sent" "card-5 unblocked" "unblock message references both cards"

# --- Fallback: state transition succeeds even when the notify command fails ---
cat > "$TMP/fail.sh" <<'F'
#!/usr/bin/env bash
exit 1
F
chmod +x "$TMP/fail.sh"
out="$(AGMSG_SEND_CMD="$TMP/fail.sh" bash "$AGK" move 5 doing 2>/dev/null)"
assert_contains "$out" "card-5: " "move succeeds even when notify fails"
col5="$(sqlite3 "$TMP/board.db" "SELECT col FROM cards WHERE id=5;")"
assert_eq "$col5" "doing" "state transition persists despite notify failure"
```

- [ ] **Step 2: Run test and confirm failure**

Run: `bash tests/test_transitions.sh`
Expected: FAIL (`block.sh` does not exist yet)

- [ ] **Step 3: Write block.sh**

`scripts/block.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib/storage.sh"
source "$DIR/lib/agmsg.sh"

TEAM_OVERRIDE=""; ID_ARG=""; BY_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --by)   BY_ARG="$2"; shift 2 ;;
    --team) TEAM_OVERRIDE="$2"; shift 2 ;;
    *) if [ -z "$ID_ARG" ]; then ID_ARG="$1"; else echo "agkanban block: unexpected arg: $1" >&2; exit 2; fi; shift ;;
  esac
done
num="$(card_num "$ID_ARG")" || exit 2
[ -z "$BY_ARG" ] && { echo "agkanban block: --by <id> required" >&2; exit 2; }
by="$(card_num "$BY_ARG")" || exit 2

ensure_db
agmsg_identity "${AGK_TYPE:-claude-code}" || true
team="${TEAM_OVERRIDE:-${AGK_TEAM:-}}"
[ -z "$team" ] && { echo "agkanban block: team unresolved (join agmsg or pass --team)" >&2; exit 1; }

now="$(db_now)"
changed="$(db_exec "UPDATE cards SET blocked_by=$by, updated_at='$now'
                    WHERE id=$num AND team='$(sql_escape "$team")'; SELECT changes();")"
[ "$changed" = "0" ] && { echo "agkanban block: card-$num not found in team $team" >&2; exit 1; }
echo "card-$num blocked by card-$by"
```

- [ ] **Step 4: Run test and confirm success**

Run: `bash tests/test_transitions.sh`
Expected: all block / unblock / fallback assertions show `ok:` / `ALL PASS`

- [ ] **Step 5: Commit**

```bash
git add scripts/block.sh tests/test_transitions.sh
git commit -m "feat: add block subcommand + unblock notification on done"
```

---

## Task 13: SKILL.md / README / LICENSE / .gitignore

**Files:**
- Create: `SKILL.md`, `README.md`, `LICENSE`, `.gitignore`

- [ ] **Step 1: Write .gitignore**

`.gitignore`:

```
db/
*.db
*.db-shm
*.db-wal
```

- [ ] **Step 2: Write SKILL.md**

`SKILL.md`:

```markdown
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

All commands run as `scripts/agkanban.sh <subcommand>`. No arguments defaults to `mine`.

| Command | Action |
|---|---|
| `scripts/agkanban.sh` | Your assigned cards (= mine) |
| `scripts/agkanban.sh mine` | Your doing/review cards |
| `scripts/agkanban.sh board` | Full team board |
| `scripts/agkanban.sh add "<title>" [--assignee X] [--reviewer Y] [--body "..."]` | Add card (todo) |
| `scripts/agkanban.sh move <id> <todo\|doing\|review\|done>` | Column transition (triggers agmsg auto-notify) |
| `scripts/agkanban.sh claim <id>` | Set assignee=self and move to doing (atomic) |
| `scripts/agkanban.sh show <id>` | Card detail + event history |
| `scripts/agkanban.sh block <id> --by <id2>` | Set dependency |

Pass `--team <name>` on each command when you belong to multiple teams.

## Delivery (awareness)

agkanban has no dedicated monitor. Notifications fired on transitions are delivered by
**agmsg's delivery mechanism (turn/monitor/hook)**. Because state is persistent, running
`mine` / `board` on demand is sufficient to catch up without missing anything.

## Notification mapping

| Transition | Recipient |
|---|---|
| → doing | assignee |
| → review | reviewer (falls back to creator) |
| → done | creator (+ assignee if different) |
| dependency done | assignee of the waiting card |

Notifications to yourself are suppressed.
```

- [ ] **Step 3: Write README.md**

`README.md`:

````markdown
# agkanban

Multi-agent kanban task board that pairs with [agmsg](https://github.com/). State lives in a
per-team SQLite board; moving a card auto-notifies teammates through agmsg (event-driven).
Built with bash + sqlite3 — no daemon, no network.

## Install

**skills.sh (recommended)** — installs globally to `~/.agents/skills`:

```bash
npx --yes skills add lucianlamp/agkanban -g -y
```

**gh CLI (alternative, preview)**:

```bash
gh skill install lucianlamp/agkanban --agent claude-code --scope user
```

> agkanban works best paired with agmsg. Install agmsg first and join your team.
> Board operations work without agmsg, but notifications are skipped.

## Quick start

```bash
scripts/agkanban.sh add "design API" --assignee codex --reviewer claude
scripts/agkanban.sh claim 1        # claim (assignee=self, move to doing, atomic)
scripts/agkanban.sh move 1 review  # auto-notifies reviewer
scripts/agkanban.sh                # no args = your assigned cards (mine)
scripts/agkanban.sh board          # full board
```

## How it works

- **State**: `db/board.db` (per team). Override with `AGKANBAN_STORAGE_PATH`.
- **Identity**: borrows team/agent from agmsg's `whoami.sh` (searches `AGMSG_HOME`, sibling dir, `~/.agents/skills/agmsg`).
- **Notifications**: fires agmsg's `send.sh` on column transitions (swappable via `AGMSG_SEND_CMD` for testing).
- **Delivery**: piggybacks on agmsg's turn/monitor/hook. agkanban has no dedicated monitor.

## Test

```bash
bash tests/test_transitions.sh
```

## License

MIT
````

- [ ] **Step 4: Write LICENSE**

`LICENSE` (MIT. `<YEAR>` = 2026, `<COPYRIGHT HOLDER>` = lucianlamp):

```
MIT License

Copyright (c) 2026 lucianlamp

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 5: Re-run all tests (regression check)**

Run: `bash tests/test_transitions.sh`
Expected: `ALL PASS`

- [ ] **Step 6: Set executable permissions + Commit**

```bash
chmod +x scripts/agkanban.sh scripts/*.sh
git add SKILL.md README.md LICENSE .gitignore
git update-index --chmod=+x scripts/agkanban.sh scripts/init-db.sh scripts/add.sh scripts/move.sh scripts/claim.sh scripts/mine.sh scripts/show.sh scripts/board.sh scripts/block.sh
git commit -m "docs: add SKILL.md, README, LICENSE, gitignore; mark scripts executable"
```

---

## Task 14: GitHub publish preparation (create private → push)

**Files:**
- None (git/gh operations only)

> The user specified "make it public later after polishing." Start with private and push.
> Make public later with user approval (`gh repo edit --visibility public`).

- [ ] **Step 1: Final local verification**

Run:
```bash
cd ~/dev/agkanban
bash tests/test_transitions.sh
for f in scripts/*.sh scripts/lib/*.sh; do bash -n "$f" || echo "SYNTAX FAIL: $f"; done
```
Expected: `ALL PASS` and no syntax errors

- [ ] **Step 2: Create private remote and push (if not yet created)**

Run:
```bash
cd ~/dev/agkanban
gh repo view lucianlamp/agkanban >/dev/null 2>&1 \
  || gh repo create lucianlamp/agkanban --private --source=. --remote=origin --description "Multi-agent kanban board that pairs with agmsg"
git push -u origin "$(git symbolic-ref --short HEAD)"
```
Expected: repo created (or existing detected) then push succeeds

- [ ] **Step 3: Verify install one-liner (gh path)**

Run:
```bash
gh skill install lucianlamp/agkanban --agent claude-code --scope user
ls -ld ~/.agents/skills/agkanban && head -3 ~/.agents/skills/agkanban/SKILL.md
```
Expected: expanded to `~/.agents/skills/agkanban/`; SKILL.md frontmatter visible

- [ ] **Step 4: Post-install production path smoke test (agmsg discovery)**

Run:
```bash
AGK_AGENT="" AGK_TEAM="" bash ~/.agents/skills/agkanban/scripts/agkanban.sh --help
```
Expected: usage displayed (no crash on agmsg sibling discovery path)

> Final production notification integration test (real agmsg send): join an agmsg team,
> run `agkanban add` → `agkanban move ... doing`, and verify the message arrives in the
> recipient's inbox (Claude verifies locally).

---

## Self-Review

**1. Spec coverage (spec sections → implementation tasks):**
- §2.1 event-driven coupling → Task 8 (move fire), Task 5 (events)
- §2.2 per-team scope → all commands filter by team (Task 6–12)
- §2.3 independent board.db → Task 2/3
- §2.4 identity borrowing + discovery fallback → Task 4 (agmsg.sh)
- §2.5 piggyback delivery + pull / no-arg=mine → Task 10, Task 6 (dispatcher no-arg)
- §3.2 data model → Task 3
- §3.3 notification mapping table → Task 5/8
- §3.5 claim atomicity → Task 9 (UPDATE+changes() in same connection)
- §3.5 fallback → Task 12 (transition succeeds despite notify failure)
- §4 command interface → Task 6–12 + dispatcher
- §5 directory layout → all tasks
- §6 testing → per-task TDD + Task 1 harness
- §8 distribution → Task 13 (README/SKILL), Task 14 (gh)
- Gaps: none

**2. Placeholder scan:** No TBD/TODO or vague handling instructions. All code steps contain real code.

**3. Type consistency:**
- To avoid cross-connection `changes()` issues, claim/block run UPDATE and `SELECT changes()` in the **same `db_exec` string** (Task 9/12). Matches `db_exec`'s spec of running multiple statements in one process (Task 2).
- Seam names `AGK_AGENT`/`AGK_TEAM`/`AGKANBAN_STORAGE_PATH`/`AGMSG_SEND_CMD` are consistent across all tasks.
- Self-skip behavior (no send when actor == recipient) accounted for; Task 8/9 notification assertions updated to expect empty output.
- Function names `fire_transition`/`fire_unblock`/`agmsg_send`/`agmsg_identity`/`agmsg_home`/`ensure_db`/`card_num`/`sql_val` match between definitions (Task 2/4/5) and call sites (Task 6–12).
