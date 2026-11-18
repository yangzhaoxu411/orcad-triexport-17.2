[CmdletBinding()]
param([string]$CadenceRoot, [switch]$ValidateOnly, [switch]$UpdateForNextLaunch)
. (Join-Path $PSScriptRoot 'Installer.Common.ps1')

$payload = Test-Payload $PSScriptRoot
$cadence = Find-Capture172 $CadenceRoot
$destination = Get-TriExportHome
$parent = Split-Path -Parent $destination
$loader = Join-Path $cadence 'tools\capture\tclscripts\capAutoLoad\zzTriExport.tcl'
Assert-OwnedLoader $loader
if (Test-Path -LiteralPath $destination) { $null = Assert-OwnedDirectory $destination $parent }
if ($ValidateOnly) {
    Write-Output "Validated package and Capture 17.2. No files changed.`nCapture: $cadence`nPlugin: $destination`nLoader: $loader"
    exit 0
}
if (Get-Process -Name TriExportWorker -ErrorAction SilentlyContinue) {
    throw 'An export is running. Wait for it to finish before updating.'
}
if ($UpdateForNextLaunch -and -not (Test-Path -LiteralPath $destination)) {
    throw 'UpdateForNextLaunch is only available for an existing owned installation.'
}
if ((Get-Process -Name capture -ErrorAction SilentlyContinue) -and -not $UpdateForNextLaunch) {
    throw 'Close Capture before installing. The installer does not close applications.'
}

$null = New-Item -ItemType Directory -Path $parent -Force
$id = [Guid]::NewGuid().ToString('N')
$stage = Join-Path $parent "stage-$id"
$backup = Join-Path $parent "backup-$id"
$loaderTemp = "$loader.$id.tmp"
$oldLoader = if (Test-Path -LiteralPath $loader) { [IO.File]::ReadAllBytes($loader) } else { $null }
$movedOld = $false
$installedNew = $false
$wroteLoader = $false
try {
    $null = New-Item -ItemType Directory -Path $stage
    [IO.File]::WriteAllText((Join-Path $stage '.triexport-owned'), $script:ProductMarker)
    Get-ChildItem -LiteralPath $payload -Force | Copy-Item -Destination $stage -Recurse -Force
    [IO.File]::WriteAllText((Join-Path $stage 'install.json'),
        (@{ version = '1.0.0-rc8'; cadence_root = $cadence; installed_utc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json),
        (New-Object Text.UTF8Encoding($false)))
    # Prove loader-folder write access before replacing the current version.
    Copy-Item -LiteralPath (Join-Path $stage 'zzTriExport.tcl') -Destination $loaderTemp
    if (Test-Path -LiteralPath $destination) {
        $verified = Assert-OwnedDirectory $destination $parent
        Move-Item -LiteralPath $verified -Destination $backup
        $movedOld = $true
    }
    $verifiedStage = Assert-OwnedDirectory $stage $parent
    Move-Item -LiteralPath $verifiedStage -Destination $destination
    $installedNew = $true
    Move-Item -LiteralPath $loaderTemp -Destination $loader -Force
    $wroteLoader = $true
} catch {
    $failure = $_
    if ($wroteLoader) {
        if ($null -ne $oldLoader) { [IO.File]::WriteAllBytes($loader, $oldLoader) }
        else { Remove-Item -LiteralPath $loader -Force }
    }
    if ($installedNew) { Remove-OwnedDirectory $destination $parent }
    if ($movedOld) {
        $verifiedBackup = Assert-OwnedDirectory $backup $parent
        Move-Item -LiteralPath $verifiedBackup -Destination $destination
    }
    throw "Installation failed: $failure`nIf access was denied, run install.cmd as administrator using the same Windows account."
} finally {
    if (Test-Path -LiteralPath $loaderTemp) { Remove-Item -LiteralPath $loaderTemp -Force }
    if (Test-Path -LiteralPath $stage) { Remove-OwnedDirectory $stage $parent }
}
if (Test-Path -LiteralPath $backup) { Remove-OwnedDirectory $backup $parent }
Write-Output "Installed TriExport 1.0.0-rc8. Restart Capture 17.2, then choose TriExport > Export Files after Help.`nPlugin: $destination"
