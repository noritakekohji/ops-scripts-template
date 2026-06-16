#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for CollectSnapshot.ps1.
    Covers: label/no-label ZIP naming, tool failure continuation, all-fail ZIP, missing script.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:ps1 = Join-Path (Get-RepoRoot) 'tools\collect-snapshot\CollectSnapshot.ps1'

    function New-MockToolsDir {
        $mockRoot = New-TempWorkdir

        foreach ($t in @('server-snapshot', 'port-inventory', 'aws-instance-audit')) {
            New-Item -ItemType Directory -Path (Join-Path $mockRoot $t) -Force | Out-Null
        }

        # server-snapshot mock
        $ssContent = @'
#Requires -Version 5.1
param(
    [string]$Command = '',
    [string]$OutputPath = ''
)
if ($env:MOCK_CALL_LOG) {
    Add-Content -Path $env:MOCK_CALL_LOG -Value "server-snapshot: $Command $OutputPath"
}
if ($OutputPath) {
    '{"tool":"server-snapshot"}' | Set-Content -Path $OutputPath -Encoding UTF8
}
exit 0
'@
        Set-Content -Path (Join-Path $mockRoot 'server-snapshot\ServerSnapshot.ps1') -Value $ssContent -Encoding UTF8

        # port-inventory mock
        $piContent = @'
#Requires -Version 5.1
param([switch]$Json)
$flag = if ($Json) { '-Json' } else { '' }
if ($env:MOCK_CALL_LOG) {
    Add-Content -Path $env:MOCK_CALL_LOG -Value "port-inventory: $flag"
}
if ($Json) {
    '[{"tool":"port-inventory"}]'
}
exit 0
'@
        Set-Content -Path (Join-Path $mockRoot 'port-inventory\PortInventory.ps1') -Value $piContent -Encoding UTF8

        # aws-instance-audit mock
        $awsContent = @'
#Requires -Version 5.1
param([string]$OutputPath = '')
if ($env:MOCK_CALL_LOG) {
    Add-Content -Path $env:MOCK_CALL_LOG -Value "aws-instance-audit: $OutputPath"
}
if ($OutputPath) {
    '{"tool":"aws-instance-audit"}' | Set-Content -Path $OutputPath -Encoding UTF8
}
exit 0
'@
        Set-Content -Path (Join-Path $mockRoot 'aws-instance-audit\Get-AwsInstanceAudit.ps1') -Value $awsContent -Encoding UTF8

        return $mockRoot
    }

}

Describe 'CollectSnapshot: Label in folder name' {
    It '--Label puts label in archive name' {
        $work = New-TempWorkdir
        $mock = New-MockToolsDir
        $callLog = Join-Path $work 'mock_calls.log'
        try {
            $r = Invoke-Controller -ScriptPath $script:ps1 `
                -Arguments @('-Label', 'pre-upgrade', '-Output', "$work\out") `
                -Env @{ COLLECT_SNAPSHOT_TOOLS_DIR = $mock; MOCK_CALL_LOG = $callLog }
            $r.ExitCode | Should -Be 0
            $zips = @(Get-ChildItem -Path "$work\out" -Filter '*pre-upgrade*.zip' -ErrorAction SilentlyContinue)
            $zips | Should -Not -BeNullOrEmpty
        }
        finally {
            Remove-TempPath $work
            Remove-TempPath $mock
        }
    }
}

Describe 'CollectSnapshot: No label' {
    It 'generates exactly 1 ZIP without label' {
        $work = New-TempWorkdir
        $mock = New-MockToolsDir
        $callLog = Join-Path $work 'mock_calls.log'
        try {
            $r = Invoke-Controller -ScriptPath $script:ps1 `
                -Arguments @('-Output', "$work\out") `
                -Env @{ COLLECT_SNAPSHOT_TOOLS_DIR = $mock; MOCK_CALL_LOG = $callLog }
            $r.ExitCode | Should -Be 0
            $zips = @(Get-ChildItem -Path "$work\out" -Filter '*.zip' -ErrorAction SilentlyContinue)
            $zips.Count | Should -Be 1
        }
        finally {
            Remove-TempPath $work
            Remove-TempPath $mock
        }
    }
}

