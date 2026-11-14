<#
.SYNOPSIS
    P/Invoke layer for IconDoctor.

.DESCRIPTION
    All Win32 / Shell32 interop used by the module lives here, behind a
    single type so that `Add-Type` only ever compiles once per session.

    Design notes:
      * We never touch the user's shell state from this file.
      * Every icon handle we obtain is released with DestroyIcon.
#>

if (-not ('IconDoctor.Native' -as [type])) {
    Add-Type -Namespace IconDoctor -Name Native -MemberDefinition @'
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        public struct SHFILEINFO
        {
            public IntPtr hIcon;
            public int iIcon;
            public uint dwAttributes;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string szDisplayName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)]
            public string szTypeName;
        }

        [DllImport("shell32.dll", CharSet = CharSet.Auto)]
        public static extern IntPtr SHGetFileInfo(
            string pszPath, uint dwFileAttributes, ref SHFILEINFO psfi,
            uint cbFileInfo, uint uFlags);

        [DllImport("shell32.dll", CharSet = CharSet.Auto)]
        public static extern uint ExtractIconEx(
            string lpszFile, int nIconIndex,
            IntPtr[] phiconLarge, IntPtr[] phiconSmall, uint nIcons);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool DestroyIcon(IntPtr hIcon);

        [DllImport("shell32.dll")]
        public static extern void SHChangeNotify(int wEventId, uint uFlags,
            IntPtr dwItem1, IntPtr dwItem2);

        // --- Mandatory integrity label (SACL) -------------------------------
        // Windows 11 runs shell extensions such as the .lnk icon handler in a
        // restricted context. If a folder carries a Low integrity label, that
        // handler cannot read it and every shortcut inside renders generic -
        // while the .exe icons still work, because those are read directly.

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern uint GetNamedSecurityInfo(
            string pObjectName, int objectType, uint securityInfo,
            out IntPtr ppsidOwner, out IntPtr ppsidGroup,
            out IntPtr ppDacl, out IntPtr ppSacl, out IntPtr ppSecurityDescriptor);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool ConvertSecurityDescriptorToStringSecurityDescriptor(
            IntPtr pSecurityDescriptor, uint revision, uint securityInfo,
            out IntPtr stringSecurityDescriptor, out uint stringSecurityDescriptorLen);

        [DllImport("kernel32.dll")]
        public static extern IntPtr LocalFree(IntPtr hMem);

        // Returns the SACL part of the SDDL (e.g. "S:(ML;;NW;;;LW)") or null.
        public static string GetLabelSddl(string path)
        {
            IntPtr owner, group, dacl, sacl, sd;
            uint err = GetNamedSecurityInfo(path, 1 /*SE_FILE_OBJECT*/,
                0x10 /*LABEL_SECURITY_INFORMATION*/,
                out owner, out group, out dacl, out sacl, out sd);
            if (err != 0 || sd == IntPtr.Zero) return null;
            try
            {
                IntPtr text; uint len;
                if (!ConvertSecurityDescriptorToStringSecurityDescriptor(sd, 1, 0x10, out text, out len)) return null;
                try { return Marshal.PtrToStringUni(text); }
                finally { LocalFree(text); }
            }
            finally { LocalFree(sd); }
        }
'@
}

# Shell file info flags
$script:SHGFI_ICON       = 0x000000100
$script:SHGFI_LARGEICON  = 0x000000000
$script:SHGFI_SMALLICON  = 0x000000001
$script:SHGFI_SYSICONINDEX = 0x000004000

$script:SHCNE_ASSOCCHANGED = 0x08000000
$script:SHCNF_IDLIST       = 0x0000

function Get-ShellIconBitmap {
    <#
    .SYNOPSIS
        Returns the icon the shell would draw for a path, as a 32x32 bitmap.
    .DESCRIPTION
        This is the same lookup path Explorer uses for the desktop, which is
        exactly what we need to reproduce (and score) a blank icon.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Small
    )

    $flags = $script:SHGFI_ICON
    if ($Small) { $flags = $flags -bor $script:SHGFI_SMALLICON }

    $info = New-Object IconDoctor.Native+SHFILEINFO
    $size = [System.Runtime.InteropServices.Marshal]::SizeOf($info)
    $null = [IconDoctor.Native]::SHGetFileInfo($Path, 0, [ref]$info, [uint32]$size, [uint32]$flags)

    if ($info.hIcon -eq [IntPtr]::Zero) { return $null }

    try {
        $icon = [System.Drawing.Icon]::FromHandle($info.hIcon)
        return $icon.ToBitmap()
    }
    finally {
        $null = [IconDoctor.Native]::DestroyIcon($info.hIcon)
    }
}

function Get-ExeIconBitmap {
    <#
    .SYNOPSIS
        Extracts an icon straight out of an executable / dll / ico resource.
    .DESCRIPTION
        Deliberately bypasses the shell icon cache: this is our ground truth
        for "what the icon should look like". Returns $null when the file
        carries no icon at all.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Index = 0
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    $large = New-Object IntPtr[] 1
    $small = New-Object IntPtr[] 1
    $count = [IconDoctor.Native]::ExtractIconEx($Path, $Index, $large, $small, 1)
    if ($count -eq 0 -or $large[0] -eq [IntPtr]::Zero) { return $null }

    try {
        $icon = [System.Drawing.Icon]::FromHandle($large[0])
        return $icon.ToBitmap()
    }
    finally {
        $null = [IconDoctor.Native]::DestroyIcon($large[0])
        if ($small[0] -ne [IntPtr]::Zero) {
            $null = [IconDoctor.Native]::DestroyIcon($small[0])
        }
    }
}

function Clear-ShellIconNotification {
    <# Tells the shell that icons/associations changed, so it repaints. #>
    [IconDoctor.Native]::SHChangeNotify($script:SHCNE_ASSOCCHANGED, 0, [IntPtr]::Zero, [IntPtr]::Zero)
}
