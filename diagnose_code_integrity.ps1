$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class USBPcapCodeIntegrityQuery
{
    [StructLayout(LayoutKind.Sequential)]
    private struct CodeIntegrityInformation
    {
        public UInt32 Length;
        public UInt32 Options;
    }
    [DllImport("ntdll.dll")]
    private static extern Int32 NtQuerySystemInformation(
        Int32 informationClass, ref CodeIntegrityInformation information,
        Int32 informationLength, out Int32 returnLength);
    public static UInt32 GetOptions()
    {
        var info = new CodeIntegrityInformation { Length = 8 };
        Int32 length;
        Int32 status = NtQuerySystemInformation(103, ref info, 8, out length);
        if (status != 0) throw new Exception("NtQuerySystemInformation: 0x" + status.ToString("X8"));
        return info.Options;
    }
}
'@
$options = [USBPcapCodeIntegrityQuery]::GetOptions()
[pscustomobject]@{
    CodeIntegrityOptions = ('0x{0:X8}' -f $options)
    CodeIntegrityEnabled = [bool]($options -band 0x1)
    TestSigningActive = [bool]($options -band 0x2)
    HVCIKernelModeEnabled = [bool]($options -band 0x400)
} | Format-List
