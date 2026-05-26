#Requires -Version 5.1

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:ctl = Join-Path (Get-RepoRoot) 'scripts_windows\postgresql\PostgreSQLCtl.ps1'
}

Describe 'PostgreSQLCtl' {
    It 'invalid action -> error' {
        (Invoke-Controller -ScriptPath $script:ctl -Arguments @('foo','postgresql')).ExitCode | Should -Not -Be 0
    }
    It 'service not found -> exit 2' {
        (Invoke-ControllerWithServiceMock -ScriptPath $script:ctl -Arguments @('status', 'NoSuch') -InitialStatus 'None').ExitCode | Should -Be 2
    }
    It 'idempotent start when Running' {
        $r = Invoke-ControllerWithServiceMock -ScriptPath $script:ctl -Arguments @('start', 'postgresql') -InitialStatus 'Running'
        $r.ExitCode | Should -Be 0
        $r.Combined | Should -Match 'Skipped'
    }
    It 'restart always runs' {
        $r = Invoke-ControllerWithServiceMock -ScriptPath $script:ctl -Arguments @('restart', 'postgresql') -InitialStatus 'Stopped'
        @($r.Calls | Where-Object { $_ -match 'Restart-Service' }).Count | Should -BeGreaterThan 0
    }
}
