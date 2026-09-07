param([switch]$SkipSelfTest)
$ErrorActionPreference = 'Stop'
$releaseRoot = Split-Path -Parent $PSScriptRoot
$python = Get-Command py -ErrorAction SilentlyContinue
if ($python) {
    & $python.Source -3 (Join-Path $releaseRoot 'rebuild_payload.py')
} else {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { throw 'Python 3 is required to rebuild the checked addon payload. Install Python 3, then run Build.cmd again.' }
    & $python.Source (Join-Path $releaseRoot 'rebuild_payload.py')
}
if ($LASTEXITCODE -ne 0) { throw 'Payload validation failed; the installer was not compiled.' }
$manifestPath = Join-Path $releaseRoot 'manifest.json'
$manifest = ConvertFrom-Json -InputObject (Get-Content -Raw -LiteralPath $manifestPath)
$outputPath = Join-Path $releaseRoot ('UBK-' + $manifest.version + '-Setup.exe')
& (Join-Path $PSScriptRoot 'Build-Installer.ps1') -ManifestPath $manifestPath -PayloadZipPath (Join-Path $releaseRoot 'payload.zip') -OutputPath $outputPath -RunSelfTest:(-not $SkipSelfTest)
Write-Output ('Ready: ' + $outputPath)
Write-Output 'This command builds UBK and runs temporary fixture tests. It does not install into WoW.'
