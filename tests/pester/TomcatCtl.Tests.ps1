#Requires -Version 5.1
<#
.SYNOPSIS
    TomcatCtl.ps1 の単体テスト（service cmdlets をラッパーで上書き）
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:ctl = Join-Path (Get-RepoRoot) 'scripts_windows\tomcat\TomcatCtl.ps1'
    if (-not (Test-Path $script:ctl)) { throw "Script not found: $script:ctl" }
}

Describe 'TomcatCtl: argument validation' {
    It 'invalid action -> ValidateSet error' {
        $r = Invoke-Controller -ScriptPath $script:ctl -Arguments @('foo', 'Tomcat10')
        $r.ExitCode | Should -Not -Be 0
    }
    It 'missing positional ServiceName -> error' {
        $r = Invoke-Controller -ScriptPath $script:ctl -Arguments @('status')
        $r.ExitCode | Should -Not -Be 0
    }
    It 'WaitTimeoutSec out of range -> error' {
        $r = Invoke-Controller -ScriptPath $script:ctl -Arguments @('start', 'Tomcat10', '-WaitTimeoutSec', '9999')
        $r.ExitCode | Should -Not -Be 0
    }
    It 'invalid characters in ServiceName -> error' {
        $r = Invoke-Controller -ScriptPath $script:ctl -Arguments @('status', 'bad;name')
        $r.ExitCode | Should -Not -Be 0
    }
}

Describe 'TomcatCtl: behaviour with mocked Get-Service' {
    It 'service not found -> exit 2' {
        $r = Invoke-ControllerWithServiceMock -ScriptPath $script:ctl -Arguments @('status', 'NoSuch') -InitialStatus 'None'
        $r.ExitCode | Should -Be 2
        $r.Combined | Should -Match 'Service not found'
    }
    It 'status is read-only (no Start/Stop/Restart calls)' {
        $r = Invoke-ControllerWithServiceMock -ScriptPath $script:ctl -Arguments @('status', 'Tomcat10') -InitialStatus 'Running'
        $r.ExitCode | Should -Be 0
        @($r.Calls | Where-Object { $_ -match 'Start-Service|Stop-Service|Restart-Service' }).Count | Should -Be 0
    }
    It 'start when already Running -> skipped (idempotent)' {
        $r = Invoke-ControllerWithServiceMock -ScriptPath $script:ctl -Arguments @('start', 'Tomcat10') -InitialStatus 'Running'
        $r.ExitCode | Should -Be 0
        $r.Combined | Should -Match 'Skipped \(idempotent\)'
        @($r.Calls | Where-Object { $_ -match 'Start-Service' }).Count | Should -Be 0
    }
    It 'stop when already Stopped -> skipped' {
        $r = Invoke-ControllerWithServiceMock -ScriptPath $script:ctl -Arguments @('stop', 'Tomcat10') -InitialStatus 'Stopped'
        $r.ExitCode | Should -Be 0
        $r.Combined | Should -Match 'Skipped'
        @($r.Calls | Where-Object { $_ -match 'Stop-Service' }).Count | Should -Be 0
    }
    It 'stop from Running -> Stop-Service called' {
        $r = Invoke-ControllerWithServiceMock -ScriptPath $script:ctl -Arguments @('stop', 'Tomcat10') -InitialStatus 'Running'
        $r.ExitCode | Should -Be 0
        @($r.Calls | Where-Object { $_ -match 'Stop-Service' }).Count | Should -BeGreaterThan 0
    }
    It 'restart always invokes Restart-Service' {
        $r = Invoke-ControllerWithServiceMock -ScriptPath $script:ctl -Arguments @('restart', 'Tomcat10') -InitialStatus 'Stopped'
        $r.ExitCode | Should -Be 0
        @($r.Calls | Where-Object { $_ -match 'Restart-Service' }).Count | Should -BeGreaterThan 0
    }
}
