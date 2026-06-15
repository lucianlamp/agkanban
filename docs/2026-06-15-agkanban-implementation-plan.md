# agkanban Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** agmsg と組み合わせて真価を発揮する、bash + sqlite3 製の kanban 型タスク状態管理スキル `agkanban` を作り、GitHub で配布可能にする。

**Architecture:** 状態は独立 DB `board.db`（team 単位）に永続化。カードの列遷移時に agmsg の `send.sh` を呼んで関係者へ自動通知（イベント駆動結合）。識別（team/agent）は agmsg から借用。push 通知は agmsg の delivery に相乗りし、agkanban は pull コマンド（引数なし = `mine`）のみ提供。

**Tech Stack:** bash, sqlite3（WAL）, git, gh（配布）。テストは依存無しの bash アサーションハーネス。

**設計参照:** `docs/2026-06-15-agkanban-design.md`

---

## File Structure

開発リポジトリ `~/dev/agkanban`（root がそのままスキル本体）。

| ファイル | 責務 |
|---|---|
| `SKILL.md` | スキル本体。識別解決の案内 + サブコマンド分岐の指示 |
| `README.md` | ワンライナー install（skills.sh 主 + gh 代替）+ 使い方 |
| `LICENSE` | MIT |
| `.gitignore` | `db/`（実行時生成物）を無視 |
| `scripts/agkanban.sh` | ディスパッチャ（no-arg = mine）。各サブコマンドへ exec |
| `scripts/lib/storage.sh` | board.db パス解決・DB 実行ヘルパ・SQL エスケープ・timestamp・card id parse |
| `scripts/lib/agmsg.sh` | agmsg 探索・識別解決（whoami）・send ラッパ（`AGMSG_SEND_CMD` seam） |
| `scripts/lib/events.sh` | 遷移→通知マッピングと発火 |
| `scripts/init-db.sh` | スキーマ作成 |
| `scripts/add.sh` | カード追加（todo） |
| `scripts/move.sh` | 列遷移 + イベント発火 |
| `scripts/claim.sh` | 原子的 claim（assignee=自分, doing へ） |
| `scripts/mine.sh` | 自分の doing/review カード（no-arg の既定） |
| `scripts/show.sh` | カード詳細 + イベント履歴 |
| `scripts/board.sh` | team のボード全体 |
| `scripts/block.sh` | 依存設定 |
| `tests/lib_assert.sh` | テスト用アサーションハーネス |
| `tests/test_transitions.sh` | 遷移・claim・通知・フォールバックのテスト |

**重要な設計シーム（テスト容易性）:**
- `AGKANBAN_STORAGE_PATH` — board.db の置き場を差し替え（テストは一時ディレクトリ）
- `AGMSG_SEND_CMD` — 通知送信コマンドを差し替え（テストは記録用スクリプト）
- `AGK_AGENT` / `AGK_TEAM` — 事前設定されていれば whoami を呼ばず識別とみなす（テストでスタブ）

---

## Task 1: テストハーネス

**Files:**
- Create: `tests/lib_assert.sh`

- [ ] **Step 1: アサーションハーネスを書く**

`tests/lib_assert.sh`:

```bash
#!/usr/bin/env bash
# 依存無しの最小アサーションハーネス。各 assert が ASSERT_FAILS を加算する。
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

- [ ] **Step 2: 構文チェック**

Run: `bash -n tests/lib_assert.sh`
Expected: 出力なし・exit 0

- [ ] **Step 3: Commit**

```bash
git add tests/lib_assert.sh
git commit -m "test: add minimal bash assertion harness"
```

---

## Task 2: storage ライブラリ

**Files:**
- Create: `scripts/lib/storage.sh`

- [ ] **Step 1: storage.sh を書く**

`scripts/lib/storage.sh`:

```bash
#!/usr/bin/env bash
# storage.sh — board.db のパス解決と DB 実行ヘルパ。
# 解決順: AGKANBAN_STORAGE_PATH(env) > 既定 <skill>/db

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

# 空なら NULL、それ以外は 'escaped' を返す（SQL リテラル生成用）
sql_val() {
  if [ -z "${1:-}" ]; then printf 'NULL'; else printf "'%s'" "$(sql_escape "$1")"; fi
}

# 1 回の sqlite3 プロセスで SQL を実行（複数文は同一接続 → changes() が有効）
db_exec() { sqlite3 -batch "$(agkanban_db)" "$1"; }

