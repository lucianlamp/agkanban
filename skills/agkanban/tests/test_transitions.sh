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

# --- Task 6: add ---
out="$(bash "$AGK" add "first task" --assignee bob --reviewer carol)"
assert_contains "$out" "card-1" "add returns card-1"
row="$(sqlite3 "$TMP/board.db" "SELECT team,col,assignee,reviewer,creator,title FROM cards WHERE id=1;")"
assert_eq "$row" "dev|todo|bob|carol|alice|first task" "add inserts row (todo, creator=alice)"

# --- Task 7: board ---
out="$(bash "$AGK" board)"
assert_contains "$out" "todo" "board shows todo column"
assert_contains "$out" "card-1" "board lists card-1"
assert_contains "$out" "first task" "board shows title"

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
# 上記ブロックの最後2行を以下に置き換える:
: > "$AGK_TEST_SENT"
bash "$AGK" move 2 review >/dev/null
assert_eq "$(cat "$AGK_TEST_SENT")" "" "review w/o reviewer -> creator==self -> skipped (no send)"

# --- Task 9: claim + 競合 ---
bash "$AGK" add "claimable" >/dev/null    # card-3, assignee=NULL
: > "$AGK_TEST_SENT"
out="$(AGK_AGENT=bob AGK_TEAM=dev bash "$AGK" claim 3)"
assert_contains "$out" "card-3" "claim by bob succeeds"
row="$(sqlite3 "$TMP/board.db" "SELECT col,assignee FROM cards WHERE id=3;")"
assert_eq "$row" "doing|bob" "claim sets doing + assignee=bob"
assert_eq "$(cat "$AGK_TEST_SENT")" "" "claim self-assign -> actor==assignee -> no send"

# 2人目 carol の claim は失敗（既に bob 保有）
set +e
out2="$(AGK_AGENT=carol AGK_TEAM=dev bash "$AGK" claim 3 2>&1)"
rc=$?
set -e
assert_eq "$rc" "1" "second claim by carol exits 1"
assert_contains "$out2" "already claimed" "second claim reports conflict"

# --- Task 10: 自分の担当カード（引数なし = mine 相当）---
# bob は card-1(done)・card-3(doing) を持つ。doing/review のみ列挙 → card-3 のみ。
noarg_bob="$(AGK_AGENT=bob AGK_TEAM=dev bash "$AGK")"
assert_contains "$noarg_bob" "card-3" "no-arg lists bob's doing card"
assert_not_contains "$noarg_bob" "card-1" "no-arg excludes done card"
# 'mine' サブコマンドは削除済み: 既定動作へ案内して exit 2
set +e
mine_out="$(AGK_AGENT=bob AGK_TEAM=dev bash "$AGK" mine 2>&1)"; mrc=$?
set -e
assert_eq "$mrc" "2" "'mine' subcommand removed (exits 2)"
assert_contains "$mine_out" "既定動作" "'mine' points users to the no-arg default"

# --- Task 11: show ---
out="$(bash "$AGK" show 1)"
assert_contains "$out" "card-1" "show prints card id"
assert_contains "$out" "first task" "show prints title"
assert_contains "$out" "todo->doing" "show prints event history"

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

finish
