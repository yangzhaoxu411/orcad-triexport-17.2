Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ProductMarker = 'OrCADTriExport-17.2-owned-v1'
$script:LoaderMarker = '# OrCADTriExport-17.2-loader-v1'

function Get-TriExportHome {
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not available.' }
    return [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'OrCADTriExport\17.2'))
}

function Assert-Capture172([string]$Root) {
    $full = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path
    $capture = Join-Path $full 'tools\bin\capture.exe'
    $netlister = Join-Path $full 'tools\bin\pstswp.exe'
    $autoload = Join-Path $full 'tools\capture\tclscripts\capAutoLoad'
    foreach ($path in @($capture, $netlister, $autoload)) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Not a Capture 17.2 installation: $full" }
    }
    $version = (Get-Item -LiteralPath $capture).VersionInfo.FileVersion
    if ($version -notmatch '^17\.2(?:\D|$)') { throw "Expected Capture 17.2; found '$version' at $full" }
    return $full
}

function Find-Capture172([string]$RequestedRoot) {
    if ($RequestedRoot) { return Assert-Capture172 $RequestedRoot }
    $candidates = @(
        $env:CDSROOT,
        'D:\cadence17.2\Cadence\SPB_17.2',
        'C:\Cadence\SPB_17.2',
        'D:\Cadence\SPB_17.2',
        'C:\Cadence\SPB_17.2-2016'
    )
    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        foreach ($entry in @(Get-ItemProperty -Path $key -ErrorAction SilentlyContinue)) {
            if ($entry.PSObject.Properties['DisplayName'] -and
                $entry.PSObject.Properties['InstallLocation'] -and
                $entry.DisplayName -match '(?i)(Cadence|OrCAD).*17\.2') {
                $candidates += $entry.InstallLocation
            }
        }
    }
    $valid = @()
    foreach ($path in @($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        try { $valid += Assert-Capture172 $path } catch { continue }
    }
    $valid = @($valid | Select-Object -Unique)
    if ($valid.Count -eq 1) { return $valid[0] }
    if ($valid.Count -gt 1) { throw "Multiple installations found. Use -CadenceRoot with one of: $($valid -join ', ')" }
    throw 'Capture 17.2 was not found. Run install.ps1 -CadenceRoot <SPB_17.2 directory>.'
}

function Assert-OwnedDirectory([string]$Path, [string]$Parent) {
    $full = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path.TrimEnd('\', '/')
    $parentFull = (Resolve-Path -LiteralPath $Parent -ErrorAction Stop).Path.TrimEnd('\', '/')
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($full), $parentFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to change a directory outside the expected parent: $full"
    }
    $item = Get-Item -LiteralPath $full -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing reparse point: $full" }
    $marker = Join-Path $full '.triexport-owned'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or
        [IO.File]::ReadAllText($marker).Trim() -ne $script:ProductMarker) {
        throw "Directory is not marked as owned by TriExport: $full"
    }
    $links = @(Get-ChildItem -LiteralPath $full -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($links.Count) { throw "Unexpected reparse point inside $full" }
    return $full
}

function Remove-OwnedDirectory([string]$Path, [string]$Parent) {
    $verified = Assert-OwnedDirectory $Path $Parent
    Remove-Item -LiteralPath $verified -Recurse -Force
}

function Assert-OwnedLoader([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        if (-not [IO.File]::ReadAllText($Path).StartsWith($script:LoaderMarker)) {
            throw "Another file already occupies the loader path. It will not be overwritten: $Path"
        }
    }
}

function Test-Payload([string]$PackageRoot) {
    $payload = Join-Path $PackageRoot 'payload'
    $manifestPath = Join-Path $PackageRoot 'payload-sha256.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Package checksum manifest is missing.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($prop in $manifest.PSObject.Properties) {
        if ($prop.Name -match '(^[/\\]|(^|[/\\])\.\.([/\\]|$)|:)') { throw 'Unsafe path in checksum manifest.' }
        $file = Join-Path $payload $prop.Name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing package file: $($prop.Name)" }
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $prop.Value) { throw "Package checksum mismatch: $($prop.Name)" }
    }
    $actual = @(Get-ChildItem -LiteralPath $payload -File -Recurse -Force)
    if ($actual.Count -ne @($manifest.PSObject.Properties).Count) { throw 'Unexpected files in payload.' }
    foreach ($required in @('TriExport.tcl', 'zzTriExport.tcl', 'bin/TriExportWorker.exe', '.triexport-owned')) {
        if (-not $manifest.PSObject.Properties[$required]) { throw "Incomplete package: $required" }
    }
    return $payload
}
