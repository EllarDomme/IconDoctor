<#
.SYNOPSIS
    Enumeration + scoring of shortcut icons.
#>

function Get-IconTargets {
    <#
    .SYNOPSIS
        Lists the .lnk files worth inspecting.
    .DESCRIPTION
        Defaults to the two desktop folders (per-user and all-users), because
        that is where the "white icon" complaint almost always happens.
    .EXAMPLE
        Get-IconTargets -IncludeStartMenu
    #>
    param(
        [string[]]$Path,
        [switch]$IncludeStartMenu,
        [switch]$Recurse
    )

    if (-not $Path) {
        $Path = @(
            [Environment]::GetFolderPath('Desktop')
            [Environment]::GetFolderPath('CommonDesktopDirectory')
        )
        if ($IncludeStartMenu) {
            $Path += [Environment]::GetFolderPath('Programs')
        }
    }

    $seen = @{}
    foreach ($dir in $Path) {
        if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { continue }
        $files = Get-ChildItem -LiteralPath $dir -Filter '*.lnk' -Force -Recurse:$Recurse -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            if ($seen.ContainsKey($file.FullName)) { continue }
            $seen[$file.FullName] = $true
            $file
        }
    }
}

function Get-IconReport {
    <#
    .SYNOPSIS
        Scores every shortcut icon: Ok / Blank / TargetMissing / NoIconSource.
    .DESCRIPTION
        For each shortcut we build two signatures:
          * the shell's icon (what Explorer draws, cache included)
          * the target executable's icon (ground truth, cache bypassed)
        and compare them. A shortcut is reported Blank when the shell output
        looks like the generic white page and does not resemble the target.
    .PARAMETER Path
        Folders to scan. Defaults to the desktop folders.
    .EXAMPLE
        Get-IconReport | Format-Table Name, Verdict, Similarity
    #>
    param(
        [string[]]$Path,
        [switch]$IncludeStartMenu,
        [switch]$Recurse,
        [switch]$Detailed
    )

    $wsh = New-Object -ComObject WScript.Shell
    $targets = Get-IconTargets -Path $Path -IncludeStartMenu:$IncludeStartMenu -Recurse:$Recurse

    foreach ($file in $targets) {
        $row = [pscustomobject]@{
            Name       = $file.BaseName
            Path       = $file.FullName
            Target     = $null
            Verdict    = 'Skipped'
            Similarity = $null
            WhiteRatio = $null
            Saturation = $null
            Message    = $null
        }

        try {
            $shortcut = $wsh.CreateShortcut($file.FullName)
            $target = [string]$shortcut.TargetPath
            $row.Target = $target

            if ([string]::IsNullOrWhiteSpace($target)) {
                $row.Verdict = 'TargetMissing'
                $row.Message = 'Shortcut has no readable target (link data damaged).'
                $row
                continue
            }
            if (-not (Test-Path -LiteralPath $target)) {
                $row.Verdict = 'TargetMissing'
                $row.Message = "Target not found: $target"
                $row
                continue
            }

            $reference = Get-ExeIconBitmap -Path $target
            if (-not $reference) {
                $row.Verdict = 'NoIconSource'
                $row.Message = 'Target carries no icon resource; nothing to compare against.'
                $row
                continue
            }

            $actual = Get-ShellIconBitmap -Path $file.FullName
            if (-not $actual) {
                $row.Verdict = 'Blank'
                $row.Message = 'Shell returned no icon at all.'
                $row
                continue
            }

            $refSig = ConvertTo-IconSignature -Bitmap $reference
            $actSig = ConvertTo-IconSignature -Bitmap $actual
            $cmp = Compare-IconSignature -Reference $refSig -Candidate $actSig

            $row.Similarity = $cmp.Similarity
            $row.WhiteRatio = $actSig.WhiteRatio
            $row.Saturation = $actSig.Saturation

            # Similarity is the primary signal: if the shell icon already
            # matches the target's own icon resource, it is correct no matter
            # how pale it looks. Pure-white app icons (Baidu Netdisk, WeChat,
            # Leica-style brands) score 0.93-0.98 here, so a white-ratio test
            # alone would produce false positives.
            if ($cmp.Similarity -ge 0.80) {
                $row.Verdict = 'Ok'
            }
            elseif (Test-BlankIcon -Signature $actSig) {
                $row.Verdict = 'Blank'
                $row.Message = 'Shell icon looks like the generic white page.'
            }
            else {
                # Not blank, just different (custom icon, themed icon, ...).
                $row.Verdict = 'Ok'
                $row.Message = 'Icon differs from target resource (custom icon?).'
            }
        }
        catch {
            $row.Verdict = 'Skipped'
            $row.Message = $_.Exception.Message
        }

        if ($Detailed) {
            $row | Add-Member -NotePropertyName ScannedAt -NotePropertyValue (Get-Date) -PassThru
        }
        else {
            $row
        }
    }
}
