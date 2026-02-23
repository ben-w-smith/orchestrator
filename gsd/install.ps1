# GSD Workflow Commands — Installer / Updater (Windows PowerShell)
#
# Requires: gh CLI (https://cli.github.com) — authenticated with repo access
#
# Usage:
#   gh api repos/ben-smith-atg/cursor-gsd/contents/install.ps1 --jq '.content' `
#     | % { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_)) } `
#     | iex
#
# Or run locally after cloning:
#   . $env:USERPROFILE\.cursor\commands\gsd\install.ps1
$ErrorActionPreference = "Stop"

$REPO  = "ben-smith-atg/cursor-gsd"
$DEST  = "$env:USERPROFILE\.cursor\commands\gsd"
$FILES = @(
    "setup-gsd.md",
    "spec-gsd.md",
    "plan-gsd.md",
    "build-gsd.md",
    "verify-gsd.md",
    "retro-gsd.md",
    "README.md"
)

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Error "gh CLI is required. Install from https://cli.github.com"
    exit 1
}

New-Item -ItemType Directory -Force -Path $DEST | Out-Null

Write-Host "Installing GSD commands to $DEST ..."
Write-Host ""

foreach ($f in $FILES) {
    $content = gh api "repos/$REPO/contents/$f" --jq '.content'
    $bytes   = [System.Convert]::FromBase64String($content)
    [System.IO.File]::WriteAllBytes("$DEST\$f", $bytes)
    Write-Host "  v $f"
}

Write-Host ""
Write-Host "Done. $($FILES.Count) files installed to $DEST"
Write-Host "Restart Cursor to pick up the updated commands."
