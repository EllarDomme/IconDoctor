<#
.SYNOPSIS
    Icon fingerprinting: the part that lets the tool know whether it fixed
    anything, without asking the user to eyeball the desktop.

.DESCRIPTION
    A signature is a fixed-size RGB snapshot of an icon plus a few scalar
    features. Two signatures can be compared with a mean-absolute-difference
    score, which is stable across alpha edges and anti-aliasing.

    The "blank icon" heuristic is intentionally conservative: a Windows
    generic shortcut icon is a big near-white page with a small blue arrow,
    so it scores high on white ratio and low on average saturation. A real
    app icon almost never does both at once.
#>

function ConvertTo-IconSignature {
    <#
    .SYNOPSIS
        Downsamples a bitmap into a comparable signature.
    .PARAMETER Size
        Sampling grid. 16 keeps the comparison cheap and blur-tolerant.
    #>
    param(
        [Parameter(Mandatory)][System.Drawing.Bitmap]$Bitmap,
        [int]$Size = 16
    )

    $sample = New-Object System.Drawing.Bitmap $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($sample)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.DrawImage($Bitmap, 0, 0, $Size, $Size)
    $g.Dispose()

    $rgb = New-Object 'int[]' ($Size * $Size * 3)
    $whitePixels = 0
    $opaquePixels = 0
    $saturationSum = 0.0
    $colors = @{}

    for ($y = 0; $y -lt $Size; $y++) {
        for ($x = 0; $x -lt $Size; $x++) {
            $c = $sample.GetPixel($x, $y)
            $i = ($y * $Size + $x) * 3
            $rgb[$i] = $c.R; $rgb[$i + 1] = $c.G; $rgb[$i + 2] = $c.B

            if ($c.A -le 32) { continue }

            $opaquePixels++
            if ($c.R -gt 230 -and $c.G -gt 230 -and $c.B -gt 230) { $whitePixels++ }

            $max = [math]::Max($c.R, [math]::Max($c.G, $c.B))
            $min = [math]::Min($c.R, [math]::Min($c.G, $c.B))
            if ($max -gt 0) { $saturationSum += ($max - $min) / $max }

            # 4 bits per channel is enough to count "distinct look" without
            # being fooled by anti-aliasing gradients.
            $key = (($c.R -shr 4) -shl 8) -bor (($c.G -shr 4) -shl 4) -bor ($c.B -shr 4)
            $colors[$key] = $true
        }
    }
    $sample.Dispose()

    $whiteRatio = 1.0
    $saturation = 0.0
    if ($opaquePixels -gt 0) {
        $whiteRatio = [math]::Round($whitePixels / $opaquePixels, 3)
        $saturation = [math]::Round($saturationSum / $opaquePixels, 3)
    }

    [pscustomobject]@{
        Grid           = $Size
        Rgb            = $rgb
        WhiteRatio     = $whiteRatio
        Saturation     = $saturation
        DistinctColors = $colors.Count
        OpaquePixels   = $opaquePixels
    }
}

function Compare-IconSignature {
    <#
    .SYNOPSIS
        Mean absolute RGB difference between two signatures, as similarity.
    #>
    param(
        [Parameter(Mandatory)]$Reference,
        [Parameter(Mandatory)]$Candidate
    )

    if ($Reference.Grid -ne $Candidate.Grid) {
        throw 'Signatures must share the same grid size.'
    }

    $total = 0.0
    $length = $Reference.Rgb.Length
    for ($i = 0; $i -lt $length; $i++) {
        $total += [math]::Abs($Reference.Rgb[$i] - $Candidate.Rgb[$i])
    }

    $diff = $total / $length
    [pscustomobject]@{
        Difference = [math]::Round($diff, 1)
        Similarity = [math]::Round(1 - ($diff / 255), 3)
    }
}

function Test-BlankIcon {
    <#
    .SYNOPSIS
        Heuristic: does this signature look like the generic white-page icon?
    .DESCRIPTION
        Two conditions must hold, which keeps colourful-but-pale icons
        (e.g. Baidu Netdisk) out of the "blank" bucket.
    #>
    param(
        [Parameter(Mandatory)]$Signature,
        [double]$WhiteThreshold = 0.45,
        [double]$SaturationThreshold = 0.18
    )

    ($Signature.WhiteRatio -ge $WhiteThreshold) -and
    ($Signature.Saturation -le $SaturationThreshold)
}
