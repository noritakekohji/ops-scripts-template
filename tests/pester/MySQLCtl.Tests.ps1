#Requires -Version 5.1

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:ctl = Join-Path (Get-RepoRoot) 'scripts_windows\mysql\MySQLCtl.ps1'
}

Describe 'MySQLCtl' {
    It 'invalid action -> error' {
        (Invoke-Controller -ScriptPath $script:ctl -Arguments @('foo','MySQL')).ExitCode | Should -Not -Be 0
    }
    It 'service not found -> exit 2' {
        (Invoke-ControllerWithServiceMock -ScriptPath $script:ctl -Arguments @('status', 'NoSuch') -InitialStatus 'None').ExitCode | Should -Be 2
    }
    It 'idempotent stop when Stopped' {
        $r = Invoke-ControllerWithServiceMock -ScriptPath $script:ctl -Arguments @('stop', 'MySQL') -InitialStatus 'Stopped'
        $r.ExitCode | Should -Be 0
        $r.Combined | Should -Match 'Skipped'
    }
    It 'stop from Running -> Stop-Service called' {
        $r = Invoke-ControllerWithServiceMock -ScriptPath $script:ctl -Arguments @('stop', 'MySQL') -InitialStatus 'Running'
        @($r.Calls | Where-Object { $_ -match 'Stop-Service' }).Count | Should -BeGreaterThan 0
    }
}
