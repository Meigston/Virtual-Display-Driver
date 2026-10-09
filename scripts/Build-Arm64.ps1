#Requires -Version 5.1
<#
.SYNOPSIS
    Builds MttVDD Release|ARM64 with the WDK/SDK from NuGet and stages an UNSIGNED attestation CAB.

.DESCRIPTION
    1. Restores "Virtual Display Driver (HDR)\packages.config" (WDK/SDK 10.0.26100.x) with nuget.exe.
    2. Builds MttVDD.sln for ARM64 with SignMode=Off (no test certificate, nothing is signed).
    3. Copies MttVDD.inf, MttVDD.dll and MttVDD.pdb into a single short-named folder, regenerates an
       unsigned catalog with Inf2Cat and validates the INF with InfVerif /h.
    4. Writes a makecab DDF and builds the CAB that Partner Center attestation expects
       (driver files inside one subfolder, never at the CAB root).

    The CAB still has to be signed with the organization's EV certificate and submitted to
    Partner Center (Hardware > Submit new hardware). Microsoft replaces the catalog.
    This script never signs, installs or trusts anything.

.EXAMPLE
    .\scripts\Build-Arm64.ps1

.EXAMPLE
    .\scripts\Build-Arm64.ps1 -PackagesDir C:\wdk\packages -NuGetExe C:\tools\nuget.exe