# DB が無ければ init-db.sh で作る
ensure_db() {
  local db; db="$(agkanban_db)"
  if [ ! -f "$db" ]; then
    mkdir -p "$(dirname "$db")"
    bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../init-db.sh"
  fi
}

# "card-12" / "12" を 12 に正規化。非数値は stderr + return 1
card_num() {
  local raw="${1#card-}"
  case "$raw" in
    ''|*[!0-9]*) echo "agkanban: invalid card id: $1" >&2; return 1 ;;
  esac
  printf '%s' "$raw"
}
```

- [ ] **Step 2: 構文チェックとヘルパ単体確認**

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

## Task 3: スキーマ初期化

**Files:**
- Create: `scripts/init-db.sh`
- Test: `tests/test_transitions.sh`（このタスクで雛形を作り、以降のタスクで追記）

- [ ] **Step 1: 失敗するテスト（DB 初期化）を書く**

`tests/test_transitions.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib_assert.sh"

# --- 隔離環境 ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export AGKANBAN_STORAGE_PATH="$TMP"
export AGK_TEST_SENT="$TMP/sent.log"
: > "$AGK_TEST_SENT"

# 通知記録用 recorder（team|from|to|body を 1 行で追記）
cat > "$TMP/recorder.sh" <<'REC'
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$AGK_TEST_SENT"
REC
chmod +x "$TMP/recorder.sh"
export AGMSG_SEND_CMD="$TMP/recorder.sh"

# 識別スタブ（whoami を呼ばせない）
export AGK_AGENT="alice"
export AGK_TEAM="dev"

AGK="$ROOT/scripts/agkanban.sh"

# --- Task 3: DB 初期化 ---
bash "$ROOT/scripts/init-db.sh"
tables="$(sqlite3 "$TMP/board.db" ".tables")"
assert_contains "$tables" "cards" "init-db creates cards table"
assert_contains "$tables" "card_events" "init-db creates card_events table"

finish
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_transitions.sh`
Expected: FAIL（`init-db.sh` が存在しないため `cards`/`card_events` が無い）

- [ ] **Step 3: init-db.sh を書く**

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

- [ ] **Step 4: テストを実行して成功を確認**

Run: `bash tests/test_transitions.sh`
Expected: `ok: init-db creates cards table` / `ok: init-db creates card_events table` / `ALL PASS`

- [ ] **Step 5: Commit**

```bash
git add scripts/init-db.sh tests/test_transitions.sh tests/lib_assert.sh
git commit -m "feat: add board.db schema (init-db) with passing test"
```

---

## Task 4: agmsg ライブラリ（探索・識別・送信）

**Files:**
- Create: `scripts/lib/agmsg.sh`

- [ ] **Step 1: agmsg.sh を書く**

`scripts/lib/agmsg.sh`:

```bash
#!/usr/bin/env bash
# agmsg.sh — agmsg の探索・識別解決・送信ラッパ。
# storage.sh が先に source されている前提（db_exec 等は使わない）。

# agmsg のインストール先を探索（見つからなければ return 1）
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

# 識別解決。成功で AGK_AGENT / AGK_TEAM を設定し return 0。
# 既に両方が env で設定済みなら whoami を呼ばない（テスト/override seam）。
agmsg_identity() {
  if [ -n "${AGK_AGENT:-}" ] && [ -n "${AGK_TEAM:-}" ]; then return 0; fi
  local type="${1:-claude-code}" home out
  home="$(agmsg_home)" || return 1
  out="$(bash "$home/scripts/whoami.sh" "$(pwd)" "$type" 2>/dev/null)" || return 1
  AGK_AGENT="$(printf '%s\n' "$out" | sed -n 's/.*agent=\([^ ]*\).*/\1/p')"
  AGK_TEAM="$(printf '%s\n' "$out" | sed -n 's/.*teams=\([^, ]*\).*/\1/p')"
  [ -n "$AGK_AGENT" ] && [ -n "$AGK_TEAM" ]
}

# 通知送信。宛先が空 or 送信者自身ならスキップ。
# AGMSG_SEND_CMD があればそれを使い、無ければ agmsg の send.sh。
# agmsg 不在/失敗時は警告を出して握りつぶす（状態遷移は止めない）。
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

- [ ] **Step 2: 構文チェックと send seam の確認**

