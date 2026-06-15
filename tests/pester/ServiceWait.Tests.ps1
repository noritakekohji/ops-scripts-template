#Requires -Version 5.1
Set-StrictMode -Version Latest

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:Script  = Join-Path (Get-RepoRoot) 'scripts_windows\os\ServiceWait.ps1'
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures\service_wait\sample.lst'
    $script:BaseEnv = @{
        OPS_LIB        = Join-Path (Get-RepoRoot) 'scripts_windows\lib'
        OPS_CONFIG_DIR = Join-Path (Get-RepoRoot) 'config'
    }
}

Describe 'ServiceWait.ps1 argument and list parsing' {
    It 'fails with exit 1 when no list given' {
        $r = Invoke-Controller -ScriptPath $script:Script -Arguments @() -Env $script:BaseEnv
        $r.ExitCode | Should -Be 1
    }
    It 'fails with exit 2 when list file does not exist' {
        $r = Invoke-Controller -ScriptPath $script:Script -Arguments @('-TargetList', 'C:\does\not\exist.lst') -Env $script:BaseEnv
        $r.ExitCode | Should -Be 2
    }
    It 'fails with exit 2 on unknown type' {
        $work = New-TempWorkdir
        try {
            $tmp = Join-Path $work 'bad-type.lst'
            'foo, 127.0.0.1, bad type' | Set-Content -Path $tmp -Encoding ASCII
            $r = Invoke-Controller -ScriptPath $script:Script -Arguments @('-TargetList', $tmp) -Env $script:BaseEnv
            $r.ExitCode | Should -Be 2
        } finally {
            Remove-TempPath $work
        }
    }
    It 'fails with exit 2 when a row has more than 3 columns (v3.1)' {
        $work = New-TempWorkdir
        try {
            $tmp = Join-Path $work 'extra-col.lst'
            'ping, 127.0.0.1, desc, per_check_timeout_sec=2' | Set-Content -Path $tmp -Encoding ASCII
            $r = Invoke-Controller -ScriptPath $script:Script -Arguments @('-TargetList', $tmp) -Env $script:BaseEnv
            $r.ExitCode | Should -Be 2
            $r.Combined | Should -Match 'extra_columns'
        } finally {
            Remove-TempPath $work
        }
    }
    It 'reports start line and times out (exit 3) on closed targets' {
        $env = @{} + $script:BaseEnv
        $env['OPS_OVERRIDE_TIMEOUT_SEC']      = '1'
        $env['OPS_OVERRIDE_INITIAL_WAIT_SEC'] = '0'
        $env['OPS_OVERRIDE_INTERVAL_SEC']     = '1'
        $r = Invoke-Controller -ScriptPath $script:Script -Arguments @('-TargetList', $script:Fixture) -Env $env
        $r.ExitCode | Should -Be 3
        $r.Combined | Should -Match 'start targets=3'
    }
}

