# Building USBPcap for Windows ARM64

`USBPcap.ARM64.sln` builds **native ARM64**, not ARM64EC or emulated x64:

- `USBPcap.sys`: the existing WDM USB class filter driver.
- `USBPcapCMD.exe`: the existing command-line/Wireshark extcap tool, with a
  statically linked CRT and its normal `asInvoker` execution level.

The ARM64 driver targets Windows 11 24H2 (build 26100) or newer. The compiler
and kit versions are build dependencies, not the minimum OS version. Runtime
compatibility still needs testing on the intended Windows release and hardware.
Development installation and operation have been **reported working in a Windows
ARM64 VM hosted by UTM on macOS**, using the procedure below. This is not a claim
of broad hardware compatibility, HVCI validation, or production certification.
The existing x86/x64 `SOURCES`, INX, build scripts and installers are unchanged.
The NSIS/WiX release installers are **not** ARM64 installers.

## Prerequisites

Use Windows 11 with PowerShell 5.1 or later and Visual Studio 2026 (or its Build
Tools) with:

- Desktop development with C++ / MSVC v145 build tools.
- ARM64/ARM64EC C++ build tools (the target here is ARM64).
- **C++ Spectre-mitigated libraries for ARM64/ARM64EC**, matching the installed
  MSVC version. Keep these enabled; the driver is compiled with `/Qspectre`.
- Recommended: the **Windows Driver Kit** Visual Studio component (or Windows
  Driver Kit Build Tools in the standalone Build Tools installer).

The build restores matching SDK/WDK NuGet packages, pinned in `packages.config`
to **10.0.28000.2526**. These support VS 2026; an installed Windows SDK alone does
not supply the kernel headers, libraries or driver build integration. An older
system SDK can remain installed alongside the restored kit.

First use downloads NuGet 6.14.0 from `dist.nuget.org`, verifies its Microsoft
Authenticode signature, and restores Microsoft packages from `api.nuget.org`.
NuGet also uses its normal per-user package cache. No elevation is needed.

If the VS WDK toolset integration is absent, the script downloads Microsoft's
WDK MSBuild integration VSIX (18.9.11915.232) from
`download.visualstudio.microsoft.com`, verifies its pinned SHA-256, and overlays
it on a **local copy** of the installed v180 MSBuild configuration. This lives
under `.tools/`; it does not install an extension or modify Visual Studio.

### Locally supplied Spectre libraries

Normally install the matching Spectre component with Visual Studio Installer.
For an offline/extracted Microsoft toolchain, supply the directory explicitly:

```powershell
.\build_arm64.ps1 -SpectreLibraryDirectory 'D:\toolchain\lib\spectre\arm64'
```

It must contain genuine ARM64 libraries matching your MSVC toolset. This script
**does not download Spectre libraries** or disable mitigations if they are absent.
It also recognizes the version-matched extraction layout
`.tools/vc-spectre/Contents/VC/Tools/MSVC/<version>/lib/spectre/arm64`.
That layout was used for the initial validation (MSVC 14.51.36231), with
Microsoft's `Microsoft.VC.14.51.CRT.ARM64.Desktop.spectre.base` package and SHA-256
`cca5181bc117f37e85f23aee1ee34c943b49ae634e1f157d696b3334515fbd2f`.
These local dependencies are ignored by Git and are not included in a clone.

## Build

From a normal PowerShell prompt in the checkout:

```powershell
.\build_arm64.ps1
.\build_arm64.ps1 -Configuration Debug
```

