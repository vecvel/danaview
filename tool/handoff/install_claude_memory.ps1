# Installs Claude's project notes from docs/editor/handoff/claude-memory into this
# machine's Claude Code project folder, so a Claude session on this computer picks up
# the editor build where the Mac left off.
#
# Usage (PowerShell, from anywhere):
#   powershell -ExecutionPolicy Bypass -File tool\handoff\install_claude_memory.ps1
# Open the project folder once in the Claude app (Code tab) first; that creates the
# project folder this script fills. The script also works if it doesn't exist yet.

param(
  [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

$ErrorActionPreference = 'Stop'

$RepoRoot = $RepoRoot.TrimEnd('\', '/')
$source = Join-Path $RepoRoot 'docs\editor\handoff\claude-memory'
if (-not (Test-Path $source)) {
  throw "Notes not found at $source. Run this from the danaview_player repo on branch editor-wip or editor-android."
}

# Claude Code names a project's folder after its path, with every character that isn't
# a letter or digit replaced by '-', e.g. C:\Users\me\Desktop\danaview_player ->
# C--Users-me-Desktop-danaview-player.
$configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$projects = Join-Path $configDir 'projects'
$name = $RepoRoot -replace '[^A-Za-z0-9]', '-'
$target = Join-Path $projects $name

if (-not (Test-Path $target)) {
  # Reuse an existing folder whose name only differs in letter case (drive letter).
  $match = Get-ChildItem -Path $projects -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ieq $name } | Select-Object -First 1
  if ($match) {
    $target = $match.FullName
  } else {
    Write-Host "No Claude project folder yet for $RepoRoot; creating $target"
    Write-Host "(If Claude later shows no notes, open the project once in the Claude app and run this again.)"
  }
}

$memory = Join-Path $target 'memory'
New-Item -ItemType Directory -Force -Path $memory | Out-Null

# Keep a backup of any notes already on this machine.
$existing = Get-ChildItem -Path $memory -Filter '*.md' -ErrorAction SilentlyContinue
if ($existing) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $backup = Join-Path $target "memory-backup-$stamp"
  Copy-Item -Path $memory -Destination $backup -Recurse
  Write-Host "Backed up existing notes to $backup"
}

Copy-Item -Path (Join-Path $source '*.md') -Destination $memory -Force
$count = (Get-ChildItem -Path $memory -Filter '*.md').Count
Write-Host "Installed $count note files into $memory"
Write-Host "Next: open the Claude app, Code tab, choose $RepoRoot, and say: continue the Android lane (read docs/editor/handoff/README.md)."