Describe 'ServiceWait.ps1 v2 .lst header' {
    It 'header timeout_sec=1 makes the script time out without env override' {
        $work = New-TempWorkdir
        try {
            $tmp = Join-Path $work 'hdr-timeout.lst'
            @(
                'initial_wait_sec = 0',
                'interval_sec     = 1',
                'timeout_sec      = 1',
                '',
                'tcp, 127.0.0.1:1, closed'
            ) | Set-Content -Path $tmp -Encoding ASCII
            $r = Invoke-Controller -ScriptPath $script:Script -Arguments @('-TargetList', $tmp) -Env $script:BaseEnv
            $r.ExitCode | Should -Be 3
        } finally {
            Remove-TempPath $work
        }
    }
    It 'header with unknown key exits 2' {
        $work = New-TempWorkdir
        try {
            $tmp = Join-Path $work 'bad-hdr-key.lst'
            @(
                'no_such_setting = 99',
                'tcp, 127.0.0.1:1, closed'
            ) | Set-Content -Path $tmp -Encoding ASCII
            $r = Invoke-Controller -ScriptPath $script:Script -Arguments @('-TargetList', $tmp) -Env $script:BaseEnv
            $r.ExitCode | Should -Be 2
            $r.Combined | Should -Match 'unknown_header_key'
        } finally {
            Remove-TempPath $work
        }
    }
    It 'header with non-integer value exits 2' {
        $work = New-TempWorkdir
        try {
            $tmp = Join-Path $work 'bad-hdr-val.lst'
            @(
                'timeout_sec = abc',
                'tcp, 127.0.0.1:1, closed'
            ) | Set-Content -Path $tmp -Encoding ASCII
            $r = Invoke-Controller -ScriptPath $script:Script -Arguments @('-TargetList', $tmp) -Env $script:BaseEnv
            $r.ExitCode | Should -Be 2
            $r.Combined | Should -Match 'bad_header_value'
        } finally {
            Remove-TempPath $work
        }
    }
    It 'key=value line after a target row is rejected' {
        $work = New-TempWorkdir
        try {
            $tmp = Join-Path $work 'hdr-after-target.lst'
            @(
                'tcp, 127.0.0.1:1, closed',
                'interval_sec = 5'
            ) | Set-Content -Path $tmp -Encoding ASCII
            $r = Invoke-Controller -ScriptPath $script:Script -Arguments @('-TargetList', $tmp) -Env $script:BaseEnv
            $r.ExitCode | Should -Be 2
            $r.Combined | Should -Match 'header_after_targets'
        } finally {
            Remove-TempPath $work
        }
    }
    It 'monitoring keys lingering in conf produce a WARN and are ignored' {
        $work = New-TempWorkdir
        try {
            # OPS_CONFIG_DIR points directly at the dir containing service_wait.conf
            # (not at a tree with default/ subdir; see Get-OpsConfig).
            @(
                'interval_sec = 999',
                'timeout_sec  = 999',
                'LogLevel     = INFO'
            ) | Set-Content -Path (Join-Path $work 'service_wait.conf') -Encoding ASCII

            $tmp = Join-Path $work 'targets.lst'
            @(
                'timeout_sec = 1',
                '',
                'tcp, 127.0.0.1:1, closed'
            ) | Set-Content -Path $tmp -Encoding ASCII

            $env = @{} + $script:BaseEnv
            $env['OPS_CONFIG_DIR'] = $work
            $r = Invoke-Controller -ScriptPath $script:Script -Arguments @('-TargetList', $tmp) -Env $env
            $r.ExitCode | Should -Be 3
            $r.Combined | Should -Match 'no longer used'
        } finally {
            Remove-TempPath $work
        }
    }
}

