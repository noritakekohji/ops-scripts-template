#Requires -Version 5.1

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:ctl = Join-Path (Get-RepoRoot) 'scripts_windows\nginx\NginxCtl.ps1'
}

Describe 'NginxCtl: argument validation' {
    It 'invalid action -> error' {
        (Invoke-Controller -ScriptPath $script:ctl -Arguments @('foo','nginx')).ExitCode | Should -Not -Be 0
    }
    It 'missing service -> error' {
        (Invoke-Controller -ScriptPath $script:ctl -Arguments @('status')).ExitCode | Should -Not -Be 0
    }
}

Describe 'NginxCtl: behaviour' {
    It 'service not found -> exit 2' {
        $r = Invoke-ControllerWithServiceMock -ScriptPath $script:ctl -Arguments @('status', 'nginx') -InitialStatus 'None'
        $r.ExitCode | Should -Be 2
    }
    It 'idempotent start when Running' {
        $r = Invoke-ControllerWithServiceMock -ScriptPath $script:ctl -Arguments @('start', 'nginx') -InitialStatus 'Running'
        $r.ExitCode | Should -Be 0
        $r.Combined | Should -Match 'Skipped'
    }
    It 'restart always runs' {
        $r = Invoke-ControllerWithServiceMock -ScriptPath $script:ctl -Arguments @('restart', 'nginx') -InitialStatus 'Stopped'
        ($r.Calls | Where-Object { $_ -match 'Restart-Service' }).Count | Should -BeGreaterThan 0
    }
    It 'status is read-only' {
        $r = Invoke-ControllerWithServiceMock -ScriptPath $script:ctl -Arguments @('status', 'nginx') -InitialStatus 'Running'
        ($r.Calls | Where-Object { $_ -match 'Start-Service|Stop-Service|Restart-Service' }).Count | Should -Be 0
    }
}
