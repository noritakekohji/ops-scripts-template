#Requires -Version 5.1
<#
.SYNOPSIS
    Rotate-Log.ps1 の単体テスト + 結合テスト（tmpdir 実 FS 操作）
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:ctl = Join-Path (Get-RepoRoot) 'scripts_windows\os\Rotate-Log.ps1'
}

Describe 'Rotate-Log: argument validation' {
    It 'no -Path and no -PathList -> error' {
        $r = Invoke-Controller -ScriptPath $script:ctl -Arguments @()
        $r.ExitCode | Should -Not -Be 0
    }
    It 'MaxSizeMB out of range -> error' {
        $r = Invoke-Controller -ScriptPath $script:ctl -Arguments @('-Path','x.log','-MaxSizeMB','99999999')
        $r.ExitCode | Should -Not -Be 0
    }
    It 'PathList not found -> error' {
        $missing = Join-Path ([IO.Path]::GetTempPath()) ('nosuch-' + [Guid]::NewGuid().ToString('N') + '.lst')
        $r = Invoke-Controller -ScriptPath $script:ctl -Arguments @('-PathList',$missing)
        $r.ExitCode | Should -Not -Be 0
    }
}

Describe 'Rotate-Log: integration with real files (tmpdir)' {
    BeforeEach {
        $script:work = New-TempWorkdir
    }
    AfterEach {
        Remove-TempPath $script:work
    }

    It 'WhatIf does not modify the file' {
        $f = Join-Path $script:work 'app.log'
        $bytes = New-Object byte[] (2 * 1024 * 1024)
        [System.IO.File]::WriteAllBytes($f, $bytes)
        $before = (Get-Item $f).Length
        $r = Invoke-Controller -ScriptPath $script:ctl -Arguments @('-Path', $f, '-MaxSizeMB', '1', '-WhatIf')
        $r.ExitCode | Should -Be 0
        (Get-Item $f).Length | Should -Be $before
    }

    It 'rotates a file that exceeds MaxSizeMB' {
        $f = Join-Path $script:work 'app.log'
        $bytes = New-Object byte[] (2 * 1024 * 1024)
        [System.IO.File]::WriteAllBytes($f, $bytes)
        $r = Invoke-Controller -ScriptPath $script:ctl -Arguments @('-Path', $f, '-MaxSizeMB', '1')
        $r.ExitCode | Should -Be 0
        # original is truncated or replaced
        (Get-Item $f -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        $rotated = Get-ChildItem $script:work -Filter 'app.log.*' -ErrorAction SilentlyContinue
        $rotated.Count | Should -BeGreaterOrEqual 1
    }

    It 'does not rotate when file is below MaxSizeMB' {
        $f = Join-Path $script:work 'app.log'
        [System.IO.File]::WriteAllBytes($f, (New-Object byte[] 1024))
        $before = (Get-Item $f).Length
        $r = Invoke-Controller -ScriptPath $script:ctl -Arguments @('-Path', $f, '-MaxSizeMB', '100')
        $r.ExitCode | Should -Be 0
        (Get-Item $f).Length | Should -Be $before
    }

    It '-Compress produces a .gz / .zip rotated file' {
        $f = Join-Path $script:work 'comp.log'
        $bytes = New-Object byte[] (2 * 1024 * 1024)
        [System.IO.File]::WriteAllBytes($f, $bytes)
        $r = Invoke-Controller -ScriptPath $script:ctl -Arguments @('-Path', $f, '-MaxSizeMB', '1', '-Compress')
        $r.ExitCode | Should -Be 0
        # Windows side may produce .zip via Compress-Archive instead of .gz
        $compressed = Get-ChildItem $script:work -Filter 'comp.log.*' |
                      Where-Object { $_.Name -match '\.(gz|zip)$' }
        $compressed.Count | Should -BeGreaterOrEqual 1
    }

    It '-RetentionCount deletes oldest rotated files' {
        $f = Join-Path $script:work 'r.log'
        $bytes = New-Object byte[] (2 * 1024 * 1024)
        [System.IO.File]::WriteAllBytes($f, $bytes)
        # dummy old rotated files
        for ($i = 1; $i -le 5; $i++) {
            $tag = '{0:00000000}-{1:000000}' -f 20250101, ($i * 100000)
            New-Item -ItemType File -Path (Join-Path $script:work "r.log.$tag") -Force | Out-Null
        }
        $r = Invoke-Controller -ScriptPath $script:ctl -Arguments @('-Path', $f, '-MaxSizeMB', '1', '-RetentionCount', '2')
        $r.ExitCode | Should -Be 0
        $remaining = (Get-ChildItem $script:work -Filter 'r.log.*').Count
        $remaining | Should -BeLessOrEqual 3
    }

    It '-PathList processes multiple files' {
        $f1 = Join-Path $script:work 'a.log'
        $f2 = Join-Path $script:work 'b.log'
        $bytes = New-Object byte[] (2 * 1024 * 1024)
        [System.IO.File]::WriteAllBytes($f1, $bytes)
        [System.IO.File]::WriteAllBytes($f2, $bytes)
        $list = Join-Path $script:work 'list.txt'
        Set-Content -LiteralPath $list -Value @($f1, $f2)
        $r = Invoke-Controller -ScriptPath $script:ctl -Arguments @('-PathList', $list, '-MaxSizeMB', '1')
        $r.ExitCode | Should -Be 0
        (Get-Item $f1).Length | Should -Be 0
        (Get-Item $f2).Length | Should -Be 0
    }
}