Describe 'ServiceWait.ps1 v3 local service / process' {
    It 'exit 2 when service name contains a space' {
        $work = New-TempWorkdir
        try {
            $tmp = Join-Path $work 'bad-svc.lst'
            'service, bad name, with space' | Set-Content -Path $tmp -Encoding ASCII
            $r = Invoke-Controller -ScriptPath $script:Script -Arguments @('-TargetList', $tmp) -Env $script:BaseEnv
            $r.ExitCode | Should -Be 2
            $r.Combined | Should -Match 'bad_service_name'
        } finally {
            Remove-TempPath $work
        }
    }
    It 'exit 2 when process name contains a space' {
        $work = New-TempWorkdir
        try {
            $tmp = Join-Path $work 'bad-proc.lst'
            'process, bad name, with space' | Set-Content -Path $tmp -Encoding ASCII
            $r = Invoke-Controller -ScriptPath $script:Script -Arguments @('-TargetList', $tmp) -Env $script:BaseEnv
            $r.ExitCode | Should -Be 2
            $r.Combined | Should -Match 'bad_process_name'
        } finally {
            Remove-TempPath $work
        }
    }
    It 'process check finds the running test host (powershell)' {
        # powershell.exe must be present because we are running this test.
        $work = New-TempWorkdir
        try {
            $tmp = Join-Path $work 'self.lst'
            @(
                'timeout_sec      = 5',
                'interval_sec     = 1',
                'success_threshold= 1',
                'initial_wait_sec = 0',
                '',
                'process, powershell, current shell'
            ) | Set-Content -Path $tmp -Encoding ASCII
            $r = Invoke-Controller -ScriptPath $script:Script -Arguments @('-TargetList', $tmp) -Env $script:BaseEnv
            $r.ExitCode | Should -Be 0
        } finally {
            Remove-TempPath $work
        }
    }
    It 'process check times out on a missing name' {
        $work = New-TempWorkdir
        try {
            $tmp = Join-Path $work 'missing-proc.lst'
            @(
                'timeout_sec      = 2',
                'interval_sec     = 1',
                'initial_wait_sec = 0',
                '',
                'process, nope-does-not-exist, missing'
            ) | Set-Content -Path $tmp -Encoding ASCII
            $r = Invoke-Controller -ScriptPath $script:Script -Arguments @('-TargetList', $tmp) -Env $script:BaseEnv
            $r.ExitCode | Should -Be 3
        } finally {
            Remove-TempPath $work
        }
    }
    It 'service check finds a known Running service (EventLog)' {
        $eventLog = Get-Service -Name 'EventLog' -ErrorAction SilentlyContinue
        if (-not $eventLog -or $eventLog.Status -ne 'Running') {
            Set-ItResult -Skipped -Because 'EventLog service not Running on this host'
            return
        }
        $work = New-TempWorkdir
        try {
            $tmp = Join-Path $work 'svc-eventlog.lst'
            @(
                'timeout_sec      = 5',
                'interval_sec     = 1',
                'success_threshold= 1',
                'initial_wait_sec = 0',
                '',
                'service, EventLog, Windows Event Log'
            ) | Set-Content -Path $tmp -Encoding ASCII
            $r = Invoke-Controller -ScriptPath $script:Script -Arguments @('-TargetList', $tmp) -Env $script:BaseEnv
            $r.ExitCode | Should -Be 0
        } finally {
            Remove-TempPath $work
        }
    }
    It 'service check times out on a missing service' {
        $work = New-TempWorkdir
        try {
            $tmp = Join-Path $work 'svc-missing.lst'
            @(
                'timeout_sec      = 2',
                'interval_sec     = 1',
                'initial_wait_sec = 0',
                '',
                'service, NoSuchServiceXYZ, missing'
            ) | Set-Content -Path $tmp -Encoding ASCII
            $r = Invoke-Controller -ScriptPath $script:Script -Arguments @('-TargetList', $tmp) -Env $script:BaseEnv
            $r.ExitCode | Should -Be 3
        } finally {
            Remove-TempPath $work
        }
    }
}

Describe 'ServiceWait.ps1 round semantics' {
    It 'exits 0 when a TCP listener is up' {
        # Bind an ephemeral port and accept once.
        $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), 0
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        try {
            $work = New-TempWorkdir
            try {
                $tmp = Join-Path $work 'listener.lst'
                "tcp, 127.0.0.1:$port, listener" | Set-Content -Path $tmp -Encoding ASCII
                $env = @{} + $script:BaseEnv
                $env['OPS_OVERRIDE_INITIAL_WAIT_SEC']  = '0'
                $env['OPS_OVERRIDE_INTERVAL_SEC']      = '1'
                $env['OPS_OVERRIDE_TIMEOUT_SEC']       = '5'
                $env['OPS_OVERRIDE_SUCCESS_THRESHOLD'] = '1'
                $r = Invoke-Controller -ScriptPath $script:Script -Arguments @('-TargetList', $tmp) -Env $env
                $r.ExitCode | Should -Be 0
            } finally {
                Remove-TempPath $work
            }
        } finally {
            $listener.Stop()
        }
    }
}
