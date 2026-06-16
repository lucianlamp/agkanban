#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../skills/agkanban" && pwd)"
source "$HERE/lib_assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$HOME"

SETUP="$ROOT/scripts/setup-codex-sandbox.sh"
CONFIG="$TMP/config.toml"

set +e
check_out="$(bash "$SETUP" --config "$CONFIG" --check 2>&1)"
check_rc=$?
set -e
assert_eq "$check_rc" "1" "check exits 1 when required writable roots are missing"
assert_contains "$check_out" "$HOME/.agkanban" "check reports missing agkanban storage root"
assert_contains "$check_out" "$HOME/.agents/skills/agmsg" "check reports missing agmsg root"

setup_out="$(bash "$SETUP" --config "$CONFIG")"
assert_contains "$setup_out" "Updated Codex sandbox writable roots" "setup reports config update"
assert_contains "$(cat "$CONFIG")" "[sandbox_workspace_write]" "setup creates sandbox section"
assert_contains "$(cat "$CONFIG")" "$HOME/.agkanban" "setup writes absolute agkanban path"
assert_contains "$(cat "$CONFIG")" "$HOME/.agents/skills/agmsg" "setup writes absolute agmsg path"

set +e
check_out2="$(bash "$SETUP" --config "$CONFIG" --check 2>&1)"
check_rc2=$?
set -e
assert_eq "$check_rc2" "0" "check exits 0 after setup"
assert_contains "$check_out2" "Codex sandbox writable roots already include agkanban paths" "check reports success"

before_second="$(cat "$CONFIG")"
bash "$SETUP" --config "$CONFIG" >/dev/null
after_second="$(cat "$CONFIG")"
assert_eq "$after_second" "$before_second" "setup is idempotent"
assert_eq "$(grep -F "$HOME/.agkanban" "$CONFIG" | wc -l | tr -d ' ')" "1" "agkanban root appears once"
assert_eq "$(grep -F "$HOME/.agents/skills/agmsg" "$CONFIG" | wc -l | tr -d ' ')" "1" "agmsg root appears once"

CONFIG2="$TMP/existing.toml"
cat > "$CONFIG2" <<EOF
model = "gpt-5.5"

[sandbox_workspace_write]
writable_roots = [
  "/keep/me",
]

[features]
memories = true
EOF

bash "$SETUP" --config "$CONFIG2" >/dev/null
assert_contains "$(cat "$CONFIG2")" "/keep/me" "setup preserves existing writable root"
assert_contains "$(cat "$CONFIG2")" "$HOME/.agkanban" "setup merges agkanban root into existing section"
assert_contains "$(cat "$CONFIG2")" "$HOME/.agents/skills/agmsg" "setup merges agmsg root into existing section"
assert_contains "$(cat "$CONFIG2")" "[features]" "setup preserves following sections"

print_out="$(bash "$SETUP" --print)"
assert_contains "$print_out" "[sandbox_workspace_write]" "print emits sandbox section"
assert_contains "$print_out" "$HOME/.agkanban" "print expands agkanban path"

finish
