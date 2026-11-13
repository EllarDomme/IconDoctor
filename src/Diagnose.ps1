<#
.SYNOPSIS
    The six-layer diagnosis. Each layer answers exactly one question and can
    be decided by evidence, so the tool never "guesses" a cause.
#>

$script:LayerNames = [ordered]@{
    L1 = 'Icon source'
    L2 = 'Shortcut content'
    L3 = 'Icon cache'
    L4 = 'Shell handler'
    L5 = 'Folder object'
    L6 = 'Folder ACL'
}

function New-LayerResult {
    param(
        [string]$Id,
        [string]$Status,
        [string]$Detail,
        $Evidence
    )
    [pscustomobject]@{
        Layer    = $Id
        Name     = $script:LayerNames[$Id]
        Status   = $Status
        Detail   = $Detail
        Evidence = $Evidence
    }
}

function Test-LayerIconSource {
    param($Report)
    $withTarget = @($Report | Where-Object { $_.Verdict -ne 'Skipped' })
    $noIcon = @($withTarget | Where-Object { $_.Verdict -eq 'NoIconSource' })
    # Only count shortcuts whose link data resolves; empty targets are a
    # layer-2 problem, not a layer-1 one.
    $missing = @($withTarget | Where-Object {
            $_.Verdict -eq 'TargetMissing' -and -not [string]::IsNullOrWhiteSpace($_.Target)
        })

    if ($withTarget.Count -eq 0) {
        return New-LayerResult 'L1' 'Skip' 'No shortcuts with a readable target were found.' $null
    }
    if ($noIcon.Count -gt 0) {
        return New-LayerResult 'L1' 'Warn' `
            "$($noIcon.Count) target(s) carry no icon resource - those cannot be fixed by any cache trick." `
            ($noIcon | Select-Object Name, Target)
    }
    if ($missing.Count -gt 0) {
        return New-LayerResult 'L1' 'Warn' `
            "$($missing.Count) shortcut(s) point at a missing file - uninstall leftovers." `
            ($missing | Select-Object Name, Target)
    }
    return New-LayerResult 'L1' 'Pass' 'Every target exists and carries an icon resource.' $null
}

function Test-LayerShortcutContent {
    param($Report)
    $broken = @($Report | Where-Object { $_.Verdict -eq 'TargetMissing' -and [string]::IsNullOrWhiteSpace($_.Target) })
    if ($broken.Count -gt 0) {
        return New-LayerResult 'L2' 'Warn' `
            "$($broken.Count) shortcut(s) have damaged link data (no target resolvable)." `
            ($broken | Select-Object Name, Path)
    }
    return New-LayerResult 'L2' 'Pass' 'All shortcuts resolve to a target path.' $null
}

function Get-IconCacheState {
    <# Returns the icon cache database files plus the configured limit. #>
    $dir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
    $files = @()
    if (Test-Path -LiteralPath $dir) {
        $files = @(Get-ChildItem -LiteralPath $dir -Filter 'iconcache*.db' -Force -ErrorAction SilentlyContinue |
            Sort-Object Length -Descending |
            Select-Object Name, Length, LastWriteTime)
    }

    $limit = $null
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
    if (Test-Path $key) {
        $limit = (Get-Item $key).GetValue('Max Cached Icons')
    }

    [pscustomobject]@{
        Directory = $dir
        Files     = $files
        Count     = $files.Count
        Bytes     = ($files | Measure-Object -Property Length -Sum).Sum
        MaxCachedIcons = $limit
    }
}

function Test-LayerIconCache {
    $state = Get-IconCacheState
    if ($state.Count -eq 0) {
        return New-LayerResult 'L3' 'Warn' 'No icon cache database found - it is rebuilt on next Explorer start.' $state
    }

    # The 32px + 48px databases are the ones the desktop uses. Sitting at a
    # round power-of-two size is the classic "cache is full" fingerprint.
    $atCap = @($state.Files | Where-Object {
            ($_.Name -match 'iconcache_(32|48)\.db$') -and
            ($_.Length -band ($_.Length - 1)) -eq 0 -and $_.Length -ge 1MB
        })

    $detail = "$($state.Count) cache databases, " + [math]::Round($state.Bytes / 1MB, 1) + ' MB total.'
    if ($null -eq $state.MaxCachedIcons) { $detail += ' Max Cached Icons is not set (default is small).' }
    else { $detail += " Max Cached Icons = $($state.MaxCachedIcons)." }

    if ($atCap.Count -gt 0 -and $null -eq $state.MaxCachedIcons) {
        return New-LayerResult 'L3' 'Warn' ($detail + ' Cache may be saturated.') $state
    }
    return New-LayerResult 'L3' 'Pass' $detail $state
}

