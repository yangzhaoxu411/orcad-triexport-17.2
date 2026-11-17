[CmdletBinding()]
param(
    [string]$Python = 'python',
    [string]$Tclsh = 'tclsh',
    [string]$BuildDependencies = '',
    [switch]$SkipTclTests
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$base = $PSScriptRoot
$work = Join-Path $base '.work'
$null = New-Item -ItemType Directory -Path (Join-Path $work 'tmp') -Force
$saved = @{}
foreach ($name in @('PYTHONPATH', 'PYINSTALLER_CONFIG_DIR', 'TEMP', 'TMP')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
Push-Location $base
try {
    if ($BuildDependencies) { $env:PYTHONPATH = (Resolve-Path -LiteralPath $BuildDependencies).Path }
    $env:PYINSTALLER_CONFIG_DIR = Join-Path $work 'pyinstaller-cache'
    $env:TEMP = Join-Path $work 'tmp'
    $env:TMP = $env:TEMP
    & $Python -m unittest discover -s tests -p test_worker.py -v
    if ($LASTEXITCODE) { throw 'Python tests failed.' }
    & (Join-Path $base 'tests/test_installer.ps1')
    if (-not $SkipTclTests) {
        & $Tclsh tests/test_capture_mock.tcl
        if ($LASTEXITCODE) { throw 'Tcl mock tests failed.' }
        & $Tclsh tests/test_ui_mock.tcl
        if ($LASTEXITCODE) { throw 'UI regression tests failed.' }
    }
    & $Python -m PyInstaller --noconfirm --clean --onedir --windowed --noupx `
        --name TriExportWorker --distpath (Join-Path $work 'dist') `
        --workpath (Join-Path $work 'pyinstaller') --specpath $work `
        --exclude-module PIL --exclude-module cryptography --exclude-module Crypto `
        --exclude-module numpy --exclude-module matplotlib --exclude-module pytest `
        --exclude-module tkinter --exclude-module IPython src/worker.py
    if ($LASTEXITCODE) { throw 'Worker build failed.' }
    & $Python scripts/assemble_release.py
    if ($LASTEXITCODE) { throw 'Packaging failed.' }
    $exe = Join-Path $base 'release\OrCAD-TriExport-17.2-1.0.0-rc6\payload\bin\TriExportWorker.exe'
    $resultFile = Join-Path $work 'worker-selftest.json'
    if (Test-Path -LiteralPath $resultFile) { Remove-Item -LiteralPath $resultFile }
    # A windowless helper may return immediately in PowerShell; use -Wait.
    $process = Start-Process -FilePath $exe -ArgumentList @('selftest', ('"' + $resultFile + '"')) -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $resultFile)) { throw 'Compiled worker failed to start.' }
    $result = Get-Content -LiteralPath $resultFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $result.ok) { throw 'Compiled worker self-test failed.' }
    if (-not $SkipTclTests) {
        & $Tclsh tests/test_worker_bridge.tcl $exe
        if ($LASTEXITCODE) { throw 'Compiled worker / Tcl bridge test failed.' }
    }
    Write-Output 'Build, offline tests, packaging and compiled-worker startup check passed.'
} finally {
    Pop-Location
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}
