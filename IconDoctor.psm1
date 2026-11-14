<#
.SYNOPSIS
    IconDoctor - diagnose and repair blank / white shortcut icons on Windows.
.DESCRIPTION
    Dot-sources the implementation files. The order matters: Native defines
    the P/Invoke surface, Signature the scoring, Scan the enumeration,
    Diagnose the layer probes, Repair the fixes.
#>

$script:ModuleRoot = $PSScriptRoot

# System.Drawing is required for every icon operation; load it before the
# implementation files parse their [System.Drawing.Bitmap] signatures.
Add-Type -AssemblyName System.Drawing -ErrorAction Stop

. (Join-Path $ModuleRoot 'src\Native.ps1')
. (Join-Path $ModuleRoot 'src\Signature.ps1')
. (Join-Path $ModuleRoot 'src\Scan.ps1')
. (Join-Path $ModuleRoot 'src\Diagnose.ps1')
. (Join-Path $ModuleRoot 'src\Repair.ps1')

Export-ModuleMember -Function @(
    'Get-IconTargets'
    'Get-IconReport'
    'Invoke-IconDiagnosis'
    'Invoke-IconRepair'
    'Get-IconCacheState'
    'ConvertTo-IconSignature'
    'Compare-IconSignature'
    'Test-BlankIcon'
    'Get-ShellIconBitmap'
    'Get-ExeIconBitmap'
    'Set-IconCacheLimit'
    'Reset-IconCache'
    'Update-ShortcutIcon'
    'Reset-FolderObject'
    'Reset-FolderIntegrity'
    'ConvertFrom-IntegritySddl'
    'Get-FolderIntegrityLabel'
    'Test-LayerIntegrityLabel'
    'Clear-ShellIconNotification'
)
