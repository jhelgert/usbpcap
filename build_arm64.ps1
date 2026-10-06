[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [string]$VisualStudioPath,
    [string]$SpectreLibraryDirectory,
    [switch]$NoRestore,
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'
try {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not $VisualStudioPath) {
        if (-not (Test-Path $vswhere)) {
            throw 'Visual Studio Installer not found. Install Visual Studio 2026 with ARM64 C++ build tools.'
        }
        $VisualStudioPath = & $vswhere -latest -prerelease -products '*' -version '[18.0,19.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath
        if (-not $VisualStudioPath) {
            throw 'Visual Studio 2026 ARM64 C++ tools not found. Add the MSVC ARM64/ARM64EC build tools component.'
        }
    }

    $msbuild = Join-Path $VisualStudioPath 'MSBuild\Current\Bin\MSBuild.exe'
    # Emulated PowerShell can report AMD64 even on an ARM64 machine.
    $hostArchitecture = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'Machine')
    if ($hostArchitecture -eq 'ARM64') {
        $nativeMSBuild = Join-Path $VisualStudioPath 'MSBuild\Current\Bin\arm64\MSBuild.exe'
        if (Test-Path $nativeMSBuild) { $msbuild = $nativeMSBuild }
    } else {
        $nativeMSBuild = Join-Path $VisualStudioPath 'MSBuild\Current\Bin\amd64\MSBuild.exe'
        if (Test-Path $nativeMSBuild) { $msbuild = $nativeMSBuild }
    }
    if (-not (Test-Path $msbuild)) { throw "MSBuild not found: $msbuild" }

    $tools = Join-Path $PSScriptRoot '.tools'
    if (-not $NoRestore) {
        $nuget = Join-Path $tools 'nuget-6.14.0.exe'
        if (-not (Test-Path $nuget)) {
            New-Item -ItemType Directory -Force -Path $tools | Out-Null
            Write-Host 'Downloading NuGet 6.14.0 from dist.nuget.org...'
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $download = "$nuget.download"
            Invoke-WebRequest 'https://dist.nuget.org/win-x86-commandline/v6.14.0/nuget.exe' -UseBasicParsing -OutFile $download
            $signature = Get-AuthenticodeSignature $download
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
                Remove-Item $download
                throw 'NuGet executable did not have a valid Microsoft Authenticode signature.'
            }
            Move-Item $download $nuget
        }
        & $nuget restore (Join-Path $PSScriptRoot 'packages.config') -PackagesDirectory (Join-Path $PSScriptRoot 'packages') -Source 'https://api.nuget.org/v3/index.json' -NonInteractive
        if ($LASTEXITCODE -ne 0) { throw "NuGet restore failed ($LASTEXITCODE)." }
    }

    # The NuGet WDK contains the kit, but its VS platform-toolset integration is
    # a separate component. Use a local MSBuild overlay when it is not installed.
    $vcTargets = Join-Path $VisualStudioPath 'MSBuild\Microsoft\VC\v180'
    $wdkToolset = 'Platforms\ARM64\PlatformToolsets\WindowsKernelModeDriver10.0\Toolset.props'
    $localTargets = Join-Path $tools 'vctargets\v180'
    if (-not (Test-Path (Join-Path $vcTargets $wdkToolset))) {
        if (-not $NoRestore) {
            $archive = Join-Path $tools 'wdk-build.zip'
            $hash = 'fc94cb3a77269a0c5374ee08292cb6b5804af86da04112763566f666daccf15b'
            if (-not (Test-Path $archive)) {
                Write-Host 'Downloading Microsoft WDK MSBuild integration (18.9.11915.232)...'
                Invoke-WebRequest "https://download.visualstudio.microsoft.com/download/pr/bb2a0130-3d29-484b-a4a0-eea5313ed282/$hash/payload.vsix" -UseBasicParsing -OutFile $archive
            }
            if ((Get-FileHash $archive -Algorithm SHA256).Hash -ne $hash) {
                throw 'WDK MSBuild integration SHA256 mismatch. Delete .tools\wdk-build.zip and retry.'
            }
            $extension = Join-Path $tools 'wdk-build'
            Expand-Archive $archive $extension -Force
            New-Item -ItemType Directory -Force -Path $localTargets | Out-Null
            Copy-Item (Join-Path $vcTargets '*') $localTargets -Recurse -Force
            Copy-Item (Join-Path $extension 'Contents\MSBuild\Microsoft\VC\v180\*') $localTargets -Recurse -Force
        }
        if (-not (Test-Path (Join-Path $localTargets $wdkToolset))) {
            throw 'Local WDK build integration is missing. Run without -NoRestore first.'
        }
    }

    $extraProperties = @()
    if (-not $SpectreLibraryDirectory) {
        $vcVersion = (Get-Content (Join-Path $VisualStudioPath 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt') -Raw).Trim()
        $localSpectre = Join-Path $tools "vc-spectre\Contents\VC\Tools\MSVC\$vcVersion\lib\spectre\arm64"
        if (Test-Path (Join-Path $localSpectre 'libcmt.lib')) { $SpectreLibraryDirectory = $localSpectre }
    }
    if ($SpectreLibraryDirectory) {
        $SpectreLibraryDirectory = (Resolve-Path $SpectreLibraryDirectory).Path
        if (-not (Test-Path (Join-Path $SpectreLibraryDirectory 'libcmt.lib'))) {
            throw 'SpectreLibraryDirectory must contain the ARM64 Spectre-mitigated libraries for your MSVC version.'
        }
        $extraProperties += "/p:VC_LibraryPath_VC_Desktop_CurrentPlatform_spectre=$SpectreLibraryDirectory"
        $extraProperties += "/p:VC_LibraryPath_VC_ARM64_Desktop_spectre=$SpectreLibraryDirectory"
    }

    $target = 'Build'
    if ($Rebuild) { $target = 'Rebuild' }
    & $msbuild (Join-Path $PSScriptRoot 'USBPcap.ARM64.sln') /m /nologo "/t:$target" "/p:Configuration=$Configuration" /p:Platform=ARM64 /verbosity:minimal @extraProperties
    if ($LASTEXITCODE -ne 0) { throw "ARM64 build failed ($LASTEXITCODE)." }
    Write-Host "Unsigned ARM64 binaries: $PSScriptRoot\build\ARM64\$Configuration"
    Write-Host 'The driver must be signed before it can be loaded. See BUILDING-ARM64.md.'
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