function Test-LayerShellHandler {
    <# Is the .lnk icon handler (ShellLink -> windows.storage.dll) wired up? #>
    $handler = $null
    $dll = $null
    try {
        $handler = (Get-ItemProperty 'Registry::HKEY_CLASSES_ROOT\lnkfile\shellex\IconHandler' -ErrorAction Stop).'(default)'
    }
    catch { }

    if (-not $handler) {
        return New-LayerResult 'L4' 'Fail' 'HKEY_CLASSES_ROOT\lnkfile\shellex\IconHandler is missing.' $null
    }

    try {
        $dll = (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\CLSID\$handler\InProcServer32" -ErrorAction Stop).'(default)'
    }
    catch { }

    if (-not $dll) {
        return New-LayerResult 'L4' 'Fail' "IconHandler points at $handler but its InProcServer32 is not registered." $handler
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($dll)
    if (-not (Test-Path -LiteralPath $expanded)) {
        return New-LayerResult 'L4' 'Fail' "IconHandler DLL is missing: $expanded" $dll
    }

    return New-LayerResult 'L4' 'Pass' "IconHandler -> $handler -> $dll (present)." $handler
}

function Test-LayerFolderObject {
    <#
    .SYNOPSIS
        Probes whether a folder poisons shortcut icon resolution.

    .DESCRIPTION
        Creates a throw-away shortcut to a known-good executable inside the
        target folder, reads the icon the shell computes for it, and repeats
        the same thing in %TEMP%. If the folder copy comes back blank while
        the temp copy is fine, the folder object itself is the problem -
        that is the case no cache-clearing tutorial can fix.
    #>
    param(
        [Parameter(Mandatory)][string]$Folder,
        [string]$ControlExecutable = "$env:SystemRoot\System32\notepad.exe"
    )

    if (-not (Test-Path -LiteralPath $Folder)) {
        return New-LayerResult 'L5' 'Skip' "Folder not found: $Folder" $null
    }
    if (-not (Test-Path -LiteralPath $ControlExecutable)) {
        return New-LayerResult 'L5' 'Skip' 'Control executable not available.' $null
    }

    $reference = Get-ExeIconBitmap -Path $ControlExecutable
    if (-not $reference) {
        return New-LayerResult 'L5' 'Skip' 'Control executable carries no icon.' $null
    }
    $refSig = ConvertTo-IconSignature -Bitmap $reference

    $wsh = New-Object -ComObject WScript.Shell
    $probeName = 'icondoctor_probe_{0}.lnk' -f ([guid]::NewGuid().ToString('N').Substring(0, 8))

    $probeFolder = Join-Path $Folder $probeName
    $probeTemp = Join-Path $env:TEMP $probeName
    $result = [pscustomobject]@{
        FolderSimilarity = $null
        FolderBlank      = $null
        TempSimilarity   = $null
        TempBlank        = $null
    }

    try {
        foreach ($pair in @(@{ Path = $probeFolder; Slot = 'Folder' }, @{ Path = $probeTemp; Slot = 'Temp' })) {
            $shortcut = $wsh.CreateShortcut($pair.Path)
            $shortcut.TargetPath = $ControlExecutable
            $shortcut.Save()
            Start-Sleep -Milliseconds 400

            $actual = Get-ShellIconBitmap -Path $pair.Path
            if (-not $actual) {
                $result."$($pair.Slot)Blank" = $true
                continue
            }
            $sig = ConvertTo-IconSignature -Bitmap $actual
            $cmp = Compare-IconSignature -Reference $refSig -Candidate $sig
            $result."$($pair.Slot)Similarity" = $cmp.Similarity
            $result."$($pair.Slot)Blank" = (Test-BlankIcon -Signature $sig)
        }
    }
    finally {
        foreach ($leftover in @($probeFolder, $probeTemp)) {
            if (Test-Path -LiteralPath $leftover) {
                Remove-Item -LiteralPath $leftover -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $suspect = ($result.FolderBlank -eq $true) -and ($result.TempBlank -eq $false)

    if ($suspect) {
        return New-LayerResult 'L5' 'Fail' `
            'A brand-new shortcut inside this folder renders blank, while the same shortcut in %TEMP% does not. The folder object is damaged.' `
            $result
    }
    if ($result.FolderBlank -eq $true -and $result.TempBlank -eq $true) {
        return New-LayerResult 'L5' 'Warn' `
            'Shortcut icons render blank everywhere, not only in this folder - look at layers 3/4 instead.' `
            $result
    }
    if ($null -eq $result.FolderBlank) {
        return New-LayerResult 'L5' 'Skip' 'Probe could not create a shortcut in this folder (permissions?).' $result
    }
    return New-LayerResult 'L5' 'Pass' 'New shortcuts in this folder get a correct icon.' $result
}

function Test-LayerFolderAcl {
    param([Parameter(Mandatory)][string]$Folder)
    if (-not (Test-Path -LiteralPath $Folder)) {
        return New-LayerResult 'L6' 'Skip' "Folder not found: $Folder" $null
    }

    try { $acl = Get-Acl -LiteralPath $Folder -ErrorAction Stop }
    catch { return New-LayerResult 'L6' 'Skip' ('Cannot read ACL: ' + $_.Exception.Message) $null }

    $deny = @($acl.Access | Where-Object { $_.AccessControlType -eq 'Deny' })
    $orphans = @($acl.Access | Where-Object { $_.IdentityReference.Value -like 'S-1-4-*' })

    if ($deny.Count -gt 0 -or $orphans.Count -gt 0) {
        $detail = @()
        if ($deny.Count -gt 0) { $detail += "$($deny.Count) deny rule(s)" }
        if ($orphans.Count -gt 0) { $detail += "$($orphans.Count) orphan SID(s) (S-1-4-*)" }
        return New-LayerResult 'L6' 'Warn' ('Unusual ACL on the folder: ' + ($detail -join ', ') + '.') `
            ($acl.Access | Select-Object IdentityReference, FileSystemRights, AccessControlType, IsInherited)
    }

    return New-LayerResult 'L6' 'Pass' 'Folder ACL looks normal.' $acl.Owner
}

function Invoke-IconDiagnosis {
    <#
    .SYNOPSIS
        Runs all six probes and returns a layered report.
    .DESCRIPTION
        Layers are ordered from cheapest/least invasive to deepest. The first
        layer that reports Fail or Warn is the one worth acting on; deeper
        layers still run so the report can be pasted into an issue.
    .PARAMETER Path
        Folders to diagnose. Defaults to the desktop folders.
    .EXAMPLE
        Invoke-IconDiagnosis | Format-Table Layer, Name, Status, Detail
    #>
    param(
        [string[]]$Path,
        [switch]$IncludeStartMenu
    )

    $scanArgs = @{ IncludeStartMenu = $IncludeStartMenu }
    if ($Path) { $scanArgs.Path = $Path }
    $report = @(Get-IconReport @scanArgs)

    $layers = @(
        (Test-LayerIconSource -Report $report)
        (Test-LayerShortcutContent -Report $report)
        (Test-LayerIconCache)
        (Test-LayerShellHandler)
    )

    # The folder probe only makes sense for the folder that actually holds
    # broken icons; probing every folder would create a lot of temp files.
    $suspectFolders = @($report | Where-Object { $_.Verdict -eq 'Blank' } |
        ForEach-Object { Split-Path -Parent $_.Path } | Sort-Object -Unique)

    if ($suspectFolders.Count -eq 0) {
        $layers += New-LayerResult 'L5' 'Skip' 'No blank icons found, folder probe not needed.' $null
    }
    else {
        foreach ($folder in $suspectFolders) {
            $layers += Test-LayerFolderObject -Folder $folder
        }
    }

    foreach ($folder in @([Environment]::GetFolderPath('Desktop'))) {
        $layers += Test-LayerFolderAcl -Folder $folder
    }

    $blank = @($report | Where-Object { $_.Verdict -eq 'Blank' })
    $failing = @($layers | Where-Object { $_.Status -in @('Fail', 'Warn') })

    [pscustomobject]@{
        ScannedAt   = Get-Date
        Shortcuts   = $report.Count
        BlankIcons  = $blank.Count
        Layers      = $layers
        RootCause   = ($failing | Select-Object -First 1)
        Items       = $report
    }
}
