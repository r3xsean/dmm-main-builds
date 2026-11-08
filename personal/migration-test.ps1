<#
  Runs on a hosted Windows runner before anything is published.
  Installs the official nightly with made-up data, then installs this build over
  it the way r3xsean's switch and later updates will, and checks the result.
#>
param(
  [Parameter(Mandatory)][string]$Setup,
  [Parameter(Mandatory)][string]$Version,
  [Parameter(Mandatory)][string]$Upstream
)
$ErrorActionPreference = 'Stop'
$Identifier = 'dev.stormix.deadlock-mod-manager'
$InstallDir = Join-Path $env:LOCALAPPDATA 'Deadlock Mod Manager'
$Exe = Join-Path $InstallDir 'deadlock-mod-manager.exe'
$Backups = Join-Path $env:USERPROFILE 'dmm-backups'
$failures = @()
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail"; $script:failures += $name }
}
function Install([string]$path, [string[]]$installerArgs) {
  $p = Start-Process -FilePath $path -ArgumentList $installerArgs -Wait -PassThru
  return $p.ExitCode
}
# GitHub sometimes answers with 5xx for a while; retry before failing the test.
function Retry([scriptblock]$action) {
  for ($i = 1; ; $i++) {
    try { return & $action } catch { if ($i -ge 5) { throw }; Write-Host "retry $i after: $($_.Exception.Message)"; Start-Sleep -Seconds (15 * $i) }
  }
}
function Get-Backups { @(Get-ChildItem -LiteralPath $Backups -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'COMPLETE') }) }
function Get-Protocols { @('deadlock-mod-manager', 'deadlock-modmanager', 'dlmm' | Where-Object { Test-Path "HKCU:\Software\Classes\$_" }) }

# 1. Official nightly, as r3xsean has it today
$release = Retry { Invoke-RestMethod "https://api.github.com/repos/$Upstream/releases/tags/nightly" -Headers @{ 'User-Agent' = 'dmm-main-builds' } }
$asset = $release.assets | Where-Object { $_.name -match '_x64-setup\.exe$' -and $_.name -notmatch 'cef' } | Select-Object -First 1
if (-not $asset) { throw 'No official nightly x64 setup asset found.' }
$official = Join-Path $env:RUNNER_TEMP $asset.name
Retry { Invoke-WebRequest $asset.browser_download_url -OutFile $official }
Check 'official nightly installs' ((Install $official @('/S')) -eq 0)
$officialVersion = (Get-Item $Exe).VersionInfo.ProductVersion
Write-Host "official version: $officialVersion"
$protocolsBefore = Get-Protocols

# Made-up data in both profile folders
$roaming = Join-Path $env:APPDATA $Identifier
$local = Join-Path $env:LOCALAPPDATA $Identifier
New-Item -ItemType Directory -Force $roaming, (Join-Path $local 'EBWebView') | Out-Null
'{"test":"state"}' | Set-Content (Join-Path $roaming 'state.json')
[IO.File]::WriteAllBytes((Join-Path $local 'gamebanana-catalog.db'), [byte[]](1..255))
'webview' | Set-Content (Join-Path $local 'EBWebView\marker.txt')

# 2. The one-time switch: this build over the official one
Check 'switch installs silently' ((Install $Setup @('/S')) -eq 0)
$installed = (Get-Item $Exe).VersionInfo.ProductVersion
Check 'installed version is this build' ($installed -eq $Version) "got $installed"
Check 'same install folder' (Test-Path $Exe)
Check 'data kept' ((Get-Content (Join-Path $roaming 'state.json') -Raw).Trim() -eq '{"test":"state"}')
$b = Get-Backups
Check 'backup taken before the switch' ($b.Count -eq 1)
if ($b.Count -ge 1) {
  $meta = Get-Content (Join-Path $b[0].FullName 'backup.json') -Raw | ConvertFrom-Json
  Check 'backup records both versions' ($meta.installed -eq $officialVersion -and $meta.incoming -eq $Version) "installed=$($meta.installed) incoming=$($meta.incoming)"
  Check 'backup has the data' ((Test-Path (Join-Path $b[0].FullName 'Roaming\state.json')) -and (Test-Path (Join-Path $b[0].FullName 'Local\gamebanana-catalog.db')) -and (Test-Path (Join-Path $b[0].FullName 'Local\EBWebView\marker.txt')))
}
$lnk = @(Get-ChildItem (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs') -Recurse -Filter '*Deadlock Mod Manager*.lnk' -ErrorAction SilentlyContinue)
Check 'Start menu shortcut' ($lnk.Count -ge 1)
$protocolsAfter = Get-Protocols
Check 'link handlers kept' (-not (Compare-Object $protocolsBefore $protocolsAfter)) "before=$($protocolsBefore -join ',') after=$($protocolsAfter -join ',')"

# 3. An in-app update runs the installer like this
Check 'update-mode install' ((Install $Setup @('/P', '/UPDATE')) -eq 0)
Check 'backup taken on update' ((Get-Backups).Count -eq 2)

# 4. Never install over a running DMM without a backup
$app = Start-Process -FilePath $Exe -PassThru
Start-Sleep -Seconds 5
if ($app.HasExited) {
  Write-Host "SKIP running-app check: the app exited on its own on the runner (code $($app.ExitCode))"
}
else {
  $code = Install $Setup @('/S')
  Check 'install refused while DMM runs' ($code -ne 0) "exit $code"
  Check 'no backup while DMM runs' ((Get-Backups).Count -eq 2)
  Stop-Process -Id $app.Id -Force  # started by this test
}

if (Test-Path (Join-Path $Backups 'backup.log')) { Get-Content (Join-Path $Backups 'backup.log') }
if ($failures) { throw "Migration test failed: $($failures -join ', ')" }
Write-Host 'Migration test passed.'