Run:
```bash
bash -n scripts/lib/agmsg.sh && \
TMPL="$(mktemp)" && \
bash -c 'source scripts/lib/agmsg.sh
  export AGMSG_SEND_CMD="/bin/sh -c"  # ダミー（呼ばれないことの確認）
  unset AGMSG_SEND_CMD
  # 宛先が送信者自身 → スキップ（出力なし）
  REC="'"$TMPL"'"; export AGMSG_SEND_CMD="$(command -v printf)"
  agmsg_send dev alice alice "self" ; echo "self-skip-ok"'
```
Expected: 末尾に `self-skip-ok`（自分宛はスキップされ printf は呼ばれない）

- [ ] **Step 3: Commit**

```bash
git add scripts/lib/agmsg.sh
git commit -m "feat: add agmsg lib (discovery, identity, send wrapper)"
```

---

## Task 5: events ライブラリ（遷移→通知）

**Files:**
- Create: `scripts/lib/events.sh`

- [ ] **Step 1: events.sh を書く**

`scripts/lib/events.sh`:

```bash
#!/usr/bin/env bash
# events.sh — 列遷移に対応する通知の発火。
# storage.sh と agmsg.sh が先に source されている前提。

# 直接遷移の通知。
fire_transition() { # team actor card_id title to_col assignee reviewer creator
  local team="$1" actor="$2" card_id="$3" title="$4" to_col="$5" \
        assignee="$6" reviewer="$7" creator="$8"
  local ref="card-$card_id" rcpt
  case "$to_col" in
    doing)
      agmsg_send "$team" "$actor" "$assignee" "[agkanban] $ref 着手依頼: $title" ;;
    review)
      rcpt="$reviewer"; [ -z "$rcpt" ] && rcpt="$creator"
      agmsg_send "$team" "$actor" "$rcpt" "[agkanban] $ref review待ち: $title" ;;
    done)
      agmsg_send "$team" "$actor" "$creator" "[agkanban] $ref 完了: $title"
      if [ -n "$assignee" ] && [ "$assignee" != "$creator" ]; then
        agmsg_send "$team" "$actor" "$assignee" "[agkanban] $ref 完了: $title"
      fi ;;
  esac
}

# 依存解消通知: done になった card に blocked_by で紐づく待ちカードの assignee へ。
fire_unblock() { # team actor done_id
  local team="$1" actor="$2" done_id="$3" rows dep_id dep_assignee
  rows="$(db_exec "SELECT id, COALESCE(assignee,'') FROM cards WHERE team='$(sql_escape "$team")' AND blocked_by=$done_id;")"
  [ -z "$rows" ] && return 0
  while IFS='|' read -r dep_id dep_assignee; do
    [ -z "$dep_id" ] && continue
    agmsg_send "$team" "$actor" "$dep_assignee" \
      "[agkanban] card-$dep_id のブロック解除（card-$done_id 完了）"
  done <<EOF
$rows
EOF
}
```

- [ ] **Step 2: 構文チェック**

Run: `bash -n scripts/lib/events.sh`
Expected: 出力なし・exit 0

- [ ] **Step 3: Commit**

```bash
git add scripts/lib/events.sh
git commit -m "feat: add events lib (transition + unblock notifications)"
```

---

## Task 6: ディスパッチャ + add

**Files:**
- Create: `scripts/agkanban.sh`, `scripts/add.sh`
- Modify: `tests/test_transitions.sh`（add のテストを追記）

- [ ] **Step 1: 失敗するテスト（add）を追記**

`tests/test_transitions.sh` の `finish` の直前に挿入:

```bash
# --- Task 6: add ---
out="$(bash "$AGK" add "first task" --assignee bob --reviewer carol)"
assert_contains "$out" "card-1" "add returns card-1"
row="$(sqlite3 "$TMP/board.db" "SELECT team,col,assignee,reviewer,creator,title FROM cards WHERE id=1;")"
assert_eq "$row" "dev|todo|bob|carol|alice|first task" "add inserts row (todo, creator=alice)"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_transitions.sh`
Expected: FAIL（`agkanban.sh` / `add.sh` が無い）

- [ ] **Step 3: ディスパッチャを書く**

`scripts/agkanban.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
sub="${1:-mine}"        # 引数なし = mine
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
agkanban — agmsg と組み合わせる kanban 型タスク管理
  agkanban                       自分の担当カード（= mine）
  agkanban mine                  自分の doing/review カード
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
```