#>
[CmdletBinding()]
param(
    [string]$Configuration = 'Release',
    # Where the NuGet packages live (restored here if missing).
    [string]$PackagesDir,
    [string]$NuGetExe,
    [string]$MSBuildExe,
    # Output root; must be a local path (attestation rejects UNC paths).
    [string]$OutputDir,
    # Inf2Cat targets: UMDF 2.25 runs on Windows 10 1803 (RS4) and later.
    [string]$InfOs = '10_RS4_ARM64,10_RS5_ARM64,10_19H1_ARM64,10_VB_ARM64,10_CO_ARM64,10_NI_ARM64,10_GE_ARM64',
    [ValidateLength(1, 39)]
    [string]$PackageFolderName = 'MttVDD',
    [string]$CabName = 'MttVDD-ARM64-Attestation.cab',
    [switch]$SkipRestore,
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$vdd = Join-Path $repo 'Virtual Display Driver (HDR)'
$packagesConfig = Join-Path $vdd 'packages.config'
if (-not $PackagesDir) { $PackagesDir = Join-Path $vdd 'packages' }
if (-not $OutputDir) { $OutputDir = Join-Path $repo 'artifacts\ARM64' }
$PackagesDir = $PackagesDir.TrimEnd('\')

function Write-Step([string]$Text) { Write-Host "==> $Text" }

function Get-PeMachine([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $pe = [BitConverter]::ToInt32($bytes, 0x3c)
    return [BitConverter]::ToUInt16($bytes, $pe + 4)
}

[xml]$config = Get-Content -LiteralPath $packagesConfig
$wdkVersion = ($config.packages.package | Where-Object { $_.id -eq 'Microsoft.Windows.WDK.ARM64' }).version
if (-not $wdkVersion) { throw "Microsoft.Windows.WDK.ARM64 not found in $packagesConfig" }
$wdkRoot = Join-Path $PackagesDir "Microsoft.Windows.WDK.ARM64.$wdkVersion\c"

# 1. Restore
if (-not $SkipRestore) {
    if (-not $NuGetExe) {
        $cmd = Get-Command nuget.exe -ErrorAction SilentlyContinue
        if ($cmd) {
            $NuGetExe = $cmd.Source
        } else {
            $NuGetExe = Join-Path $env:TEMP 'nuget.exe'
            if (-not (Test-Path -LiteralPath $NuGetExe)) {
                Write-Step 'Downloading nuget.exe'
                Invoke-WebRequest -UseBasicParsing 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe' -OutFile $NuGetExe
            }
        }
    }
    Write-Step "Restoring WDK/SDK $wdkVersion into $PackagesDir"
    & $NuGetExe restore $packagesConfig -PackagesDirectory $PackagesDir -NonInteractive
    if ($LASTEXITCODE -ne 0) { throw "nuget restore failed ($LASTEXITCODE)" }
}
if (-not (Test-Path -LiteralPath $wdkRoot)) { throw "WDK NuGet package not found: $wdkRoot" }

# 2. Build
$release = Join-Path $vdd "ARM64\$Configuration"
if (-not $SkipBuild) {
    if (-not $MSBuildExe) {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (-not (Test-Path -LiteralPath $vswhere)) { throw 'vswhere.exe not found; pass -MSBuildExe' }
        $vsPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
        if (-not $vsPath) { throw 'No Visual Studio / Build Tools with MSBuild found' }
        $bin = Join-Path $vsPath 'MSBuild\Current\Bin'
        $MSBuildExe = Join-Path $bin 'MSBuild.exe'
        $native = Join-Path $bin ($env:PROCESSOR_ARCHITECTURE.ToLower() + '\MSBuild.exe')
        if (Test-Path -LiteralPath $native) { $MSBuildExe = $native }
    }
    Write-Step "Building MttVDD $Configuration|ARM64 with $MSBuildExe"
    & $MSBuildExe (Join-Path $vdd 'MttVDD.sln') /t:Rebuild /m /nodeReuse:false /nologo /v:minimal `
        "/p:Configuration=$Configuration" /p:Platform=ARM64 /p:SignMode=Off `
        "/p:VddPackagesDir=$PackagesDir" "/p:VddWdkNuGetVersion=$wdkVersion"
    if ($LASTEXITCODE -ne 0) { throw "MSBuild failed ($LASTEXITCODE)" }
}

# 3. Attestation folder
if ($OutputDir -match '^\\\\') { throw "OutputDir must be a local path, not UNC: $OutputDir" }
$attestation = Join-Path $OutputDir 'attestation'
$stage = Join-Path $attestation $PackageFolderName
if (Test-Path -LiteralPath $attestation) { Remove-Item -LiteralPath $attestation -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $release 'MttVDD\MttVDD.inf') -Destination $stage
Copy-Item -LiteralPath (Join-Path $release 'MttVDD\MttVDD.dll') -Destination $stage
Copy-Item -LiteralPath (Join-Path $release 'MttVDD.pdb') -Destination $stage

$machine = Get-PeMachine (Join-Path $stage 'MttVDD.dll')
if ($machine -ne 0xAA64) { throw ('MttVDD.dll is not ARM64 (PE machine 0x{0:X4})' -f $machine) }
Write-Step 'MttVDD.dll PE machine 0xAA64 (ARM64)'

$inf2cat = Join-Path $wdkRoot "bin\$($wdkVersion -replace '\.\d+$', '.0')\x86\inf2cat.exe"
Write-Step "Inf2Cat /os:$InfOs (catalog stays unsigned)"
& $inf2cat "/driver:$stage" "/os:$InfOs" /uselocaltime
if ($LASTEXITCODE -ne 0) { throw "Inf2Cat failed ($LASTEXITCODE)" }

# InfVerif must match the host CPU; the ARM64 WDK package only ships an ARM64 build of it.
$hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$infverif = Get-ChildItem -Path $PackagesDir -Directory -Filter "Microsoft.Windows.WDK.*.$wdkVersion" |
    ForEach-Object { Get-ChildItem -Path (Join-Path $_.FullName 'c\tools') -Recurse -Filter infverif.exe -ErrorAction SilentlyContinue } |
    Where-Object { $_.Directory.Name -eq $hostArch } | Select-Object -First 1
if ($infverif) {
    Write-Step 'InfVerif /h (WHQL signature rules)'
    & $infverif.FullName /h /v (Join-Path $stage 'MttVDD.inf')
    if ($LASTEXITCODE -ne 0) { Write-Warning "InfVerif /h reported errors ($LASTEXITCODE)" }
}

# 4. DDF + makecab
$ddf = Join-Path $attestation 'MttVDD-ARM64.ddf'
$ddfLines = @(
    ';*** MttVDD ARM64 attestation submission (unsigned; EV-sign the CAB afterwards)'
    '.OPTION EXPLICIT'
    '.Set CabinetFileCountThreshold=0'
    '.Set FolderFileCountThreshold=0'
    '.Set FolderSizeThreshold=0'
    '.Set MaxCabinetSize=0'
    '.Set MaxDiskFileCount=0'
    '.Set MaxDiskSize=0'
    '.Set CompressionType=MSZIP'
    '.Set Cabinet=on'
    '.Set Compress=on'
    ".Set CabinetNameTemplate=$CabName"
    ".Set DiskDirectoryTemplate=""$attestation"""
    '; Driver files go in a single subfolder, never at the CAB root'
    ".Set DestinationDir=$PackageFolderName"
)
$ddfLines += Get-ChildItem -LiteralPath $stage -File | ForEach-Object { '"' + $_.FullName + '"' }
Set-Content -LiteralPath $ddf -Value $ddfLines -Encoding ASCII

Write-Step 'makecab'
Push-Location $attestation
try {
    & makecab.exe /F $ddf | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "makecab failed ($LASTEXITCODE)" }
} finally {
    Pop-Location
    Remove-Item -LiteralPath (Join-Path $attestation 'setup.inf'), (Join-Path $attestation 'setup.rpt') -ErrorAction SilentlyContinue
}

$cab = Join-Path $attestation $CabName
Write-Step "CAB: $cab"
& expand.exe -D $cab | Where-Object { $_ -match ':' }
Get-ChildItem -LiteralPath $stage -File | ForEach-Object {
    '{0,-12} {1,10} {2}' -f $_.Name, $_.Length, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower()
}
'{0,-12} {1,10} {2}' -f $CabName, (Get-Item -LiteralPath $cab).Length, (Get-FileHash -LiteralPath $cab -Algorithm SHA256).Hash.ToLower()
Write-Host ''
Write-Host 'Next: sign the CAB with the EV certificate, e.g.'
Write-Host "  signtool sign /fd sha256 /tr http://timestamp.digicert.com /td sha256 /n `"<EV subject>`" `"$cab`""
Write-Host 'then Partner Center > Hardware > Submit new hardware (test-signing options unchecked).'