For a process-local execution-policy override, if needed:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build_arm64.ps1
```

The script finds VS 2026 installations with ARM64 tools, including Insiders, and
selects native ARM64 MSBuild on an ARM64 host even from an emulated PowerShell.
Use `-VisualStudioPath` to choose a particular installation. `-NoRestore` avoids
network restore after dependencies are populated; `-Rebuild` rebuilds all code.
After changing/updating Visual Studio, run without `-NoRestore` to refresh the
local MSBuild overlay if used, and update the matching Spectre libraries.

After restoring dependencies, the solution can also be opened in VS 2026 with
`Debug|ARM64` or `Release|ARM64`. Install the normal Spectre component for IDE
builds; the script's `-SpectreLibraryDirectory` override is command-line only.

Outputs for Release (substitute `Debug` for the other configuration):

```text
build/ARM64/Release/USBPcapCMD/USBPcapCMD.exe
build/ARM64/Release/USBPcapCMD/USBPcapCMD.pdb
build/ARM64/Release/USBPcapDriver/USBPcap.sys
build/ARM64/Release/USBPcapDriver/USBPcap.pdb
build/ARM64/Release/USBPcapDriver/package/USBPcap.sys
build/ARM64/Release/USBPcapDriver/package/USBPcap.inf
build/ARM64/Release/USBPcapDriver/package/USBPcaparm64.cat
```

The driver build runs WDK INF verification and Inf2Cat signability checks for
`10_GE_ARM64` (Windows 11 24H2 ARM64). The ARM64 INF is separate from the legacy
INF to preserve the older architectures' installation behavior. It registers
the same USB class upper filter and service as the original driver.

## Validation

On an ARM64 host, **before signing the package**:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test_arm64.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test_arm64.ps1 -Configuration Debug
```

If `running scripts is disabled on this system` appears when invoking a `.ps1`
directly, use the commands above. `-ExecutionPolicy Bypass` applies only to that
PowerShell process; no permanent execution-policy change or elevation is needed.

This checks the ARM64 (`0xAA64`) PE32+ machine type, native-driver/GUI-executable
subsystems, package presence, and equality of the built and packaged driver.
It also runs `USBPcapCMD --help` and `--extcap-version` with timeouts. On an x64
cross-build host use `-SkipSmokeTest` for binary/package checks only.

Signing the packaged SYS changes its bytes, so the equality check will no longer
match the unsigned build output. After signing, use the signature-verification
commands below instead. Do not rebuild merely to rerun this test: a rebuild
replaces the signed package.

Successful compilation does not establish kernel runtime correctness. Existing
source warnings (including deprecated `ExAllocatePoolWithTag`, size conversions,
and diagnostic format strings) remain; warnings are visible, not treated as
errors. This port does not change the capture protocol or the driver/CMD C code.

## Development installation: signing and boot policy

**The build produces an unsigned SYS, EXE and catalog. Use a disposable test
machine/VM, not a production system.** This USB class filter can affect USB input
and other devices; driver failures can crash Windows. Back up the VM/machine and
save its BitLocker/device-encryption recovery key before changing boot settings.

There are two separate requirements: Windows must be booted in test-signing
mode, and the driver package must be signed with a trusted development
certificate. Trusting a certificate alone does not enable test-signing mode.
The build scripts do neither automatically.

### 1. Disable Secure Boot on the test guest

Secure Boot normally prevents enabling test-signing. On physical hardware, use
that machine's documented UEFI procedure. On a managed machine, consult its
administrator rather than bypassing policy.

#### UTM on macOS

Change the **VM's** Secure Boot state, not the Mac's Startup Security settings:

1. Save the Windows recovery key if encryption is enabled, shut down Windows
   completely (do not suspend it), and back up the stopped VM.
2. In UTM, select the VM and open **Edit -> QEMU -> Maintenance**.
3. Check **Reset UEFI Variables** and **uncheck Preload Secure Boot Keys**.
4. Leave **UEFI Boot** and **TPM 2.0** enabled. Save and start the VM without
   quitting UTM first; maintenance options apply to the next startup only.

Resetting UEFI variables clears the Secure Boot keys and may also reset custom
boot entries/settings. It can trigger BitLocker recovery. If the VM no longer
boots normally, use the saved recovery information/backup rather than deleting
its TPM or disk. Menu names can differ by UTM version.