- [ ] **Step 4: add.sh を書く**

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
agmsg_identity "${AGK_TYPE:-claude-code}" || true   # 未解決でも creator 空で続行可
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

- [ ] **Step 5: テストを実行して成功を確認**

Run: `bash tests/test_transitions.sh`
Expected: `ok: add returns card-1` / `ok: add inserts row (todo, creator=alice)` / `ALL PASS`

- [ ] **Step 6: Commit**

```bash
git add scripts/agkanban.sh scripts/add.sh tests/test_transitions.sh
git commit -m "feat: add dispatcher and add subcommand"
```

---

## Task 7: board（一覧表示）

**Files:**
- Create: `scripts/board.sh`
- Modify: `tests/test_transitions.sh`

- [ ] **Step 1: 失敗するテスト（board）を追記**

`finish` 直前に挿入:

```bash
# --- Task 7: board ---
out="$(bash "$AGK" board)"
assert_contains "$out" "todo" "board shows todo column"
assert_contains "$out" "card-1" "board lists card-1"
assert_contains "$out" "first task" "board shows title"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_transitions.sh`
Expected: FAIL（`board.sh` が無い）

- [ ] **Step 3: board.sh を書く**

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

- [ ] **Step 4: テストを実行して成功を確認**

Run: `bash tests/test_transitions.sh`
Expected: `ok: board shows todo column` / `ok: board lists card-1` / `ok: board shows title` / `ALL PASS`

- [ ] **Step 5: Commit**

```bash
git add scripts/board.sh tests/test_transitions.sh
git commit -m "feat: add board subcommand"
```

---

## Task 8: move + イベント発火

**Files:**
- Create: `scripts/move.sh`
- Modify: `tests/test_transitions.sh`

- [ ] **Step 1: 失敗するテスト（move と通知）を追記**

`finish` 直前に挿入:

```bash
# --- Task 8: move + 通知 ---
: > "$AGK_TEST_SENT"
bash "$AGK" move 1 doing >/dev/null      # card-1 assignee=bob
sent="$(cat "$AGK_TEST_SENT")"
assert_contains "$sent" "dev|alice|bob|" "move->doing notifies assignee"
assert_contains "$sent" "card-1 着手依頼" "doing message has card ref + label"
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
assert_contains "$sent" "card-1 完了" "done message has card ref + label"

# reviewer 未設定なら creator に通知
bash "$AGK" add "no reviewer" --assignee bob >/dev/null   # card-2 creator=alice
: > "$AGK_TEST_SENT"
bash "$AGK" move 2 review >/dev/null
assert_contains "$(cat "$AGK_TEST_SENT")" "dev|alice|alice|" "review w/o reviewer falls back to creator"
```

注: 最後のアサーションは creator=alice=actor=alice のため `agmsg_send` の自己宛スキップに引っかかる。**意図的にスキップされる**ので、`sent.log` に `alice|alice` は現れない。テストを実態に合わせて次のように修正する:

```bash
# 上記ブロックの最後2行を以下に置き換える:
: > "$AGK_TEST_SENT"
bash "$AGK" move 2 review >/dev/null
assert_eq "$(cat "$AGK_TEST_SENT")" "" "review w/o reviewer -> creator==self -> skipped (no send)"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_transitions.sh`
Expected: FAIL（`move.sh` が無い）

- [ ] **Step 3: move.sh を書く**

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

- [ ] **Step 4: テストを実行して成功を確認**

Run: `bash tests/test_transitions.sh`
Expected: 追加した move 系アサーションがすべて `ok:` / `ALL PASS`

- [ ] **Step 5: Commit**

```bash
git add scripts/move.sh tests/test_transitions.sh
git commit -m "feat: add move subcommand with event-driven agmsg notifications"
```

---

## Task 9: claim（原子的）

**Files:**
- Create: `scripts/claim.sh`
- Modify: `tests/test_transitions.sh`

- [ ] **Step 1: 失敗するテスト（claim と競合）を追記**

`finish` 直前に挿入:

