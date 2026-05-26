#Requires -Version 5.1
<#
.SYNOPSIS
    Get-ServerInfo.ps1 の smoke test (実 Windows API 呼び出しを許可)
#>

$IsRealWindows = ($PSVersionTable.Platform -eq 'Win32NT') -or ($PSVersionTable.PSEdition -eq 'Desktop')

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:ctl = Join-Path (Get-RepoRoot) 'scripts_windows/os/Get-ServerInfo.ps1'
}

Describe 'Get-ServerInfo: smoke' -Skip:(-not $IsRealWindows) {
    BeforeEach { $script:work = New-TempWorkdir }
    AfterEach  { Remove-TempPath $script:work }

    It 'writes JSON to -OutputPath' {
        $out = Join-Path $script:work 'info.json'
        $r = Invoke-Controller -ScriptPath $script:ctl -Arguments @('-OutputPath', $out)
        $r.ExitCode | Should -Be 0
        Test-Path $out | Should -Be $true
        # JSON として parse できること
        $obj = Get-Content $out -Raw | ConvertFrom-Json
        $obj | Should -Not -BeNullOrEmpty
    }

    It '-Category os emits an os section' {
        $out = Join-Path $script:work 'info.json'
        $r = Invoke-Controller -ScriptPath $script:ctl -Arguments @('-Category','os','-OutputPath',$out)
        $r.ExitCode | Should -Be 0
        $obj = Get-Content $out -Raw | ConvertFrom-Json
        $obj.PSObject.Properties.Name | Should -Contain 'os'
    }
}
