[CmdletBinding()]
param([string]$CadenceRoot)
. (Join-Path $PSScriptRoot 'Installer.Common.ps1')
$destination = Get-TriExportHome
$parent = Split-Path -Parent $destination
if (-not (Test-Path -LiteralPath $destination)) { Write-Output 'TriExport is not installed for this user.'; exit 0 }
$null = Assert-OwnedDirectory $destination $parent
if (-not $CadenceRoot) {
    $receipt = Get-Content -LiteralPath (Join-Path $destination 'install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $CadenceRoot = $receipt.cadence_root
}
$cadence = Assert-Capture172 $CadenceRoot
if (Get-Process -Name capture -ErrorAction SilentlyContinue) { throw 'Close Capture before uninstalling.' }
$loader = Join-Path $cadence 'tools\capture\tclscripts\capAutoLoad\zzTriExport.tcl'
Assert-OwnedLoader $loader
if (Test-Path -LiteralPath $loader) { Remove-Item -LiteralPath $loader -Force }
Remove-OwnedDirectory $destination $parent
Write-Output 'TriExport removed. Exported files, settings, diagnostic logs and Ghostscript were kept.'
