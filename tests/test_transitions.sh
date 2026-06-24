#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# tests/ lives at the repo root; the skill itself is under skills/agkanban/.
ROOT="$(cd "$HERE/../skills/agkanban" && pwd)"
source "$HERE/lib_assert.sh"

# --- Isolated environment ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

DEFAULT_HOME="$TMP/default-home"
mkdir -p "$DEFAULT_HOME"
default_storage="$(env -u AGKANBAN_STORAGE_PATH HOME="$DEFAULT_HOME" bash -c 'source "$1"; agkanban_storage_dir' _ "$ROOT/scripts/lib/storage.sh")"
assert_eq "$default_storage" "$DEFAULT_HOME/.agkanban" "default storage lives under HOME/.agkanban"

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

# no reviewer set: notify creator; creator==self → skipped
bash "$AGK" add "no reviewer" --assignee bob >/dev/null   # card-2 creator=alice
# Replace the last 2 lines above with:
: > "$AGK_TEST_SENT"
bash "$AGK" move 2 review >/dev/null
assert_eq "$(cat "$AGK_TEST_SENT")" "" "review w/o reviewer -> creator==self -> skipped (no send)"

# --- Task 9: claim + conflict ---
bash "$AGK" add "claimable" >/dev/null    # card-3, assignee=NULL
: > "$AGK_TEST_SENT"
out="$(AGK_AGENT=bob AGK_TEAM=dev bash "$AGK" claim 3)"
assert_contains "$out" "card-3" "claim by bob succeeds"
row="$(sqlite3 "$TMP/board.db" "SELECT col,assignee FROM cards WHERE id=3;")"
assert_eq "$row" "doing|bob" "claim sets doing + assignee=bob"
assert_eq "$(cat "$AGK_TEST_SENT")" "" "claim self-assign -> actor==assignee -> no send"

# Second claim by carol fails (bob already holds it)
set +e
out2="$(AGK_AGENT=carol AGK_TEAM=dev bash "$AGK" claim 3 2>&1)"
rc=$?
set -e
assert_eq "$rc" "1" "second claim by carol exits 1"
assert_contains "$out2" "already claimed" "second claim reports conflict"

# --- Task 10: assigned cards (no-arg = mine equivalent) ---
# bob has card-1(done) and card-3(doing). Only doing/review are listed → card-3 only.
noarg_bob="$(AGK_AGENT=bob AGK_TEAM=dev bash "$AGK")"
assert_contains "$noarg_bob" "card-3" "no-arg lists bob's doing card"
assert_not_contains "$noarg_bob" "card-1" "no-arg excludes done card"
# 'mine' subcommand removed: redirects to default and exits 2
set +e
mine_out="$(AGK_AGENT=bob AGK_TEAM=dev bash "$AGK" mine 2>&1)"; mrc=$?
set -e
assert_eq "$mrc" "2" "'mine' subcommand removed (exits 2)"
assert_contains "$mine_out" "is the default" "'mine' points users to the no-arg default"

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
assert_contains "$sent" "card-5 unblocked" "unblock message references both cards"

# --- Fallback: state transition succeeds even when notify command fails ---
cat > "$TMP/fail.sh" <<'F'
#!/usr/bin/env bash
exit 1
F
chmod +x "$TMP/fail.sh"
out="$(AGMSG_SEND_CMD="$TMP/fail.sh" bash "$AGK" move 5 doing 2>/dev/null)"
assert_contains "$out" "card-5: " "move succeeds even when notify fails"
col5="$(sqlite3 "$TMP/board.db" "SELECT col FROM cards WHERE id=5;")"
assert_eq "$col5" "doing" "state transition persists despite notify failure"

# --- Semantic transition verbs: review / done / reopen (thin wrappers over move) ---
bash "$AGK" add "verb card" --assignee bob --reviewer carol >/dev/null
vid="$(sqlite3 "$TMP/board.db" "SELECT max(id) FROM cards;")"
: > "$AGK_TEST_SENT"
bash "$AGK" review "$vid" >/dev/null
assert_eq "$(sqlite3 "$TMP/board.db" "SELECT col FROM cards WHERE id=$vid;")" "review" "review verb -> review column"
assert_contains "$(cat "$AGK_TEST_SENT")" "dev|alice|carol|" "review verb notifies reviewer"
bash "$AGK" done "$vid" >/dev/null
assert_eq "$(sqlite3 "$TMP/board.db" "SELECT col FROM cards WHERE id=$vid;")" "done" "done verb -> done column"
bash "$AGK" reopen "$vid" >/dev/null
assert_eq "$(sqlite3 "$TMP/board.db" "SELECT col FROM cards WHERE id=$vid;")" "todo" "reopen verb -> todo column"

# --- mine includes todo cards assigned to me (card-$vid is now todo, assignee=bob) ---
mine_todo="$(AGK_AGENT=bob AGK_TEAM=dev bash "$AGK")"
assert_contains "$mine_todo" "card-$vid" "no-arg (mine) includes my todo cards"

