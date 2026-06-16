# agkanban on Windows

agkanban's logic is a single Bash + sqlite3 implementation. On Windows it runs through
**Git Bash**, with a thin PowerShell launcher that hands commands off to the Bash
dispatcher (`scripts/agkanban.sh`) over a UTF-8-safe base64 argv file. This mirrors
[agmsg's Windows support](https://github.com/fujibee/agmsg/pull/128) — no logic is
reimplemented in PowerShell.

## Requirements

- **Git for Windows** (provides `bash.exe` and `cygpath`). If it is not on a standard
  path, set `GIT_BASH` (or `AGKANBAN_BASH`) to its `bash.exe`.
- **sqlite3** available from Git Bash (`command -v sqlite3` must succeed in Git Bash).
- **agmsg** installed and the project joined to a team (agkanban borrows identity from it).

The repository pins shell scripts to LF line endings so a Windows checkout can run them
from Git Bash without `set: invalid option` / `$'\r'` failures.

## Run it

From PowerShell, in the project directory you joined to the agmsg team:

```powershell
# directly via the launcher
& "$HOME\.agents\skills\agkanban\scripts\windows\agkanban.ps1"            # your open cards
& "$HOME\.agents\skills\agkanban\scripts\windows\agkanban.ps1" board
& "$HOME\.agents\skills\agkanban\scripts\windows\agkanban.ps1" add "実装タスク" --assignee codex --reviewer claude
& "$HOME\.agents\skills\agkanban\scripts\windows\agkanban.ps1" claim 1
& "$HOME\.agents\skills\agkanban\scripts\windows\agkanban.ps1" done 1
```

### Optional: a short `agkanban` command

Install a profile function so you can just type `agkanban ...`:

```powershell
& "$HOME\.agents\skills\agkanban\scripts\windows\install-agkanban.ps1"
# then, in a new PowerShell session:
agkanban
agkanban add "タスク" --assignee codex
```

## Agent type

Identity is resolved by agmsg's `whoami`. On Windows the launcher sets `AGK_TYPE` so the
right registration is matched. Default is `codex`; override per session:

```powershell
$env:AGKANBAN_AGENT_TYPE = 'claude-code'
```

## SessionStart auto-pull (hooks) on Windows

The hook command must run through Git Bash. Point it at `bash.exe` explicitly:

- **Claude Code** (`~/.claude/settings.json`):

  ```json
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command",
        "command": "\"C:\\Program Files\\Git\\bin\\bash.exe\" \"$HOME/.agents/skills/agkanban/hooks/session-start.sh\"" } ] }
    ]
  }
  ```

- **Codex** (`~/.codex/hooks.json`): use `command_windows` (or `commandWindows`) for the
  Windows variant pointing at Git Bash + `session-start.sh`; trust it via `/hooks`.

## How the handoff works

1. `agkanban.ps1` finds Git Bash, sets UTF-8, preflights sqlite3.
2. It sets `AGK_TYPE` and `AGKANBAN_PROJECT` (current dir as a `cygpath -u` path).
3. It base64-encodes each argument (one per line) into a temp file and calls
   `bash scripts/agkanban.sh --argv-file <file>`.
4. `agkanban.sh` decodes the args and dispatches normally — so Japanese titles, quotes,
   and paths survive the PowerShell -> Bash boundary intact.
