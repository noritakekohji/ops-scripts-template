#Requires -Version 5.1

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:ctl = Join-Path (Get-RepoRoot) 'scripts_windows\sqlserver\SqlServerCtl.ps1'
}

Describe 'SqlServerCtl' {
    It 'invalid action -> error' {
        (Invoke-Controller -ScriptPath $script:ctl -Arguments @('foo','MSSQLSERVER')).ExitCode | Should -Not -Be 0
    }
    It 'named instance pattern is accepted (MSSQL$INSTANCE)' {
        # ValidatePattern allows $ sign; this only checks arg parsing, not real service.
        $r = Invoke-ControllerWithServiceMock -ScriptPath $script:ctl -Arguments @('status', 'MSSQL$PROD') -InitialStatus 'Running'
        $r.ExitCode | Should -Be 0
    }
    It 'service not found -> exit 2' {
        (Invoke-ControllerWithServiceMock -ScriptPath $script:ctl -Arguments @('status', 'NoSuch') -InitialStatus 'None').ExitCode | Should -Be 2
    }
    It 'idempotent stop when Stopped' {
        $r = Invoke-ControllerWithServiceMock -ScriptPath $script:ctl -Arguments @('stop', 'MSSQLSERVER') -InitialStatus 'Stopped'
        $r.ExitCode | Should -Be 0
        $r.Combined | Should -Match 'Skipped'
    }
}