# --- edit: update fields ---
bash "$AGK" add "orig title" --assignee bob >/dev/null
eid="$(sqlite3 "$TMP/board.db" "SELECT max(id) FROM cards;")"
bash "$AGK" edit "$eid" --title "new title" --reviewer carol --body "do the thing" >/dev/null
erow="$(sqlite3 "$TMP/board.db" "SELECT title||'|'||COALESCE(reviewer,'')||'|'||COALESCE(body,'') FROM cards WHERE id=$eid;")"
assert_eq "$erow" "new title|carol|do the thing" "edit updates title/reviewer/body"
bash "$AGK" edit "$eid" --reviewer "" >/dev/null
assert_eq "$(sqlite3 "$TMP/board.db" "SELECT COALESCE(reviewer,'NULL') FROM cards WHERE id=$eid;")" "NULL" "edit with empty value clears the field"
set +e
bash "$AGK" edit "$eid" >/dev/null 2>&1; nrc=$?
set -e
assert_eq "$nrc" "2" "edit with no fields errors"

# --- delete: removes the card, its events, and clears dangling dependencies ---
bash "$AGK" add "blocker X" >/dev/null
da="$(sqlite3 "$TMP/board.db" "SELECT max(id) FROM cards;")"
bash "$AGK" add "waiter X" >/dev/null
dw="$(sqlite3 "$TMP/board.db" "SELECT max(id) FROM cards;")"
bash "$AGK" block "$dw" --by "$da" >/dev/null
bash "$AGK" move "$da" doing >/dev/null   # create an event row for da
bash "$AGK" delete "$da" >/dev/null
assert_eq "$(sqlite3 "$TMP/board.db" "SELECT count(*) FROM cards WHERE id=$da;")" "0" "delete removes the card"
assert_eq "$(sqlite3 "$TMP/board.db" "SELECT count(*) FROM card_events WHERE card_id=$da;")" "0" "delete removes the card's events"
assert_eq "$(sqlite3 "$TMP/board.db" "SELECT COALESCE(blocked_by,'NULL') FROM cards WHERE id=$dw;")" "NULL" "delete clears dangling blocked_by"
set +e
bash "$AGK" delete "$da" >/dev/null 2>&1; drc=$?
set -e
assert_eq "$drc" "1" "delete of missing card errors"

# --- authorization: delete=creator only, edit=creator+assignee ---
# created by alice (global AGK_AGENT), assigned to bob
bash "$AGK" add "owned by alice" --assignee bob >/dev/null
oid="$(sqlite3 "$TMP/board.db" "SELECT max(id) FROM cards;")"
set +e
out_del="$(AGK_AGENT=bob AGK_TEAM=dev bash "$AGK" delete "$oid" 2>&1)"; arc=$?
set -e
assert_eq "$arc" "1" "delete by non-creator is refused"
assert_contains "$out_del" "only the creator" "delete refusal names the creator rule"
assert_eq "$(sqlite3 "$TMP/board.db" "SELECT count(*) FROM cards WHERE id=$oid;")" "1" "refused delete leaves the card intact"
# assignee bob may edit
AGK_AGENT=bob AGK_TEAM=dev bash "$AGK" edit "$oid" --body "from assignee" >/dev/null
assert_eq "$(sqlite3 "$TMP/board.db" "SELECT body FROM cards WHERE id=$oid;")" "from assignee" "assignee may edit"
# carol (neither creator nor assignee) may not edit
set +e
out_edit="$(AGK_AGENT=carol AGK_TEAM=dev bash "$AGK" edit "$oid" --body "hacked" 2>&1)"; erc2=$?
set -e
assert_eq "$erc2" "1" "edit by non-creator/non-assignee is refused"
# creator alice may delete
AGK_AGENT=alice AGK_TEAM=dev bash "$AGK" delete "$oid" >/dev/null
assert_eq "$(sqlite3 "$TMP/board.db" "SELECT count(*) FROM cards WHERE id=$oid;")" "0" "creator may delete"

# --- Windows PowerShell shim: --argv-file base64 handoff (UTF-8 safe) ---
argvf="$TMP/argv.txt"; : > "$argvf"
for a in "add" "日本語カード" "--assignee" "bob"; do
  printf '%s\r\n' "$(printf '%s' "$a" | base64)" >> "$argvf"
done
out_argv="$(AGK_AGENT=alice AGK_TEAM=dev bash "$AGK" --argv-file "$argvf")"
assert_contains "$out_argv" "added to dev" "--argv-file decodes and dispatches"
assert_eq "$(sqlite3 "$TMP/board.db" "SELECT title FROM cards ORDER BY id DESC LIMIT 1;")" "日本語カード" "--argv-file preserves UTF-8 args"

