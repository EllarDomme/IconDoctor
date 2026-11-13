#Requires -Version 5.1
<#
.SYNOPSIS
    IconDoctor command line entry point.

.DESCRIPTION
    Three verbs, no surprises:
        -Scan       read-only, prints a table of every shortcut icon
        -Diagnose   read-only, six layer probes + a root-cause guess
        -Fix        repairs what it safely can, then proves it by re-scanning

.EXAMPLE
    .\IconDoctor.ps1 -Scan

.EXAMPLE
    .\IconDoctor.ps1 -Diagnose -Path "$env:USERPROFILE\Desktop"

.EXAMPLE
    .\IconDoctor.ps1 -Fix -RestartExplorer
#>
[CmdletBinding(DefaultParameterSetName = 'Scan')]
param(
    [Parameter(ParameterSetName = 'Scan')]
    [switch]$Scan,

    [Parameter(ParameterSetName = 'Diagnose')]
    [switch]$Diagnose,

    [Parameter(ParameterSetName = 'Fix')]
    [switch]$Fix,

    [string[]]$Path,
    [switch]$IncludeStartMenu,
    [switch]$Recurse,
    [switch]$Json,

    [Parameter(ParameterSetName = 'Fix')]
    [switch]$RestartExplorer,

    [Parameter(ParameterSetName = 'Fix')]
    [switch]$RebuildFolderObject,

    [Parameter(ParameterSetName = 'Fix')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'Fix')]
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'IconDoctor.psd1') -Force

$common = @{}
if ($Path) { $common.Path = $Path }
if ($IncludeStartMenu) { $common.IncludeStartMenu = $true }
if ($Recurse) { $common.Recurse = $true }

function Write-Section([string]$Text) {
    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('-' * $Text.Length) -ForegroundColor DarkCyan
}

function Get-StepText($Step) {
    if ($Step.PSObject.Properties.Name -contains 'Message' -and $Step.Message) { return $Step.Message }
    if ($Step.PSObject.Properties.Name -contains 'Path' -and $Step.Path) { return $Step.Path }
    return ''
}

switch ($PSCmdlet.ParameterSetName) {
    'Scan' {
        $report = @(Get-IconReport @common)
        if ($Json) {
            $report | ConvertTo-Json -Depth 4
            break
        }
        Write-Section "IconDoctor - scan ($($report.Count) shortcuts)"
        $report | Format-Table Name, Verdict, Similarity, Target -AutoSize | Out-String -Width 160 | Write-Host
        $bad = @($report | Where-Object { $_.Verdict -ne 'Ok' })
        if ($bad.Count -eq 0) {
            Write-Host 'All icons look correct.' -ForegroundColor Green
        }
        else {
            Write-Host "$($bad.Count) shortcut(s) need attention. Run -Diagnose for the reason." -ForegroundColor Yellow
        }
    }

    'Diagnose' {
        $result = Invoke-IconDiagnosis @common
        if ($Json) {
            $result | ConvertTo-Json -Depth 6
            break
        }
        Write-Section 'IconDoctor - diagnosis'
        Write-Host ("Shortcuts: {0}   Blank icons: {1}" -f $result.Shortcuts, $result.BlankIcons)
        Write-Host ''
        $result.Layers | Format-Table Layer, Name, Status, Detail -AutoSize -Wrap | Out-String -Width 160 | Write-Host

        if ($result.RootCause) {
            Write-Host ("Root cause (first failing layer): {0} - {1}" -f $result.RootCause.Layer, $result.RootCause.Name) -ForegroundColor Yellow
            Write-Host $result.RootCause.Detail -ForegroundColor Yellow
        }
        else {
            Write-Host 'No failing layer detected. If icons still look wrong, check display scaling.' -ForegroundColor Green
        }
    }

    'Fix' {
        $fixArgs = @{
            RestartExplorer     = [bool]$RestartExplorer
            RebuildFolderObject = [bool]$RebuildFolderObject
            Force               = [bool]$Force
            WhatIf              = [bool]$DryRun
        }
        if ($Path) { $fixArgs.Path = $Path }

        $result = Invoke-IconRepair @fixArgs

        if ($Json) {
            $result | ConvertTo-Json -Depth 6
            break
        }

        Write-Section 'IconDoctor - repair'
        Write-Host $result.Message
        foreach ($step in $result.Steps) {
            Write-Host ("  [{0}] {1}" -f $step.Action, (Get-StepText $step))
        }
        Write-Host ''
        Write-Host ("Fixed: {0}" -f $result.Fixed) -ForegroundColor Green

        $remaining = @($result.After | Where-Object { $_.Verdict -ne 'Ok' })
        if ($remaining.Count -gt 0) {
            Write-Host ''
            Write-Host 'Still needs attention:' -ForegroundColor Yellow
            $remaining | Format-Table Name, Verdict, Message -AutoSize -Wrap | Out-String -Width 160 | Write-Host
        }
    }
}