```bash
# --- Task 9: claim + 競合 ---
bash "$AGK" add "claimable" >/dev/null    # card-3, assignee=NULL
: > "$AGK_TEST_SENT"
out="$(AGK_AGENT=bob AGK_TEAM=dev bash "$AGK" claim 3)"
assert_contains "$out" "card-3" "claim by bob succeeds"
row="$(sqlite3 "$TMP/board.db" "SELECT col,assignee FROM cards WHERE id=3;")"
assert_eq "$row" "doing|bob" "claim sets doing + assignee=bob"
assert_contains "$(cat "$AGK_TEST_SENT")" "dev|bob|bob|" "claim self-assign -> self -> skipped"

# 2人目 carol の claim は失敗（既に bob 保有）
set +e
out2="$(AGK_AGENT=carol AGK_TEAM=dev bash "$AGK" claim 3 2>&1)"
rc=$?
set -e
assert_eq "$rc" "1" "second claim by carol exits 1"
assert_contains "$out2" "already claimed" "second claim reports conflict"
```

注: `claim self-assign -> self -> skipped` は assignee=bob, actor=bob で自己宛のため送信されない。期待値は空。実態に合わせ次に修正:

```bash
# 上の claim 通知アサーションを置き換え:
assert_eq "$(cat "$AGK_TEST_SENT")" "" "claim self-assign -> actor==assignee -> no send"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_transitions.sh`
Expected: FAIL（`claim.sh` が無い）

- [ ] **Step 3: claim.sh を書く**

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

# 遷移前情報（タイトル・元列）。存在しないなら not found。
row="$(db_exec "SELECT col,title,COALESCE(reviewer,''),COALESCE(creator,'') FROM cards WHERE id=$num AND team='$(sql_escape "$team")';")"
[ -z "$row" ] && { echo "agkanban claim: card-$num not found in team $team" >&2; exit 1; }
IFS='|' read -r from_col title reviewer creator <<EOF
$row
EOF

# 原子的 claim: 同一接続で UPDATE と changes() を実行。
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

- [ ] **Step 4: テストを実行して成功を確認**

Run: `bash tests/test_transitions.sh`
Expected: claim 系アサーションすべて `ok:` / `ALL PASS`

- [ ] **Step 5: Commit**

```bash
git add scripts/claim.sh tests/test_transitions.sh
git commit -m "feat: add atomic claim subcommand"
```

---

## Task 10: mine（no-arg 既定）

**Files:**
- Create: `scripts/mine.sh`
- Modify: `tests/test_transitions.sh`

- [ ] **Step 1: 失敗するテスト（mine と no-arg 同一挙動）を追記**

`finish` 直前に挿入:

```bash
# --- Task 10: mine（no-arg = mine）---
# bob は card-1(done)・card-3(doing) を持つ。doing/review のみ列挙 → card-3 のみ。
mine_bob="$(AGK_AGENT=bob AGK_TEAM=dev bash "$AGK" mine)"
assert_contains "$mine_bob" "card-3" "mine lists bob's doing card"
assert_not_contains "$mine_bob" "card-1" "mine excludes done card"
# no-arg は mine と同一
noarg_bob="$(AGK_AGENT=bob AGK_TEAM=dev bash "$AGK")"
assert_eq "$noarg_bob" "$mine_bob" "no-arg behaves like mine"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_transitions.sh`
Expected: FAIL（`mine.sh` が無い）

- [ ] **Step 3: mine.sh を書く**

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

- [ ] **Step 4: テストを実行して成功を確認**

Run: `bash tests/test_transitions.sh`
Expected: mine 系アサーションすべて `ok:` / `ALL PASS`

- [ ] **Step 5: Commit**

```bash
git add scripts/mine.sh tests/test_transitions.sh
git commit -m "feat: add mine subcommand (also the no-arg default)"
```

---

## Task 11: show（詳細 + 履歴）

**Files:**
- Create: `scripts/show.sh`
- Modify: `tests/test_transitions.sh`

- [ ] **Step 1: 失敗するテスト（show）を追記**

`finish` 直前に挿入:

```bash
# --- Task 11: show ---
out="$(bash "$AGK" show 1)"
assert_contains "$out" "card-1" "show prints card id"
assert_contains "$out" "first task" "show prints title"
assert_contains "$out" "todo->doing" "show prints event history"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_transitions.sh`
Expected: FAIL（`show.sh` が無い）

- [ ] **Step 3: show.sh を書く**

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

- [ ] **Step 4: テストを実行して成功を確認**

Run: `bash tests/test_transitions.sh`
Expected: show 系アサーションすべて `ok:` / `ALL PASS`

- [ ] **Step 5: Commit**