Describe 'CollectSnapshot: Tool failure' {
    It '1 tool failure continues and exits 1, ZIP still created' {
        $work = New-TempWorkdir
        $mock = New-MockToolsDir
        $callLog = Join-Path $work 'mock_calls.log'
        # Make port-inventory fail
        'exit 1' | Set-Content -Path (Join-Path $mock 'port-inventory\PortInventory.ps1') -Encoding UTF8
        try {
            $r = Invoke-Controller -ScriptPath $script:ps1 `
                -Arguments @('-Output', "$work\out") `
                -Env @{ COLLECT_SNAPSHOT_TOOLS_DIR = $mock; MOCK_CALL_LOG = $callLog }
            $r.ExitCode | Should -Be 1
            $logContent = Get-Content $callLog -ErrorAction SilentlyContinue
            $joined = if ($logContent) { $logContent -join "`n" } else { '' }
            $joined | Should -Match 'server-snapshot'
            $joined | Should -Match 'aws-instance-audit'
            $zips = @(Get-ChildItem -Path "$work\out" -Filter '*.zip' -ErrorAction SilentlyContinue)
            $zips.Count | Should -BeGreaterThan 0
        }
        finally {
            Remove-TempPath $work
            Remove-TempPath $mock
        }
    }
}

Describe 'CollectSnapshot: All tools fail' {
    It 'all tools fail → ZIP still generated, exit 1' {
        $work = New-TempWorkdir
        $mock = New-MockToolsDir
        $callLog = Join-Path $work 'mock_calls.log'
        # Make all 3 tools fail
        'exit 1' | Set-Content -Path (Join-Path $mock 'server-snapshot\ServerSnapshot.ps1') -Encoding UTF8
        'exit 1' | Set-Content -Path (Join-Path $mock 'port-inventory\PortInventory.ps1') -Encoding UTF8
        'exit 1' | Set-Content -Path (Join-Path $mock 'aws-instance-audit\Get-AwsInstanceAudit.ps1') -Encoding UTF8
        try {
            $r = Invoke-Controller -ScriptPath $script:ps1 `
                -Arguments @('-Output', "$work\out") `
                -Env @{ COLLECT_SNAPSHOT_TOOLS_DIR = $mock; MOCK_CALL_LOG = $callLog }
            $r.ExitCode | Should -Be 1
            $zips = @(Get-ChildItem -Path "$work\out" -Filter '*.zip' -ErrorAction SilentlyContinue)
            $zips.Count | Should -BeGreaterThan 0
        } finally { Remove-TempPath $work; Remove-TempPath $mock }
    }
}

Describe 'CollectSnapshot: Missing tool script' {
    It 'missing tool script is skipped, other tools run, exit 1' {
        $work = New-TempWorkdir
        $mock = New-MockToolsDir
        $callLog = Join-Path $work 'mock_calls.log'
        # Remove port-inventory script
        Remove-Item -Path (Join-Path $mock 'port-inventory\PortInventory.ps1') -Force
        try {
            $r = Invoke-Controller -ScriptPath $script:ps1 `
                -Arguments @('-Output', "$work\out") `
                -Env @{ COLLECT_SNAPSHOT_TOOLS_DIR = $mock; MOCK_CALL_LOG = $callLog }
            $r.ExitCode | Should -Be 1
            # Other tools still ran
            $log = Get-Content $callLog -ErrorAction SilentlyContinue
            ($log -join "`n") | Should -Match 'server-snapshot'
            ($log -join "`n") | Should -Match 'aws-instance-audit'
        } finally { Remove-TempPath $work; Remove-TempPath $mock }
    }
}
