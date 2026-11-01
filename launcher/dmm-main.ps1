<#
.SYNOPSIS
  Opens the newest personal build of Deadlock Mod Manager `main`.

.DESCRIPTION
  If DMM is closed and a newer build is published in r3xsean/dmm-main-builds,
  downloads it, checks its SHA-256, snapshots DMM's app state, and switches to it.
  Then starts the current build with --disable-auto-update, so the app never
  offers to replace itself with an official release. If anything fails, it opens
  the build it already has.

  Folders:
    %LOCALAPPDATA%\dmm-main\versions\<tag>\   downloaded builds (newest 5 kept)
    %LOCALAPPDATA%\dmm-main\current.json      which build is in use
    %LOCALAPPDATA%\dmm-main\launcher.log
    C:\Users\User\dmm-backups\<time>-before-<tag>\   state snapshots (newest 10 kept)

.PARAMETER Offline
  Skip the update check and open the current build.

.PARAMETER Use
  Switch to an already-downloaded tag (for rolling back), e.g. -Use main-f9fc83b6.
#>
param(
  [switch]$Offline,
  [string]$Use
)

$ErrorActionPreference = 'Stop'
$Repo = 'r3xsean/dmm-main-builds'
$Root = Join-Path $env:LOCALAPPDATA 'dmm-main'
$Versions = Join-Path $Root 'versions'
$CurrentFile = Join-Path $Root 'current.json'
$Log = Join-Path $Root 'launcher.log'
$BackupRoot = 'C:\Users\User\dmm-backups'
$Identifier = 'dev.stormix.deadlock-mod-manager'
$KeepVersions = 5
$KeepBackups = 10

New-Item -ItemType Directory -Force $Versions | Out-Null

function Write-Log([string]$Message) {
  "$(Get-Date -Format s) $Message" | Add-Content -LiteralPath $Log
}

function Show-Error([string]$Message) {
  Write-Log "ERROR $Message"
  Add-Type -AssemblyName PresentationFramework
  [System.Windows.MessageBox]::Show($Message, 'DMM (main)') | Out-Null
}

# Read-only check: any DMM copy (official or personal) that's running.
function Test-DmmRunning {
  [bool](Get-Process -ErrorAction SilentlyContinue | Where-Object {
      try { $_.Path -and (Split-Path -Leaf $_.Path) -match '^(deadlock-mod-manager|dmm-main-[0-9a-f]+)\.exe$' } catch { $false }
    })
}

function Get-Current {
  if (Test-Path -LiteralPath $CurrentFile) { Get-Content -LiteralPath $CurrentFile -Raw | ConvertFrom-Json }
}

function Set-Current($Manifest, [string]$Exe) {
  [ordered]@{ tag = $Manifest.tag; sha = $Manifest.sha; version = $Manifest.version; exe = $Exe; switched = (Get-Date).ToString('o') } |
    ConvertTo-Json | Set-Content -LiteralPath $CurrentFile -Encoding utf8
}

# Settings, the mod database and state; not the browser cache or logs.
function Save-State([string]$Tag) {
  $dst = Join-Path $BackupRoot "$(Get-Date -Format 'yyyyMMdd-HHmmss')-before-$Tag"
  $pairs = @(
    @{ From = Join-Path $env:APPDATA $Identifier; To = Join-Path $dst 'Roaming'; Exclude = @() },
    @{ From = Join-Path $env:LOCALAPPDATA $Identifier; To = Join-Path $dst 'Local'; Exclude = @('EBWebView', 'logs') }
  )
  foreach ($p in $pairs) {
    if (-not (Test-Path -LiteralPath $p.From)) { continue }
    $rc = @($p.From, $p.To, '/E', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    if ($p.Exclude.Count) { $rc += '/XD'; $rc += $p.Exclude }
    & robocopy @rc | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Backing up $($p.From) failed (robocopy exit $LASTEXITCODE)." }
  }
  Write-Log "state saved to $dst"
  Get-ChildItem -LiteralPath $BackupRoot -Directory -Filter '*-before-main-*' | Sort-Object Name -Descending |
    Select-Object -Skip $KeepBackups | Remove-Item -Recurse -Force
}

function Remove-OldVersions([string]$KeepTag) {
  Get-ChildItem -LiteralPath $Versions -Directory | Where-Object Name -ne $KeepTag | Sort-Object LastWriteTime -Descending |
    Select-Object -Skip ($KeepVersions - 1) | Remove-Item -Recurse -Force
}

function Switch-To([string]$Tag) {
  $dir = Join-Path $Versions $Tag
  $manifest = Get-Content -LiteralPath (Join-Path $dir 'manifest.json') -Raw | ConvertFrom-Json
  Save-State $Tag
  Set-Current $manifest (Join-Path $dir $manifest.exe)
  Write-Log "switched to $Tag ($($manifest.sha))"
}

function Update-Build {
  $headers = @{ 'User-Agent' = 'dmm-main-launcher'; Accept = 'application/vnd.github+json' }
  $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $headers -TimeoutSec 15
  $tag = $release.tag_name
  $current = Get-Current
  if ($current -and $current.tag -eq $tag) { return }

  $dir = Join-Path $Versions $tag
  if (-not (Test-Path -LiteralPath (Join-Path $dir 'manifest.json'))) {
    $tmp = "$dir.part"
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $manifestAsset = $release.assets | Where-Object name -eq 'manifest.json'
    if (-not $manifestAsset) { throw "Release $tag has no manifest.json." }
    Invoke-WebRequest -Uri $manifestAsset.browser_download_url -OutFile (Join-Path $tmp 'manifest.json') -Headers $headers -TimeoutSec 30
    $manifest = Get-Content -LiteralPath (Join-Path $tmp 'manifest.json') -Raw | ConvertFrom-Json
    $exeAsset = $release.assets | Where-Object name -eq $manifest.exe
    if (-not $exeAsset) { throw "Release $tag has no $($manifest.exe)." }
    $exePath = Join-Path $tmp $manifest.exe
    Invoke-WebRequest -Uri $exeAsset.browser_download_url -OutFile $exePath -Headers $headers -TimeoutSec 600
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $exePath).Hash.ToLower()
    if ($hash -ne $manifest.sha256) { Remove-Item -LiteralPath $tmp -Recurse -Force; throw "Checksum mismatch for $tag." }
    Rename-Item -LiteralPath $tmp -NewName $tag
    Write-Log "downloaded $tag"
  }
  Switch-To $tag
  Remove-OldVersions $tag
}

try {
  $running = Test-DmmRunning
  if ($Use) {
    if ($running) { Show-Error 'Close Deadlock Mod Manager first, then roll back.'; exit 1 }
    if (-not (Test-Path -LiteralPath (Join-Path $Versions "$Use\manifest.json"))) { Show-Error "$Use isn't downloaded. Folders in $Versions are the ones you can use."; exit 1 }
    Switch-To $Use
  }
  elseif (-not $Offline -and -not $running) {
    try { Update-Build } catch { Write-Log "update skipped: $($_.Exception.Message)" }
  }

  $current = Get-Current
  if (-not $current -or -not (Test-Path -LiteralPath $current.exe)) {
    Show-Error "No build downloaded yet, and the update check failed. See $Log."
    exit 1
  }
  # If DMM is already open, this just brings the open window forward (single instance).
  Start-Process -FilePath $current.exe -ArgumentList '--disable-auto-update' -WorkingDirectory (Split-Path $current.exe)
  Write-Log "started $($current.tag)"
}
catch {
  Show-Error $_.Exception.Message
  exit 1
}