# --- agmsg identity: multiple registrations resolve to the active actas lock ---
FAKE_AGMSG="$TMP/fake-agmsg"
mkdir -p "$FAKE_AGMSG/scripts/lib"
cat > "$FAKE_AGMSG/scripts/whoami.sh" <<'WH'
#!/usr/bin/env bash
echo "multiple=true agents=alice,bob teams=dev type=codex project=$1"
WH
cat > "$FAKE_AGMSG/scripts/identities.sh" <<'ID'
#!/usr/bin/env bash
printf 'dev\talice\n'
printf 'dev\tbob\n'
ID
cat > "$FAKE_AGMSG/scripts/lib/actas-lock.sh" <<'LOCK'
#!/usr/bin/env bash
actas_lock_state() {
  if [ "$1|$2|$3" = "dev|bob|sid-123" ]; then
    echo "mine"
  else
    echo "free"
  fi
}
LOCK
chmod +x "$FAKE_AGMSG/scripts/whoami.sh" "$FAKE_AGMSG/scripts/identities.sh"
multi_identity="$(env -u AGK_AGENT -u AGK_TEAM \
  AGMSG_HOME="$FAKE_AGMSG" AGK_SESSION_ID=sid-123 \
  bash -c 'source "$1"; agmsg_identity; printf "%s|%s" "$AGK_AGENT" "$AGK_TEAM"' _ "$ROOT/scripts/lib/agmsg.sh")"
assert_eq "$multi_identity" "bob|dev" "multiple agmsg identities resolve via this session's actas lock"

# --- --agent override: usable when agmsg identity is unresolved (multiple agents, same project) ---
FAKE_AGMSG2="$TMP/fake-agmsg2"
mkdir -p "$FAKE_AGMSG2/scripts"
# whoami.sh returns multiple=true with no resolvable actas lock (no actas-lock.sh)
cat > "$FAKE_AGMSG2/scripts/whoami.sh" <<'WH2'
#!/usr/bin/env bash
echo "multiple=true agents=alice,bob teams=dev type=codex project=$1"
WH2
chmod +x "$FAKE_AGMSG2/scripts/whoami.sh"

# mine --agent: resolves to the given name even when whoami can't pick one
out_mine_agent="$(env -u AGK_AGENT -u AGK_TEAM \
  AGMSG_HOME="$FAKE_AGMSG2" AGKANBAN_STORAGE_PATH="$TMP" \
  bash "$AGK" --agent alice 2>&1)" || true
assert_contains "$out_mine_agent" "alice" "--agent overrides unresolved identity in default (mine) command"

# Add a card as alice to test --agent on claim/edit/delete
oa2="$(AGK_AGENT=alice AGK_TEAM=dev bash "$AGK" add "agent-override-test")"
oid2="$(printf '%s\n' "$oa2" | grep -o 'card-[0-9]*' | grep -o '[0-9]*')"

# claim --agent: claims card as the overridden agent
out_claim_agent="$(env -u AGK_AGENT -u AGK_TEAM \
  AGMSG_HOME="$FAKE_AGMSG2" AGKANBAN_STORAGE_PATH="$TMP" \
  bash "$AGK" claim "$oid2" --team dev --agent alice 2>&1)"
assert_contains "$out_claim_agent" "claimed by alice" "--agent on claim acts as the given agent"

# edit --agent: creator overrides are respected
out_edit_agent="$(env -u AGK_AGENT -u AGK_TEAM \
  AGMSG_HOME="$FAKE_AGMSG2" AGKANBAN_STORAGE_PATH="$TMP" \
  bash "$AGK" edit "$oid2" --team dev --agent alice --title "agent-override-edited" 2>&1)"
assert_contains "$out_edit_agent" "updated" "--agent on edit passes authorization"
assert_eq "$(sqlite3 "$TMP/board.db" "SELECT title FROM cards WHERE id=$oid2;")" "agent-override-edited" "--agent edit actually changed the title"

# edit --agent bob (non-creator, non-assignee) must be refused
set +e
out_edit_bad="$(env -u AGK_AGENT -u AGK_TEAM \
  AGMSG_HOME="$FAKE_AGMSG2" AGKANBAN_STORAGE_PATH="$TMP" \
  bash "$AGK" edit "$oid2" --team dev --agent bob --title "hacked" 2>&1)"; erc_bad=$?
set -e
assert_eq "$erc_bad" "1" "--agent with wrong identity is still refused by authorization guard"

# delete --agent: creator may delete
env -u AGK_AGENT -u AGK_TEAM \
  AGMSG_HOME="$FAKE_AGMSG2" AGKANBAN_STORAGE_PATH="$TMP" \
  bash "$AGK" delete "$oid2" --team dev --agent alice >/dev/null
assert_eq "$(sqlite3 "$TMP/board.db" "SELECT count(*) FROM cards WHERE id=$oid2;")" "0" "--agent on delete: creator may delete"

finish
