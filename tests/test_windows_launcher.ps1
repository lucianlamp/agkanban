$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Launcher = Join-Path $RepoRoot 'skills/agkanban/scripts/windows/agkanban.ps1'
$Installer = Join-Path $RepoRoot 'skills/agkanban/scripts/windows/install-agkanban.ps1'

function Assert-Contains {
    param(
        [string] $Haystack,
        [string] $Needle,
        [string] $Label
    )

    if ($Haystack -notlike "*$Needle*") {
        throw "$Label failed: missing [$Needle] in [$Haystack]"
    }
    Write-Output "ok: $Label"
}

function Assert-PowerShellSyntax {
    param([string] $Path)

    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $tokens, [ref] $errors) | Out-Null
    if ($errors.Count -gt 0) {
        $msg = ($errors | ForEach-Object { $_.Message }) -join '; '
        throw "PowerShell parser errors in $Path`: $msg"
    }
    Write-Output "ok: parser $Path"
}

Assert-PowerShellSyntax $Launcher
Assert-PowerShellSyntax $Installer

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("agkanban-win-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$oldStorage = $env:AGKANBAN_STORAGE_PATH
$oldAgent = $env:AGK_AGENT
$oldTeam = $env:AGK_TEAM
$oldSend = $env:AGMSG_SEND_CMD
try {
    $env:AGKANBAN_STORAGE_PATH = $tmp
    $env:AGK_AGENT = 'alice'
    $env:AGK_TEAM = 'dev'
    $env:AGMSG_SEND_CMD = Join-Path $tmp 'missing-recorder.sh'

    $body = "body with spaces, quotes ' "" and emoji 😄"
    $out = & $Launcher add 'Windows 日本語カード 😄' --assignee bob --body $body
    if ($LASTEXITCODE -ne 0) { throw "launcher add failed with exit $LASTEXITCODE" }
    Assert-Contains ($out -join "`n") 'card-1 added to dev' 'launcher add'

    $show = & $Launcher show 1
    if ($LASTEXITCODE -ne 0) { throw "launcher show failed with exit $LASTEXITCODE" }
    $showText = $show -join "`n"
    Assert-Contains $showText 'Windows 日本語カード 😄' 'launcher preserves title'
    Assert-Contains $showText 'body with spaces' 'launcher preserves body'

    $profile = Join-Path $tmp 'profile.ps1'
    & $Installer -ProfilePath $profile -FunctionName agk
    if ($LASTEXITCODE -ne 0) { throw "installer failed with exit $LASTEXITCODE" }
    $profileText = Get-Content -Raw -LiteralPath $profile
    Assert-Contains $profileText 'function agk' 'profile function installed'
    Assert-Contains $profileText $Launcher 'profile points at launcher'

    Write-Output 'ALL PASS'
} finally {
    if ($null -eq $oldStorage) { Remove-Item Env:AGKANBAN_STORAGE_PATH -ErrorAction SilentlyContinue } else { $env:AGKANBAN_STORAGE_PATH = $oldStorage }
    if ($null -eq $oldAgent) { Remove-Item Env:AGK_AGENT -ErrorAction SilentlyContinue } else { $env:AGK_AGENT = $oldAgent }
    if ($null -eq $oldTeam) { Remove-Item Env:AGK_TEAM -ErrorAction SilentlyContinue } else { $env:AGK_TEAM = $oldTeam }
    if ($null -eq $oldSend) { Remove-Item Env:AGMSG_SEND_CMD -ErrorAction SilentlyContinue } else { $env:AGMSG_SEND_CMD = $oldSend }
    Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
}
