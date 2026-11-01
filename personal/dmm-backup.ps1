<#
  Runs inside the dmm-main-builds installer, before any file is replaced.
  1. Waits (up to 90 s) for every DMM process started from the install folder to exit.
  2. Copies both app-data folders in full into %USERPROFILE%\dmm-backups\<time>-<id>-before-<version>.
  3. Marks the backup complete, then keeps the newest 10 automatic backups.
     Backups this script didn't make (e.g. the one taken before switching from the
     official build) are never deleted.
  Exit codes: 0 ok or nothing to back up, 2 DMM still running, 3 copy failed.
#>
param(
  [Parameter(Mandatory)][string]$InstallDir,
  [Parameter(Mandatory)][string]$Incoming
)

$ErrorActionPreference = 'Stop'
$Identifier = 'dev.stormix.deadlock-mod-manager'
$BackupRoot = Join-Path $env:USERPROFILE 'dmm-backups'
$Keep = 10
New-Item -ItemType Directory -Force $BackupRoot | Out-Null
$Log = Join-Path $BackupRoot 'backup.log'
function Write-Log([string]$m) { "$(Get-Date -Format s) [$Incoming] $m" | Add-Content -LiteralPath $Log }

try {
  # 1. Wait for DMM to exit (read-only check; nothing is killed).
  $installRoot = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\') + '\'
  $deadline = (Get-Date).AddSeconds(90)
  $webviewData = Join-Path $env:LOCALAPPDATA "$Identifier\EBWebView"
  while ($true) {
    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and $_.Path.StartsWith($installRoot, [StringComparison]::OrdinalIgnoreCase) -and $_.Id -ne $PID } catch { $false }
      } | Where-Object { $_.ProcessName -notmatch 'uninstall|setup' })
    # DMM's WebView2 helpers live outside the install folder and can outlast the app briefly.
    $running += @(Get-CimInstance Win32_Process -Filter "Name = 'msedgewebview2.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($webviewData, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
        ForEach-Object { [pscustomobject]@{ Id = $_.ProcessId; Path = $_.ExecutablePath } })
    if (-not $running) { break }
    if ((Get-Date) -gt $deadline) {
      Write-Log "DMM still running after 90 s: $(($running | ForEach-Object { "$($_.Id) $($_.Path)" }) -join '; ')"
      exit 2
    }
    Start-Sleep -Milliseconds 500
  }

  $sources = @(
    @{ Name = 'Roaming'; Path = Join-Path $env:APPDATA $Identifier },
    @{ Name = 'Local'; Path = Join-Path $env:LOCALAPPDATA $Identifier }
  ) | Where-Object { Test-Path -LiteralPath $_.Path }
  if (-not $sources) { Write-Log 'no app data yet; nothing to back up'; exit 0 }

  # 2. Copy.
  $installedExe = Join-Path $InstallDir 'deadlock-mod-manager.exe'
  $installed = if (Test-Path -LiteralPath $installedExe) { (Get-Item -LiteralPath $installedExe).VersionInfo.ProductVersion } else { $null }
  $safe = ($Incoming -replace '[^0-9A-Za-z.\-]', '_')
  $dst = Join-Path $BackupRoot ("{0}-{1}-before-{2}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6)), $safe)
  New-Item -ItemType Directory -Force $dst | Out-Null
  [ordered]@{ auto = $true; installed = $installed; incoming = $Incoming; started = (Get-Date).ToString('o') } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dst 'backup.json') -Encoding utf8
  foreach ($s in $sources) {
    & robocopy $s.Path (Join-Path $dst $s.Name) /E /COPY:DAT /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { Write-Log "copying $($s.Path) failed (robocopy $LASTEXITCODE)"; exit 3 }
  }
  Set-Content -LiteralPath (Join-Path $dst 'COMPLETE') -Value (Get-Date).ToString('o')
  Write-Log "backed up $installed -> $dst"

  # 3. Prune old automatic backups (complete ones only).
  Get-ChildItem -LiteralPath $BackupRoot -Directory | Where-Object {
      (Test-Path -LiteralPath (Join-Path $_.FullName 'COMPLETE')) -and
      (Test-Path -LiteralPath (Join-Path $_.FullName 'backup.json')) -and
      ((Get-Content -LiteralPath (Join-Path $_.FullName 'backup.json') -Raw | ConvertFrom-Json).auto -eq $true)
    } | Sort-Object Name -Descending | Select-Object -Skip $Keep | ForEach-Object {
      Remove-Item -LiteralPath $_.FullName -Recurse -Force
      Write-Log "pruned $($_.Name)"
    }
  exit 0
}
catch {
  Write-Log "error: $($_.Exception.Message)"
  exit 3
}