See [UTM's QEMU maintenance documentation](https://docs.getutm.app/settings-qemu/qemu/#maintenance).

In Windows, open **PowerShell as Administrator** and check:

```powershell
Confirm-SecureBootUEFI
```

The result should be `False`. An access-denied error is not the same as `False`;
run the check in an elevated PowerShell prompt.

### 2. Enable test-signing and reboot Windows

In **PowerShell as Administrator**:

```powershell
bcdedit.exe /set testsigning on
if ($LASTEXITCODE -ne 0) { throw 'Enabling test-signing failed; do not continue.' }
```

Confirm success, then **restart Windows**. In UTM this means the Windows guest,
not macOS. If BCDEdit reports that Secure Boot policy protects the setting,
complete the previous step first.

After restarting, open PowerShell in the repository root and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\diagnose_code_integrity.ps1
```

The read-only helper queries the running system, not just the next-boot setting.
It must report **`TestSigningActive : True`** before proceeding. It also reports
Code Integrity and kernel HVCI flags; it does not change them. Do not disable
additional security features merely to work around an unexplained error.

### 3. Create and trust a development certificate

After the reboot, open **PowerShell as Administrator** in the repository root.
Paste the following commands into the prompt. The examples use the Release
package; use `Debug` consistently if that is the configuration you built.

```powershell
$ErrorActionPreference = 'Stop'
$package = (Resolve-Path '.\build\ARM64\Release\USBPcapDriver\package').Path
$signTool = '.\packages\Microsoft.Windows.SDK.CPP.10.0.28000.2526\c\bin\10.0.28000.0\arm64\signtool.exe'
$inf2cat = '.\packages\Microsoft.Windows.WDK.arm64.10.0.28000.2526\c\bin\10.0.28000.0\x86\Inf2Cat.exe'

$cert = New-SelfSignedCertificate `
    -Type CodeSigningCert `
    -Subject 'CN=USBPcap ARM64 Development' `
    -KeyAlgorithm RSA `
    -KeyLength 2048 `
    -HashAlgorithm SHA256 `
    -CertStoreLocation 'Cert:\LocalMachine\My'

# Export only the public certificate; the private key stays in the local store.
$certFile = Join-Path $env:TEMP 'USBPcap-ARM64-Development.cer'
Export-Certificate -Cert $cert -FilePath $certFile | Out-Null
Import-Certificate -FilePath $certFile -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
Import-Certificate -FilePath $certFile -CertStoreLocation 'Cert:\LocalMachine\TrustedPublisher' | Out-Null
$cert.Thumbprint
```

Save the thumbprint for later signing. Create the certificate once; on subsequent
builds select that certificate from `Cert:\LocalMachine\My` by its thumbprint
instead of creating more certificates with the same subject. Trust this
certificate only on your test machine. If testing on a separate machine, import
its public `.cer` into that machine's LocalMachine Root and TrustedPublisher
stores too; do not transfer the private key merely to install the driver.

Do not use the old repository test PFX or publish/export your new private key.
USBPcapCMD does not need a signature to run these development tests.

### 4. Sign the SYS, regenerate the catalog, then sign the catalog

Continue in the same elevated PowerShell session so the variables above exist:

```powershell
& $signTool sign /v /fd SHA256 /sm /s My /sha1 $cert.Thumbprint "$package\USBPcap.sys"
if ($LASTEXITCODE -ne 0) { throw 'Driver signing failed' }

& $inf2cat "/driver:$package" /os:10_GE_ARM64 /uselocaltime
if ($LASTEXITCODE -ne 0) { throw 'Catalog generation failed' }

& $signTool sign /v /fd SHA256 /sm /s My /sha1 $cert.Thumbprint "$package\USBPcaparm64.cat"
if ($LASTEXITCODE -ne 0) { throw 'Catalog signing failed' }

& $signTool verify /pa /v "$package\USBPcap.sys"
if ($LASTEXITCODE -ne 0) { throw 'Driver signature verification failed' }

& $signTool verify /pa /v /c "$package\USBPcaparm64.cat" "$package\USBPcap.sys"
if ($LASTEXITCODE -ne 0) { throw 'Driver catalog verification failed' }

& $signTool verify /pa /v /c "$package\USBPcaparm64.cat" "$package\USBPcap.inf"
if ($LASTEXITCODE -ne 0) { throw 'INF catalog verification failed' }
```

Order matters: embedding a SYS signature changes its hash, so generate the catalog
**after** signing the SYS. Editing the INF also requires catalog regeneration and
re-signing. These `/pa` checks verify Authenticode trust and catalog membership;
they do **not** prove that Windows kernel policy will allow the driver to load.

A rebuild can replace the signed package. Repeat signing/catalog generation after
rebuilding, using your existing certificate. Do not run a rebuild during an
installation or while diagnosing the signed package.

### 5. Install the signed INF and reboot again

In File Explorer, open:

```text
build\ARM64\Release\USBPcapDriver\package
```

Right-click **USBPcap.inf**, choose **Show more options -> Install** (or Install
on versions displaying it directly), and approve the elevation/publisher prompts.
Use the INF in `package`, alongside its signed SYS and CAT, not an intermediate
or source INX file.

**Restart Windows after successful installation.** You do not need to restart
the Mac. This is a USB class upper filter: a reboot attaches it to the USB device
stacks. Simply staging the package with PnPUtil or starting its service is not a
substitute for that reboot.

### 6. Verify the service and capture interfaces

After restarting, open **PowerShell as Administrator** in the repository root:

```powershell
sc.exe query USBPcap
& '.\build\ARM64\Release\USBPcapCMD\USBPcapCMD.exe' --extcap-interfaces
```

Look for a running service and listed USBPcap interfaces. To use the interactive
capture workflow:

```powershell
& '.\build\ARM64\Release\USBPcapCMD\USBPcapCMD.exe'
```

In UTM, attach the physical USB device to the **Windows VM** through UTM's USB
passthrough controls. A device connected only to macOS is not visible to the
Windows driver. USBPcap observes the guest's USB traffic, not all host USB traffic.
See [UTM USB sharing](https://docs.getutm.app/guest-support/sharing/usb/).

Check the resulting pcap in Wireshark. Development installation and operation
were reported successful in UTM, but comprehensive capture correctness,
reconnect, suspend/resume, HVCI compatibility and uninstall testing remain to be
done. Use Driver Verifier only on a test machine with a recovery plan.

## Troubleshooting installation

### "A certificate chain processed, but terminated in a root certificate which is not trusted by the trust provider"

This error (`0x800B0109`) can appear even when SignTool `/pa` reports a valid
signature and the certificate is already trusted. In the tested UTM setup, the
cause was **Secure Boot still enabled and test-signing inactive**.

1. Run `Confirm-SecureBootUEFI` in elevated PowerShell and the
   `diagnose_code_integrity.ps1` helper above. Expect Secure Boot `False` and
   `TestSigningActive : True`. Setting BCDEdit without rebooting is insufficient.
2. Check the **actual package signer**, not just its subject name:

   ```powershell
   $signature = Get-AuthenticodeSignature '.\build\ARM64\Release\USBPcapDriver\package\USBPcaparm64.cat'
   $signature | Format-List Status,StatusMessage,SignerCertificate
   $thumbprint = $signature.SignerCertificate.Thumbprint
   Get-Item "Cert:\LocalMachine\Root\$thumbprint"
   Get-Item "Cert:\LocalMachine\TrustedPublisher\$thumbprint"
   ```

   Both stores must contain that same thumbprint on the machine performing the
   installation. A different certificate with the same subject is not enough.
3. Verify both SYS and INF catalog membership with the step 4 commands. A stale
   catalog after rebuilding, signing the SYS or editing the INF must be regenerated
   and signed again.
4. Inspect the most recent USBPcap install entry in
   `C:\Windows\INF\setupapi.dev.log`. For a service load failure, also inspect
   Event Viewer -> Applications and Services Logs -> Microsoft -> Windows ->
   CodeIntegrity -> Operational. Do not recreate certificates or disable more
   security settings without identifying the failure.

## Removal and production use

Remove the driver with the appropriate SetupAPI/primitive-driver uninstall
procedure and reboot. The INF retains a `LegacyUninstall=1` section for downlevel
removal. Do not delete the SYS or service while `USBPcap` remains registered in
the USB class `UpperFilters`, and never delete other filters. Remove the test
driver before restoring production boot policy; otherwise its required signature
will no longer be accepted. Retain a recovery plan throughout removal.

Production distribution requires the applicable Microsoft driver signing process
and runtime/compatibility testing. Test-signing is not a replacement for that
process. The old release/signing scripts reference legacy kits and certificates
and should not be used for this ARM64 package.

See Microsoft's [test-signing guidance](https://learn.microsoft.com/windows-hardware/drivers/install/test-signing).
