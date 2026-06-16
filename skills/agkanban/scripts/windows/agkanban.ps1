<#
  Thin Windows PowerShell launcher for agkanban.

  Mirrors agmsg's Windows shim (fujibee/agmsg PR #128): it does NOT reimplement any
  logic in PowerShell. It detects Git Bash, sets up UTF-8, preflights sqlite3, then hands
  the command off to the existing Bash dispatcher (scripts/agkanban.sh) over a base64
  argv file so UTF-8 / quotes / emoji survive the PowerShell -> Bash boundary.

  Identity (team/agent) is still resolved by agmsg's whoami via agkanban. This shim sets:
    - $env:AGK_TYPE          -> agent type for whoami (AGKANBAN_AGENT_TYPE, default 'codex')
    - $env:AGKANBAN_PROJECT  -> the current directory as a Git Bash path (project key)

  NOTE: This file has only been authored on macOS and MUST be tested on Windows
  (PowerShell parser check + Git Bash E2E) before relying on it.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Command = '',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Rest
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

$script:ScriptsDir = Split-Path -Parent $PSScriptRoot   # scripts/windows -> scripts
$script:AgentType = if ($env:AGKANBAN_AGENT_TYPE) { $env:AGKANBAN_AGENT_TYPE } else { 'codex' }
$script:Bash = $null

function Find-GitBash {
    $candidates = @()
    if ($env:GIT_BASH) { $candidates += $env:GIT_BASH }
    if ($env:AGKANBAN_BASH) { $candidates += $env:AGKANBAN_BASH }
    $candidates += @(
        'C:\Program Files\Git\bin\bash.exe',
        'C:\Program Files\Git\usr\bin\bash.exe',
        'C:\Program Files (x86)\Git\bin\bash.exe'
    )

    foreach ($cmd in Get-Command bash.exe -All -ErrorAction SilentlyContinue) {
        $path = if ($cmd.Source) { $cmd.Source } else { $cmd.Path }
        if ($path) { $candidates += $path }
    }

    # Prefer Git-for-Windows bash; never the WindowsApps/WSL stub.
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if ($candidate -match '\\WindowsApps\\bash\.exe$') { continue }
        if ($candidate -notmatch '\\Git\\') { continue }
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if ($candidate -match '\\WindowsApps\\bash\.exe$') { continue }
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw 'Git Bash not found. Install Git for Windows or set GIT_BASH to Git for Windows bash.exe.'
}

function ConvertTo-BashPath {
    param([string] $Path)

    $resolved = if (Test-Path -LiteralPath $Path) {
        (Resolve-Path -LiteralPath $Path).Path
    } else {
        $Path
    }

    $converted = (& $script:Bash -lc 'cygpath -u "$1"' agkanban-path $resolved 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $converted) {
        return $resolved
    }
    return $converted
}

function Test-SqliteAvailable {
    & $script:Bash -lc 'command -v sqlite3 >/dev/null 2>&1 && sqlite3 --version >/dev/null'
    if ($LASTEXITCODE -ne 0) {
        Write-Error 'sqlite3 is required and must be executable from Git Bash. Install sqlite3 or add it to the Git Bash PATH.'
        exit 127
    }
}

$script:Bash = Find-GitBash
Test-SqliteAvailable

$dispatcher = Join-Path $script:ScriptsDir 'agkanban.sh'
if (-not (Test-Path -LiteralPath $dispatcher)) {
    throw "Missing agkanban dispatcher: $dispatcher"
}

# Identity hints for whoami (resolved inside agkanban via agmsg).
$env:AGK_TYPE = $script:AgentType
$env:AGKANBAN_PROJECT = ConvertTo-BashPath (Get-Location).Path

# Collect command + remaining args (empty => no-arg agkanban => your open cards).
$commandArgs = @()
if ($Command) { $commandArgs += $Command }
if ($Rest) { $commandArgs += $Rest }

$argvFile = [System.IO.Path]::GetTempFileName()
try {
    $encodedArgs = foreach ($arg in $commandArgs) {
        [Convert]::ToBase64String($utf8NoBom.GetBytes([string] $arg))
    }
    [System.IO.File]::WriteAllLines($argvFile, [string[]] $encodedArgs, $utf8NoBom)

    & $script:Bash $dispatcher '--argv-file' (ConvertTo-BashPath $argvFile)
    $code = $LASTEXITCODE
    if ($code -ne 0) { exit $code }
} finally {
    Remove-Item -LiteralPath $argvFile -Force -ErrorAction SilentlyContinue
}
