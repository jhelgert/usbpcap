[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [switch]$SkipSmokeTest
)

$ErrorActionPreference = 'Stop'

function Assert-Arm64Image([string]$Path, [int]$Subsystem) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64 -or [BitConverter]::ToUInt16($bytes, 0) -ne 0x5A4D) {
        throw "Not a DOS/PE image: $Path"
    }
    $pe = [BitConverter]::ToInt32($bytes, 0x3C)
    if ($pe -lt 0 -or $pe + 94 -gt $bytes.Length -or [BitConverter]::ToUInt32($bytes, $pe) -ne 0x4550) {
        throw "Invalid PE header: $Path"
    }
    if ([BitConverter]::ToUInt16($bytes, $pe + 4) -ne 0xAA64) { throw "Not native ARM64: $Path" }
    if ([BitConverter]::ToUInt16($bytes, $pe + 24) -ne 0x20B) { throw "Not PE32+: $Path" }
    if ([BitConverter]::ToUInt16($bytes, $pe + 92) -ne $Subsystem) { throw "Wrong PE subsystem: $Path" }
    Write-Host "PASS ARM64 PE32+ image: $Path"
}

function Test-Command([string]$Exe, [string]$Argument, [string]$Expected) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Exe
    $info.Arguments = $Argument
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            $process.Kill()
            throw "USBPcapCMD $Argument timed out."
        }
        if ($process.ExitCode -ne 0 -or $stdout.Result -notmatch $Expected) {
            throw "USBPcapCMD $Argument failed ($($process.ExitCode)): $($stdout.Result) $($stderr.Result)"
        }
        Write-Host "PASS USBPcapCMD $Argument"
    } finally {
        $process.Dispose()
    }
}

try {
    $output = Join-Path $PSScriptRoot "build\ARM64\$Configuration"
    $driver = Join-Path $output 'USBPcapDriver\USBPcap.sys'
    $cmd = Join-Path $output 'USBPcapCMD\USBPcapCMD.exe'
    Assert-Arm64Image $driver 1
    Assert-Arm64Image $cmd 2

    $package = Join-Path $output 'USBPcapDriver\package'
    foreach ($name in 'USBPcap.sys', 'USBPcap.inf', 'USBPcaparm64.cat') {
        if (-not (Test-Path (Join-Path $package $name))) { throw "Missing package file: $name" }
    }
    if ((Get-FileHash $driver).Hash -ne (Get-FileHash (Join-Path $package 'USBPcap.sys')).Hash) {
        throw 'Packaged driver does not match the built driver.'
    }
    if ((Get-Content (Join-Path $package 'USBPcap.inf') -Raw) -notmatch '\[DefaultInstall.NTarm64\]') {
        throw 'Missing ARM64 INF install section.'
    }
    Write-Host 'PASS driver package contents (unsigned)'

    if (-not $SkipSmokeTest) {
        if ([Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'Machine') -ne 'ARM64') {
            throw 'The smoke test requires an ARM64 host. Use -SkipSmokeTest on a cross-build host.'
        }
        Test-Command $cmd '--help' 'Usage: USBPcapCMD.exe'
        Test-Command $cmd '--extcap-version' 'extcap \{version='
    }
    Write-Host 'No driver was installed or loaded; capture and kernel runtime behavior are not tested.'
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
