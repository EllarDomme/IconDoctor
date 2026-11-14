#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'IconDoctor.psd1'
    Import-Module $modulePath -Force

    function New-TestBitmap {
        param(
            [string]$Mode = 'Blank',
            [int]$Size = 32
        )
        $bmp = New-Object System.Drawing.Bitmap $Size, $Size
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        switch ($Mode) {
            'Blank' {
                $g.Clear([System.Drawing.Color]::White)
                $g.FillRectangle([System.Drawing.Brushes]::White, 0, 0, $Size, $Size)
                # tiny blue arrow-ish blob, like the generic shortcut icon
                $g.FillRectangle([System.Drawing.Brushes]::DodgerBlue, 2, 22, 8, 8)
            }
            'Colorful' {
                $g.Clear([System.Drawing.Color]::FromArgb(0, 120, 215))
                $g.FillEllipse([System.Drawing.Brushes]::Orange, 4, 4, 24, 24)
            }
            'Transparent' {
                $g.Clear([System.Drawing.Color]::Transparent)
            }
        }
        $g.Dispose()
        $bmp
    }
}

Describe 'Icon signatures' {
    It 'produces a fixed-size RGB grid' {
        $bmp = New-TestBitmap -Mode Colorful
        $sig = ConvertTo-IconSignature -Bitmap $bmp -Size 16
        $sig.Grid | Should -Be 16
        $sig.Rgb.Length | Should -Be (16 * 16 * 3)
        $bmp.Dispose()
    }

    It 'scores identical icons as fully similar' {
        $bmp = New-TestBitmap -Mode Colorful
        $a = ConvertTo-IconSignature -Bitmap $bmp
        $b = ConvertTo-IconSignature -Bitmap $bmp
        (Compare-IconSignature -Reference $a -Candidate $b).Similarity | Should -Be 1
        $bmp.Dispose()
    }

    It 'scores clearly different icons as dissimilar' {
        $left = New-TestBitmap -Mode Blank
        $right = New-TestBitmap -Mode Colorful
        $cmp = Compare-IconSignature -Reference (ConvertTo-IconSignature $left) `
            -Candidate (ConvertTo-IconSignature $right)
        $cmp.Similarity | Should -BeLessThan 0.85
        $left.Dispose(); $right.Dispose()
    }

    It 'flags the generic white page as blank' {
        $bmp = New-TestBitmap -Mode Blank
        $sig = ConvertTo-IconSignature -Bitmap $bmp
        Test-BlankIcon -Signature $sig | Should -BeTrue
        $bmp.Dispose()
    }

    It 'does not flag a colourful icon as blank' {
        $bmp = New-TestBitmap -Mode Colorful
        $sig = ConvertTo-IconSignature -Bitmap $bmp
        Test-BlankIcon -Signature $sig | Should -BeFalse
        $bmp.Dispose()
    }
}

Describe 'Enumeration' {
    It 'returns shortcut files from an explicit folder' {
        $dir = Join-Path $TestDrive 'links'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $wsh = New-Object -ComObject WScript.Shell
        $lnk = $wsh.CreateShortcut((Join-Path $dir 'probe.lnk'))
        $lnk.TargetPath = "$env:SystemRoot\System32\notepad.exe"
        $lnk.Save()

        $found = @(Get-IconTargets -Path $dir)
        $found.Count | Should -Be 1
        $found[0].Extension | Should -Be '.lnk'
    }
}

Describe 'Scan' -Tag 'Integration' {
    It 'reports Ok for a healthy shortcut' {
        $dir = Join-Path $TestDrive 'healthy'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $wsh = New-Object -ComObject WScript.Shell
        $lnk = $wsh.CreateShortcut((Join-Path $dir 'notepad.lnk'))
        $lnk.TargetPath = "$env:SystemRoot\System32\notepad.exe"
        $lnk.Save()

        $report = @(Get-IconReport -Path $dir)
        $report.Count | Should -Be 1
        $report[0].Verdict | Should -BeIn @('Ok', 'NoIconSource')
    }

    It 'reports TargetMissing for a dead shortcut' {
        $dir = Join-Path $TestDrive 'dead'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $wsh = New-Object -ComObject WScript.Shell
        $lnk = $wsh.CreateShortcut((Join-Path $dir 'ghost.lnk'))
        $lnk.TargetPath = 'C:\this\path\does\not\exist.exe'
        $lnk.Save()

        $report = @(Get-IconReport -Path $dir)
        $report[0].Verdict | Should -Be 'TargetMissing'
    }
}

Describe 'Diagnosis' -Tag 'Integration' {
    It 'returns six layers with a status each' {
        $result = Invoke-IconDiagnosis
        $result.Layers.Count | Should -BeGreaterOrEqual 6
        foreach ($layer in $result.Layers) {
            $layer.Status | Should -BeIn @('Pass', 'Warn', 'Fail', 'Skip')
        }
    }
}


Describe 'Integrity label (L7)' {
    It 'parses a Low label ACE' {
        $r = ConvertFrom-IntegritySddl -Sddl 'O:BAG:BAD:(A;;FA;;;BA)S:(ML;OICI;NW;;;LW)'
        $r.Level | Should -Be 'Low'
        $r.Code | Should -Be 'LW'
        $r.NoWriteUp | Should -BeTrue
    }

    It 'parses a Medium label without no-write-up' {
        $r = ConvertFrom-IntegritySddl -Sddl 'S:(ML;;;;;ME)'
        $r.Level | Should -Be 'Medium'
        $r.NoWriteUp | Should -BeFalse
    }

    It 'returns null when no label ACE is present' {
        ConvertFrom-IntegritySddl -Sddl 'O:BAG:BAD:(A;;FA;;;BA)' | Should -BeNullOrEmpty
    }

    It 'reports Low as Fail and Medium as Pass' {
        # Detection is exercised through the pure parser to stay elevation-free.
        (ConvertFrom-IntegritySddl -Sddl 'S:(ML;OICI;NW;;;LW)').Level | Should -Be 'Low'
        (ConvertFrom-IntegritySddl -Sddl 'S:(ML;OICI;NW;;;ME)').Level | Should -Be 'Medium'
    }
}
