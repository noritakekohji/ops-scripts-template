#Requires -Version 5.1
<#
.SYNOPSIS
    Compare-ServerInfo.ps1 の単体 + 結合テスト (fixture JSON で実行)
    Windows 側は python3 があれば共通エンジン (compare_server_info.py) に
    委譲、無ければ PS ネイティブ実装にフォールバック。両経路で
    「2 つの JSON を渡せば exit 0 になる」ことを確認する。
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $repoRoot = Get-RepoRoot
    $script:ctl = Join-Path $repoRoot 'tools\server-compare\Compare-ServerInfo.ps1'
    $script:before = Join-Path $repoRoot 'tests\fixtures\server_info_before.json'
    $script:after  = Join-Path $repoRoot 'tests\fixtures\server_info_after.json'
}

Describe 'Compare-ServerInfo: argument validation' {
    It 'missing -Before -> error' {
        $r = Invoke-Controller -ScriptPath $script:ctl -Arguments @('-After', $script:after)
        $r.ExitCode | Should -Not -Be 0
    }
    It 'non-existent -Before -> error' {
        $miss = Join-Path ([IO.Path]::GetTempPath()) ('nope-' + [Guid]::NewGuid().ToString('N') + '.json')
        $r = Invoke-Controller -ScriptPath $script:ctl -Arguments @('-Before', $miss, '-After', $script:after)
        $r.ExitCode | Should -Not -Be 0
    }
}

Describe 'Compare-ServerInfo: integration with fixtures' {
    BeforeEach { $script:work = New-TempWorkdir }
    AfterEach  { Remove-TempPath $script:work }

    It 'comparing the fixture pair succeeds (no error)' {
        $r = Invoke-Controller -ScriptPath $script:ctl -Arguments @('-Before', $script:before, '-After', $script:after)
        $r.ExitCode | Should -Be 0
    }

    It '-HtmlReport writes an HTML file with expected sections' {
        $html = Join-Path $script:work 'diff.html'
        $r = Invoke-Controller -ScriptPath $script:ctl -Arguments @('-Before', $script:before, '-After', $script:after, '-HtmlReport', $html)
        $r.ExitCode | Should -Be 0
        Test-Path $html | Should -Be $true
        $content = Get-Content $html -Raw
        $content | Should -Match '(?i)change detection|サーバ.*比較|Server.*Compare'
    }
}
