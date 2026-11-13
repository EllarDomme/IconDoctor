@{
    RootModule        = 'IconDoctor.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'a3f1c9d2-5b64-4e0a-9c71-2f8d6b1e4a57'
    Author            = 'IconDoctor contributors'
    CompanyName       = 'Community'
    Copyright         = '(c) IconDoctor contributors. MIT licensed.'
    Description       = 'Diagnose and repair blank (white-page) shortcut icons on Windows using layered probes instead of cache-clearing folklore.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport = @(
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
        'Clear-ShellIconNotification'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('windows', 'icons', 'shortcut', 'troubleshooting', 'shell', 'desktop')
            LicenseUri   = 'https://github.com/OWNER/IconDoctor/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/OWNER/IconDoctor'
            ReleaseNotes = 'Initial public preview: layered diagnosis, signature-based verification, safe repair pipeline.'
        }
    }
}
