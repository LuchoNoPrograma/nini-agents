Set-StrictMode -Version Latest

# Per-profile secrets in Windows Credential Manager via raw Win32 Cred*
# P/Invoke (no external module dependency). Target naming:
# multi-cli/<tool>/<profileId>/<envVar>. PowerShell mirror of the windows
# backend in lib/credential-store.sh -- same targets, same semantics.

if (-not ('MultiCli.NativeCredentialStore' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace MultiCli {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct NativeCredential {
        public UInt32 Flags;
        public UInt32 Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public UInt32 CredentialBlobSize;
        public IntPtr CredentialBlob;
        public UInt32 Persist;
        public UInt32 AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    public static class NativeCredentialStore {
        public const UInt32 Generic = 1;
        public const UInt32 LocalMachine = 2;
        public const int NotFound = 1168;

        [DllImport("Advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool Write([In] ref NativeCredential credential, UInt32 flags);

        [DllImport("Advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool Read(string target, UInt32 type, UInt32 flags, out IntPtr credentialPointer);

        [DllImport("Advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool Delete(string target, UInt32 type, UInt32 flags);

        [DllImport("Advapi32.dll", EntryPoint = "CredFree", SetLastError = true)]
        public static extern void Free(IntPtr buffer);
    }
}
'@
}

function Assert-MultiCliCredentialTarget {
    param([string]$Target)
    if ([string]::IsNullOrEmpty($Target)) { throw 'Credential target is required.' }
    # CRED_MAX_GENERIC_TARGET_NAME_LENGTH is 32767; longer targets fail
    # P/Invoke with an opaque Win32 error that instrumentation can clear.
    if ($Target.Length -gt 32767) { throw 'Credential target exceeds the Windows Credential Manager name limit.' }
}

# Write (create or overwrite) a generic credential. The secret buffer is
# zeroed on every exit path; throws on empty input or Win32 failure.
function Set-MultiCliCredential {
    param([string]$Target, [string]$Secret)
    Assert-MultiCliCredentialTarget -Target $Target
    if ([string]::IsNullOrEmpty($Secret)) { throw 'Credential secret must not be empty.' }
    $bytes = [Text.Encoding]::UTF8.GetBytes($Secret)
    if ($bytes.Length -gt 2560) { throw 'Credential secret exceeds the Windows Credential Manager limit.' }
    $pointer = [Runtime.InteropServices.Marshal]::AllocCoTaskMem($bytes.Length)
    try {
        [Runtime.InteropServices.Marshal]::Copy($bytes, 0, $pointer, $bytes.Length)
        $credential = New-Object MultiCli.NativeCredential
        $credential.Type = [MultiCli.NativeCredentialStore]::Generic
        $credential.TargetName = $Target
        $credential.CredentialBlobSize = $bytes.Length
        $credential.CredentialBlob = $pointer
        $credential.Persist = [MultiCli.NativeCredentialStore]::LocalMachine
        $credential.UserName = 'multi-cli'
        if (-not [MultiCli.NativeCredentialStore]::Write([ref]$credential, 0)) {
            throw "Credential Manager write failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
        }
    } finally {
        for ($index = 0; $index -lt $bytes.Length; $index++) { $bytes[$index] = 0 }
        if ($pointer -ne [IntPtr]::Zero) {
            $blobSize = $bytes.Length
            for ($index = 0; $index -lt $blobSize; $index++) {
                [Runtime.InteropServices.Marshal]::WriteByte($pointer, $index, 0)
            }
            [Runtime.InteropServices.Marshal]::FreeCoTaskMem($pointer)
        }
    }
}

# Read a credential as UTF-8 text; $null when absent. The native handle is
# freed and the byte copy zeroed on every exit path.
function Get-MultiCliCredential {
    param([string]$Target)
    Assert-MultiCliCredentialTarget -Target $Target
    $pointer = [IntPtr]::Zero
    # CredRead delivers results only through the pointer, which stays zero on
    # failure (nothing to free). For validated targets the only real failure
    # is not-found, so every failed read is "absent".
    if (-not [MultiCli.NativeCredentialStore]::Read($Target, [MultiCli.NativeCredentialStore]::Generic, 0, [ref]$pointer)) {
        return $null
    }
    try {
        $credential = [Runtime.InteropServices.Marshal]::PtrToStructure($pointer, [type][MultiCli.NativeCredential])
        if ($credential.CredentialBlobSize -eq 0) { return '' }
        $bytes = New-Object byte[] $credential.CredentialBlobSize
        [Runtime.InteropServices.Marshal]::Copy($credential.CredentialBlob, $bytes, 0, $bytes.Length)
        try {
            return [Text.Encoding]::UTF8.GetString($bytes)
        } finally {
            for ($index = 0; $index -lt $bytes.Length; $index++) { $bytes[$index] = 0 }
        }
    } finally {
        if ($pointer -ne [IntPtr]::Zero) { [MultiCli.NativeCredentialStore]::Free($pointer) }
    }
}

# Delete a credential; returns $false when it was already gone. Idempotent.
function Remove-MultiCliCredential {
    param([string]$Target)
    Assert-MultiCliCredentialTarget -Target $Target
    # Check existence first: CredDelete's Win32 error can be cleared by
    # instrumented runtimes, making not-found indistinguishable otherwise.
    if ($null -eq (Get-MultiCliCredential -Target $Target)) { return $false }
    # With existence confirmed, a failed delete can only have lost a race with
    # another deleter, in which case the credential is gone: report false.
    return [MultiCli.NativeCredentialStore]::Delete($Target, [MultiCli.NativeCredentialStore]::Generic, 0)
}

# True when a credential exists at the target.
function Test-MultiCliCredential {
    param([string]$Target)
    return $null -ne (Get-MultiCliCredential -Target $Target)
}

Export-ModuleMember -Function Set-MultiCliCredential, Get-MultiCliCredential, Remove-MultiCliCredential, Test-MultiCliCredential
