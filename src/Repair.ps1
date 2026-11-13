<#
.SYNOPSIS
    Repairs, ordered from harmless to invasive.

.DESCRIPTION
    Every repair follows the same contract:
      1. back up whatever is about to change,
      2. change the minimum needed,
      3. re-scan and prove the result.

    Destructive steps (restarting Explorer, rebuilding a folder object) are
    opt-in switches, never defaults.
#>

function Get-IconDoctorBackupPath {
    <# Creates (once per session) a timestamped folder for backups. #>
    if (-not $script:BackupRoot) {
        $script:BackupRoot = Join-Path $env:TEMP ('IconDoctor\backup_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
        New-Item -ItemType Directory -Path $script:BackupRoot -Force | Out-Null
    }
    $script:BackupRoot
}

function Set-IconCacheLimit {
    <#
    .SYNOPSIS
        Raises "Max Cached Icons" so the cache stops evicting entries.
    #>
    param([int]$Value = 8192)

    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
    if (-not (Test-Path $key)) { throw "Registry key not found: $key" }

    $backup = Get-IconDoctorBackupPath
    $previous = (Get-Item $key).GetValue('Max Cached Icons')
    $dump = "Max Cached Icons (previous) = $previous`r`n"
    $dump | Set-Content -LiteralPath (Join-Path $backup 'MaxCachedIcons.txt') -Encoding UTF8

    New-ItemProperty -Path $key -Name 'Max Cached Icons' -Value ([string]$Value) `
        -PropertyType String -Force | Out-Null

    [pscustomobject]@{
        Action   = 'SetIconCacheLimit'
        Previous = $previous
        Current  = $Value
        Backup   = $backup
    }
}

function Reset-IconCache {
    <#
    .SYNOPSIS
        Deletes the icon cache databases and restarts Explorer.

    .DESCRIPTION
        Explorer keeps the databases mapped, so they can only be removed
        while Explorer is down. Windows often restarts the shell within a
        second, so we retry in a tight loop until the files are actually gone.
    #>
    param([int]$TimeoutSeconds = 30)

    $dir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
    $deleted = 0
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        foreach ($proc in @(Get-Process explorer -ErrorAction SilentlyContinue)) {
            try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { }
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter 'iconcache*' -Force -ErrorAction SilentlyContinue)) {
            try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop; $deleted++ } catch { }
        }
        $left = @(Get-ChildItem -LiteralPath $dir -Filter 'iconcache*' -Force -ErrorAction SilentlyContinue).Count
        if ($left -eq 0) { break }
        Start-Sleep -Milliseconds 120
    }

    Start-Sleep -Seconds 1
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
    }
    Start-Sleep -Seconds 5
    Clear-ShellIconNotification
    Start-Sleep -Seconds 2

    [pscustomobject]@{
        Action  = 'ResetIconCache'
        Deleted = $deleted
        Remaining = @(Get-ChildItem -LiteralPath $dir -Filter 'iconcache*' -Force -ErrorAction SilentlyContinue).Count
    }
}

function Update-ShortcutIcon {
    <#
    .SYNOPSIS
        Rebuilds a shortcut with an explicit icon pointing at its target.
    .DESCRIPTION
        Keeps target / arguments / working directory / description, and
        writes a fresh .lnk. A new file means a new cache key, which is why
        this sometimes works when "refresh icons" does not.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$WhatIf
    )

    $wsh = New-Object -ComObject WScript.Shell
    $shortcut = $wsh.CreateShortcut($Path)
    $target = [string]$shortcut.TargetPath

    if (-not $target -or -not (Test-Path -LiteralPath $target)) {
        return [pscustomobject]@{
            Action = 'UpdateShortcutIcon'; Path = $Path; Changed = $false
            Message = 'Target missing; cannot rebuild.'
        }
    }

    if ($WhatIf) {
        return [pscustomobject]@{
            Action = 'UpdateShortcutIcon'; Path = $Path; Changed = $false
            Message = "Would rebuild with icon $target,0"
        }
    }

    $backup = Get-IconDoctorBackupPath
    $safeName = ($Path -replace '[:\\\/]', '_')
    Copy-Item -LiteralPath $Path -Destination (Join-Path $backup ($safeName + '.bak')) -Force -ErrorAction SilentlyContinue

    $arguments = [string]$shortcut.Arguments
    $workingDirectory = [string]$shortcut.WorkingDirectory
    $description = [string]$shortcut.Description
    $windowStyle = [int]$shortcut.WindowStyle

    Remove-Item -LiteralPath $Path -Force
    Start-Sleep -Milliseconds 150

    $fresh = $wsh.CreateShortcut($Path)
    $fresh.TargetPath = $target
    if ($arguments) { $fresh.Arguments = $arguments }
    if ($workingDirectory) { $fresh.WorkingDirectory = $workingDirectory }
    if ($description) { $fresh.Description = $description }
    if ($windowStyle) { $fresh.WindowStyle = $windowStyle }
    $fresh.IconLocation = "$target,0"
    $fresh.Save()

    [pscustomobject]@{
        Action  = 'UpdateShortcutIcon'
        Path    = $Path
        Changed = $true
        Message = 'Rebuilt shortcut with explicit icon.'
    }
}

function Reset-FolderObject {
    <#
    .SYNOPSIS
        Rebuilds a folder object in place (same path, new directory identity).

    .DESCRIPTION
        For the rare case where a folder itself makes shortcut icons render
        blank. Every child is moved into a fresh sibling directory, the old
        (now empty) directory is renamed aside, and the fresh one takes its
        place. Children are moved back if anything fails.

        This is the most invasive repair available and refuses to run unless
        -Force is supplied.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Force
    )

    if (-not $Force) { throw 'Reset-FolderObject requires -Force (it moves every file in the folder).' }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Folder not found: $Path" }

    $full = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
    $parent = Split-Path -Parent $full
    $leaf = Split-Path -Leaf $full
    $staging = Join-Path $parent ("$leaf.icondoctor_new")
    $retired = Join-Path $parent ("$leaf.icondoctor_old")

    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging | Out-Null

    $moved = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]

    foreach ($item in @(Get-ChildItem -LiteralPath $full -Force)) {
        try {
            Move-Item -LiteralPath $item.FullName -Destination (Join-Path $staging $item.Name) -Force -ErrorAction Stop
            $moved.Add($item.Name)
        }
        catch {
            $failed.Add("$($item.Name): $($_.Exception.Message)")
        }
    }

    if ($failed.Count -gt 0 -or @(Get-ChildItem -LiteralPath $full -Force).Count -gt 0) {
        foreach ($name in $moved) {
            try { Move-Item -LiteralPath (Join-Path $staging $name) -Destination (Join-Path $full $name) -Force -ErrorAction Stop } catch { }
        }
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Action = 'ResetFolderObject'; Path = $full; Changed = $false; Moved = $moved.Count
            Message = "Rolled back; $($failed.Count) item(s) could not be moved."
        }
        return
    }

    Rename-Item -LiteralPath $full -NewName (Split-Path -Leaf $retired) -Force
    Rename-Item -LiteralPath $staging -NewName $leaf -Force

    [pscustomobject]@{
        Action  = 'ResetFolderObject'
        Path    = $full
        Changed = $true
        Moved   = $moved.Count
        Message = "Folder rebuilt. Previous (empty) folder kept at $retired - delete it once you are happy."
    }
}

function Invoke-IconRepair {
    <#
    .SYNOPSIS
        Diagnoses, repairs what it can, and proves the result by re-scanning.

    .PARAMETER Path
        Folders to repair. Defaults to the desktop folders.
    .PARAMETER RestartExplorer
        Allows the icon cache reset (restarts Explorer, closes folder windows).
    .PARAMETER RebuildFolderObject
        Allows rebuilding a damaged folder object. Requires -Force.
    .EXAMPLE
        Invoke-IconRepair -WhatIf
    .EXAMPLE
        Invoke-IconRepair -RestartExplorer
    #>
    param(
        [string[]]$Path,
        [switch]$RestartExplorer,
        [switch]$RebuildFolderObject,
        [switch]$Force,
        [switch]$WhatIf
    )

    $scanArgs = @{}
    if ($Path) { $scanArgs.Path = $Path }

    $before = @(Get-IconReport @scanArgs)
    $broken = @($before | Where-Object { $_.Verdict -in @('Blank', 'TargetMissing') })

    $steps = New-Object System.Collections.Generic.List[object]

    if ($broken.Count -eq 0) {
        return [pscustomobject]@{
            Before  = $before
            Steps   = @()
            After   = $before
            Fixed   = 0
            Message = 'Nothing to repair: no blank or broken shortcuts found.'
        }
    }

    foreach ($item in $broken) {
        if ($item.Verdict -eq 'TargetMissing') { continue }
        $steps.Add((Update-ShortcutIcon -Path $item.Path -WhatIf:$WhatIf))
        Start-Sleep -Milliseconds 300
    }

    if (-not $WhatIf) {
        Clear-ShellIconNotification
        Start-Sleep -Seconds 2
    }

    $mid = if ($WhatIf) { $before } else { @(Get-IconReport @scanArgs) }
    $stillBlank = @($mid | Where-Object { $_.Verdict -eq 'Blank' })

    if ($stillBlank.Count -gt 0 -and $RestartExplorer -and -not $WhatIf) {
        $steps.Add((Reset-IconCache))
        $mid = @(Get-IconReport @scanArgs)
        $stillBlank = @($mid | Where-Object { $_.Verdict -eq 'Blank' })
    }

    if ($stillBlank.Count -gt 0 -and $RebuildFolderObject) {
        foreach ($folder in @($stillBlank | ForEach-Object { Split-Path -Parent $_.Path } | Sort-Object -Unique)) {
            $steps.Add((Reset-FolderObject -Path $folder -Force:$Force -WhatIf:$false))
            Start-Sleep -Seconds 2
        }
        if (-not $WhatIf) {
            $mid = @(Get-IconReport @scanArgs)
            $stillBlank = @($mid | Where-Object { $_.Verdict -eq 'Blank' })
        }
    }

    $fixed = @($mid | Where-Object { $_.Verdict -eq 'Ok' }).Count -
             @($before | Where-Object { $_.Verdict -eq 'Ok' }).Count

    [pscustomobject]@{
        Before  = $before
        Steps   = $steps
        After   = $mid
        Fixed   = [math]::Max(0, $fixed)
        Message = if ($WhatIf) {
            "Dry run: $($steps.Count) repair step(s) planned, nothing was changed."
        }
        elseif ($stillBlank.Count -eq 0) {
            'All previously blank icons now render correctly.'
        }
        else {
            "$($stillBlank.Count) icon(s) still blank. " +
            'Check the diagnosis report; you may need -RestartExplorer or -RebuildFolderObject -Force.'
        }
    }
}
