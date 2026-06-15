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

finish