```bash
git add scripts/show.sh tests/test_transitions.sh
git commit -m "feat: add show subcommand (detail + event history)"
```

---

## Task 12: block + unblock 通知 + フォールバック

**Files:**
- Create: `scripts/block.sh`
- Modify: `tests/test_transitions.sh`

- [ ] **Step 1: 失敗するテスト（block / unblock / フォールバック）を追記**

`finish` 直前に挿入:

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
assert_contains "$sent" "card-5 のブロック解除" "unblock message references both cards"

# --- フォールバック: 通知コマンドが失敗しても状態遷移は成功 ---
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

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash tests/test_transitions.sh`
Expected: FAIL（`block.sh` が無い）

- [ ] **Step 3: block.sh を書く**

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

- [ ] **Step 4: テストを実行して成功を確認**

Run: `bash tests/test_transitions.sh`
Expected: block / unblock / フォールバック系すべて `ok:` / `ALL PASS`

- [ ] **Step 5: Commit**

```bash
git add scripts/block.sh tests/test_transitions.sh
git commit -m "feat: add block subcommand + unblock notification on done"
```

---

## Task 13: SKILL.md / README / LICENSE / .gitignore

**Files:**
- Create: `SKILL.md`, `README.md`, `LICENSE`, `.gitignore`

- [ ] **Step 1: .gitignore を書く**

`.gitignore`:

```
db/
*.db
*.db-shm
*.db-wal
```

- [ ] **Step 2: SKILL.md を書く**

`SKILL.md`:

```markdown
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

すべて `scripts/agkanban.sh <subcommand>` を実行する。引数なしは `mine`。

| コマンド | 動作 |
|---|---|
| `scripts/agkanban.sh` | 自分の担当カード（= mine） |
| `scripts/agkanban.sh mine` | 自分の doing/review カード |
| `scripts/agkanban.sh board` | team のボード全体 |
| `scripts/agkanban.sh add "<title>" [--assignee X] [--reviewer Y] [--body "..."]` | カード追加（todo） |
| `scripts/agkanban.sh move <id> <todo\|doing\|review\|done>` | 列遷移（ここで agmsg 自動通知） |
| `scripts/agkanban.sh claim <id>` | assignee=自分 にして doing へ（原子的） |
| `scripts/agkanban.sh show <id>` | カード詳細 + イベント履歴 |
| `scripts/agkanban.sh block <id> --by <id2>` | 依存設定 |

複数 team に所属する場合は各コマンドに `--team <name>` を付ける。

## delivery（気づき）

agkanban は独自の監視を持たない。遷移で発火した通知は **agmsg の delivery（turn/monitor/hook）** が運ぶ。
カードは状態が永続するため、必要時に `mine` / `board` で pull すれば取りこぼさない。

## 通知マッピング

| 遷移 | 通知先 |
|---|---|
| → doing | assignee |
| → review | reviewer（無ければ creator） |
| → done | creator（+ assignee が別なら両方） |
| 依存先が done | 待ちカードの assignee |

自分自身宛の通知は送られない。
```

- [ ] **Step 3: README.md を書く**

`README.md`:

````markdown
# agkanban

Multi-agent kanban task board that pairs with [agmsg](https://github.com/). State lives in a
per-team SQLite board; moving a card auto-notifies teammates through agmsg (event-driven).
Built with bash + sqlite3 — no daemon, no network.

## Install

**skills.sh（推奨）** — `~/.agents/skills` にグローバル install:

```bash
npx --yes skills add lucianlamp/agkanban -g -y
```

**gh CLI（代替, preview）**:

```bash
gh skill install lucianlamp/agkanban --agent claude-code --scope user
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
bash tests/test_transitions.sh
```

## License

MIT
````

- [ ] **Step 4: LICENSE を書く**

`LICENSE`（MIT。`<YEAR>` は 2026、`<COPYRIGHT HOLDER>` は ysk411）:

```
MIT License

Copyright (c) 2026 ysk411

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

- [ ] **Step 5: 全テスト再実行（リグレッション確認）**

Run: `bash tests/test_transitions.sh`
Expected: `ALL PASS`

- [ ] **Step 6: 実行権限付与 + Commit**

```bash
chmod +x scripts/agkanban.sh scripts/*.sh
git add SKILL.md README.md LICENSE .gitignore
git update-index --chmod=+x scripts/agkanban.sh scripts/init-db.sh scripts/add.sh scripts/move.sh scripts/claim.sh scripts/mine.sh scripts/show.sh scripts/board.sh scripts/block.sh
git commit -m "docs: add SKILL.md, README, LICENSE, gitignore; mark scripts executable"
```

