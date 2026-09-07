param(
    [Parameter(Mandatory=$true)][string]$ManifestPath,
    [Parameter(Mandatory=$true)][string]$PayloadZipPath,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [switch]$RunSelfTest
)
$ErrorActionPreference = 'Stop'
$sourceDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The .NET Framework C# compiler was not found.' }
$frameworkDirectory = Split-Path -Parent $compiler
$manifestFile = (Resolve-Path -LiteralPath $ManifestPath).Path
$payloadFile = (Resolve-Path -LiteralPath $PayloadZipPath).Path
$outputFile = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $outputFile
[IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
$arguments = @(
    '/nologo', '/target:winexe', '/optimize+', '/platform:anycpu', '/utf8output',
    ('/win32manifest:' + (Join-Path $sourceDirectory 'Installer.manifest')),
    ('/out:' + $outputFile),
    ('/resource:' + $manifestFile + ',UBKManifest.json'),
    ('/resource:' + $payloadFile + ',UBKPayload.zip')
)
foreach ($reference in @('System.dll', 'System.Core.dll', 'System.Windows.Forms.dll', 'System.Drawing.dll', 'System.Runtime.Serialization.dll', 'System.IO.Compression.dll', 'System.IO.Compression.FileSystem.dll')) {
    $arguments += '/reference:' + (Join-Path $frameworkDirectory $reference)
}
$arguments += Join-Path $sourceDirectory 'Installer.cs'
$arguments += Join-Path $sourceDirectory 'ProspectingImport.cs'
$arguments += Join-Path $sourceDirectory 'SavedDataMigration.cs'
$arguments += Join-Path $sourceDirectory 'TSMBridgeImport.cs'
$arguments += Join-Path $sourceDirectory 'LegacyAddonArchive.cs'
$arguments += Join-Path $sourceDirectory 'TSMBridgeImportTests.cs'
$arguments += Join-Path $sourceDirectory 'SavedDataMigrationTests.cs'
$arguments += Join-Path $sourceDirectory 'InstallPrerequisites.cs'
$arguments += Join-Path $sourceDirectory 'InstallPrerequisitesTests.cs'
& $compiler @arguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outputFile)) { throw 'Installer compilation failed.' }
Write-Output ('Built: ' + $outputFile)
if ($RunSelfTest) {
    # This is the only executable launch in the build helper. It creates an inert
    # temporary client internally and cannot select or install into a real client.
    $existingReports = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'UBK-Installer-SelfTest-*' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    $process = Start-Process -FilePath $outputFile -ArgumentList '--self-test' -Wait -PassThru
    $newReports = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'UBK-Installer-SelfTest-*' | Where-Object { $existingReports -notcontains $_.FullName } | Sort-Object LastWriteTimeUtc -Descending)
    $publicResults = New-Object 'System.Collections.Generic.List[string]'
    $publicResults.Add('UBK installer fixture results')
    $publicResults.Add('Executed against isolated temporary fixtures. No live WoW installation was changed.')
    foreach ($reportDirectory in $newReports) {
        $report = Join-Path $reportDirectory.FullName 'self-test-result.txt'
        if (Test-Path -LiteralPath $report) {
            foreach ($line in Get-Content -LiteralPath $report) {
                Write-Output $line
                if ($line.StartsWith('PASS:') -or $line.StartsWith('FAIL:')) {
                    $publicResults.Add($line.Replace($reportDirectory.FullName, '<temporary fixture>'))
                }
            }
        }
    }
    $publicResults.Add('These checks do not verify live mailbox behavior or in-game UI behavior.')
    [IO.File]::WriteAllLines((Join-Path (Split-Path -Parent $sourceDirectory) 'INSTALLER_TEST_RESULTS.txt'), $publicResults.ToArray(), (New-Object Text.UTF8Encoding($false)))
    if ($process.ExitCode -ne 0) { throw ('Installer self-test failed with exit code ' + $process.ExitCode) }
    if ($newReports.Count -eq 0) { throw 'Installer self-test returned without a new temporary report.' }
}
