# Offline installer safeguards only. Never installs into Cadence or LocalAppData.
. (Join-Path $PSScriptRoot '..\Installer.Common.ps1')
$testBase = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\.work\installer-tests'))
$null = New-Item -ItemType Directory -Path $testBase -Force
$run = Join-Path $testBase ([Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $run
$owned = Join-Path $run 'owned'
$foreign = Join-Path $run 'foreign'
$null = New-Item -ItemType Directory -Path $owned
$null = New-Item -ItemType Directory -Path $foreign
[IO.File]::WriteAllText((Join-Path $owned '.triexport-owned'), $script:ProductMarker)
[IO.File]::WriteAllText((Join-Path $foreign 'user.txt'), 'keep')
$checks = 0
function Expect-Throws([scriptblock]$Action) {
    $thrown = $false
    try { & $Action } catch { $thrown = $true }
    if (-not $thrown) { throw 'Expected safeguard to reject this operation.' }
    $script:checks++
}
$verified = Assert-OwnedDirectory $owned $run
if ($verified -ne $owned) { throw 'Owned directory did not resolve correctly.' }
$checks++
Expect-Throws { Assert-OwnedDirectory $foreign $run }
Expect-Throws { Assert-OwnedDirectory $owned $testBase }
Expect-Throws { Remove-OwnedDirectory $foreign $run }
if ([IO.File]::ReadAllText((Join-Path $foreign 'user.txt')) -ne 'keep') { throw 'Foreign file changed.' }
$checks++
$loader = Join-Path $run 'loader.tcl'
[IO.File]::WriteAllText($loader, '# foreign script')
Expect-Throws { Assert-OwnedLoader $loader }
[IO.File]::WriteAllText($loader, "$script:LoaderMarker -- test")
Assert-OwnedLoader $loader
$checks++
Remove-OwnedDirectory $owned $run
if (Test-Path -LiteralPath $owned) { throw 'Owned directory was not removed.' }
$checks++
if (-not (Test-Path -LiteralPath (Join-Path $foreign 'user.txt'))) { throw 'Foreign file was removed.' }
$checks++
# Mark this single, known test fixture for guarded cleanup under its test parent.
[IO.File]::WriteAllText((Join-Path $run '.triexport-owned'), $script:ProductMarker)
Remove-OwnedDirectory $run $testBase
Write-Output "PASS: $checks installer safeguards; no installation was performed."