---

## Task 14: GitHub 公開準備（private で作成 → push）

**Files:**
- なし（git/gh 操作のみ）

> ユーザーは「整備したらあとで public にする」と指示。まず private で作成し push する。
> public 化はユーザー承認のもとで後日（`gh repo edit --visibility public`）。

- [ ] **Step 1: ローカルでの最終検証**

Run:
```bash
cd ~/dev/agkanban
bash tests/test_transitions.sh
for f in scripts/*.sh scripts/lib/*.sh; do bash -n "$f" || echo "SYNTAX FAIL: $f"; done
```
Expected: `ALL PASS` かつ構文エラーなし

- [ ] **Step 2: リモートが未作成なら private で作成 + push**

Run:
```bash
cd ~/dev/agkanban
gh repo view lucianlamp/agkanban >/dev/null 2>&1 \
  || gh repo create lucianlamp/agkanban --private --source=. --remote=origin --description "Multi-agent kanban board that pairs with agmsg"
git push -u origin "$(git symbolic-ref --short HEAD)"
```
Expected: リポジトリ作成（または既存検出）後、push 成功

- [ ] **Step 3: install ワンライナーの実地検証（gh 経路）**

Run:
```bash
gh skill install lucianlamp/agkanban --agent claude-code --scope user
ls -ld ~/.agents/skills/agkanban && head -3 ~/.agents/skills/agkanban/SKILL.md
```
Expected: `~/.agents/skills/agkanban/` に展開され、SKILL.md frontmatter が見える

- [ ] **Step 4: install 後の本番経路スモークテスト（agmsg 探索）**

Run:
```bash
AGK_AGENT="" AGK_TEAM="" bash ~/.agents/skills/agkanban/scripts/agkanban.sh --help
```
Expected: usage が表示される（agmsg 兄弟探索パスでクラッシュしないこと）

> 本番での通知連携の最終確認（実 agmsg send）は、agmsg の team に join した状態で
> `agkanban add` → `agkanban move ... doing` を実行し、相手の inbox に届くことを Claude がローカルで検証する。

---

## Self-Review

**1. Spec coverage（spec 各節 → 実装タスク）:**
- §2.1 イベント駆動結合 → Task 8（move 発火）, Task 5（events）
- §2.2 team 単位 → 全コマンドが team で絞り込み（Task 6–12）
- §2.3 独立 board.db → Task 2/3
- §2.4 識別借用・探索フォールバック → Task 4（agmsg.sh）
- §2.5 delivery 相乗り + pull / no-arg=mine → Task 10, Task 6（dispatcher no-arg）
- §3.2 データモデル → Task 3
- §3.3 通知マッピング表 → Task 5/8
- §3.5 claim 原子性 → Task 9（同一接続 UPDATE+changes()）
- §3.5 フォールバック → Task 12（notify 失敗でも遷移成功）
- §4 コマンド I/F → Task 6–12 + dispatcher
- §5 ディレクトリ → 全タスク
- §6 テスト → 各タスクの TDD + Task 1 ハーネス
- §8 配布 → Task 13（README/SKILL）, Task 14（gh）
- ギャップ: なし

**2. Placeholder scan:** TBD/TODO/「適切に処理」等なし。全コードステップは実コードを含む。

**3. Type consistency:**
- DB 接続跨ぎの `changes()` 問題を回避するため claim/block は UPDATE と `SELECT changes()` を**同一 `db_exec` 文字列**で実行（Task 9/12）。storage.sh の `db_exec` は 1 プロセスで複数文を実行する仕様（Task 2）と一致。
- `AGK_AGENT`/`AGK_TEAM`/`AGKANBAN_STORAGE_PATH`/`AGMSG_SEND_CMD` のシーム名は全タスクで一貫。
- self-skip 仕様（actor==宛先で送信しない）に合わせ、Task 8/9 の通知アサーションを「スキップ＝空」に修正済み。
- 関数名 `fire_transition`/`fire_unblock`/`agmsg_send`/`agmsg_identity`/`agmsg_home`/`ensure_db`/`card_num`/`sql_val` は定義（Task 2/4/5）と呼び出し（Task 6–12）で一致。
