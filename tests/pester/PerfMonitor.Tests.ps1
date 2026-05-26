#Requires -Version 5.1
<#
.SYNOPSIS
    PerfMonitor.ps1 / perf_monitor.bat の単体テスト + 短時間結合テスト

    結合テストは: start (1 秒間隔・3 秒で自動停止) → report → HTML 検証
    まで実 PowerShell プロセスで実行する。
#>

# Discovery 時に評価する（-Skip: は BeforeAll より先に実行される）
# PS 5.1 では $PSVersionTable.Platform プロパティが無いため、
# PSEdition='Desktop' を Windows と判定（PS Core では Platform を見る）
$IsRealWindows = if ($PSVersionTable.PSObject.Properties.Name -contains 'Platform') {
    $PSVersionTable.Platform -eq 'Win32NT'
} else {
    $PSVersionTable.PSEdition -eq 'Desktop'
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:ps1 = Join-Path (Get-RepoRoot) 'tools/perf-monitor/PerfMonitor.ps1'
}

Describe 'PerfMonitor: argument validation' {
    It 'invalid command -> ValidateSet error' {
        $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('foo')
        $r.ExitCode | Should -Not -Be 0
    }

    It 'report without session_dir -> error' {
        $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('report')
        $r.ExitCode | Should -Not -Be 0
    }

    It 'report against session_dir without data.jsonl -> exit 4' {
        $work = New-TempWorkdir
        try {
            $sess = Join-Path $work 'empty_session'
            New-Item -ItemType Directory -Path $sess | Out-Null
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('report', $sess)
            $r.ExitCode | Should -Be 4
        } finally { Remove-TempPath $work }
    }
}

Describe 'PerfMonitor: end-to-end (start -> stop -> report)' -Skip:(-not $IsRealWindows) {
    It 'collects samples and produces report.html' {
        $work = New-TempWorkdir
        try {
            # 1 秒間隔・3 秒で自動停止
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('start','-Interval','1','-Duration','3','-OutputDir',$work)
            $r.ExitCode | Should -Be 0

            # session ディレクトリ
            $sess = Get-ChildItem -Path $work -Directory -Filter 'perf_*' | Select-Object -First 1
            $sess | Should -Not -BeNullOrEmpty

            # コレクタ終了を待機（最大 10 秒）
            $deadline = (Get-Date).AddSeconds(10)
            do {
                Start-Sleep -Milliseconds 500
                $pidFile = Join-Path $sess.FullName 'collector.pid'
                $stillRunning = $false
                if (Test-Path $pidFile) {
                    $cpid = [int](Get-Content $pidFile -ErrorAction SilentlyContinue)
                    $stillRunning = $null -ne (Get-Process -Id $cpid -ErrorAction SilentlyContinue)
                }
            } while ($stillRunning -and (Get-Date) -lt $deadline)

            $data = Join-Path $sess.FullName 'data.jsonl'
            Test-Path $data | Should -Be $true
            (Get-Content $data | Measure-Object -Line).Lines | Should -BeGreaterThan 0

            # report
            $r2 = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('report', $sess.FullName)
            $r2.ExitCode | Should -Be 0
            $html = Join-Path $sess.FullName 'report.html'
            Test-Path $html | Should -Be $true
            (Get-Content $html -Raw) | Should -Match '(?i)performance monitor report'
        } finally {
            # コレクタが残っていれば止める
            Get-ChildItem -Path $work -Recurse -Filter 'collector.pid' -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    $cpid = [int](Get-Content $_.FullName)
                    Stop-Process -Id $cpid -Force -ErrorAction SilentlyContinue
                } catch {}
            }
            Remove-TempPath $work
        }
    }
}

Describe 'PerfMonitor: status / list with empty workdir' {
    It 'status returns 0 when no session exists' {
        $work = New-TempWorkdir
        try {
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('status', $work) -WorkingDirectory $work
            $r.ExitCode | Should -Be 0
        } finally { Remove-TempPath $work }
    }
    It 'list returns 0 when no sessions exist' {
        $work = New-TempWorkdir
        try {
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('list') -WorkingDirectory $work
            $r.ExitCode | Should -Be 0
        } finally { Remove-TempPath $work }
    }
}
