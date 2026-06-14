#Requires -Version 5.1
Set-StrictMode -Version Latest

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:Script  = Join-Path (Get-RepoRoot) 'scripts_windows\os\ServiceWait.ps1'
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures\service_wait\sample.lst'
    $env:OPS_LIB        = Join-Path (Get-RepoRoot) 'scripts_windows\lib'
    $env:OPS_CONFIG_DIR = Join-Path (Get-RepoRoot) 'config'
}

function Invoke-SW {
    param([string[]]$ArgsList)
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Script @ArgsList 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
}

Describe 'ServiceWait.ps1 argument and list parsing' {
    It 'fails with exit 1 when no list given' {
        $r = Invoke-SW @()
        $r.ExitCode | Should -Be 1
    }
    It 'fails with exit 2 when list file does not exist' {
        $r = Invoke-SW @('-TargetList', 'C:\does\not\exist.lst')
        $r.ExitCode | Should -Be 2
    }
    It 'fails with exit 2 on unknown type' {
        $work = New-TempWorkdir
        try {
            $tmp = Join-Path $work 'bad-type.lst'
            'foo, 127.0.0.1, bad type' | Set-Content -Path $tmp -Encoding ASCII
            $r = Invoke-SW @('-TargetList', $tmp)
            $r.ExitCode | Should -Be 2
        } finally {
            Remove-TempPath $work
        }
    }
    It 'fails with exit 2 on unknown override key' {
        $work = New-TempWorkdir
        try {
            $tmp = Join-Path $work 'bad-key.lst'
            'ping, 127.0.0.1, desc, success_threshold=99' | Set-Content -Path $tmp -Encoding ASCII
            $r = Invoke-SW @('-TargetList', $tmp)
            $r.ExitCode | Should -Be 2
        } finally {
            Remove-TempPath $work
        }
    }
    It 'reports start line and times out (exit 3) on closed targets' {
        $env:OPS_OVERRIDE_TIMEOUT_SEC      = '1'
        $env:OPS_OVERRIDE_INITIAL_WAIT_SEC = '0'
        $env:OPS_OVERRIDE_INTERVAL_SEC     = '1'
        try {
            $r = Invoke-SW @('-TargetList', $script:Fixture)
            $r.ExitCode | Should -Be 3
            $r.Output   | Should -Match 'start targets=3'
        } finally {
            $env:OPS_OVERRIDE_TIMEOUT_SEC      = $null
            $env:OPS_OVERRIDE_INITIAL_WAIT_SEC = $null
            $env:OPS_OVERRIDE_INTERVAL_SEC     = $null
        }
    }
}
