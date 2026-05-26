#Requires -Version 5.1
<#
.SYNOPSIS
    Change-Detect.ps1 の単体テスト
    before / after モードはサブプロセスで Get-ServerInfo を呼ぶため smoke 程度。
    比較ロジックは Compare-ServerInfo.Tests.ps1 で別途検証済。
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:ctl = Join-Path (Get-RepoRoot) 'tools\change-detect\Change-Detect.ps1'
}

Describe 'Change-Detect: argument validation' {
    It 'no Mode -> error' {
        (Invoke-Controller -ScriptPath $script:ctl -Arguments @()).ExitCode | Should -Not -Be 0
    }
    It 'invalid Mode -> ValidateSet error' {
        (Invoke-Controller -ScriptPath $script:ctl -Arguments @('foo')).ExitCode | Should -Not -Be 0
    }
}
