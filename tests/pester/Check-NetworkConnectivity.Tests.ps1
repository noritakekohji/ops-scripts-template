#Requires -Version 5.1
<#
.SYNOPSIS
    Check-NetworkConnectivity.ps1 の単体 + localhost 結合テスト
#>

# PS 5.1 では $PSVersionTable.Platform プロパティが無いため、
# PSEdition='Desktop' を Windows と判定（PS Core では Platform を見る）
$IsRealWindows = if ($PSVersionTable.PSObject.Properties.Name -contains 'Platform') {
    $PSVersionTable.Platform -eq 'Win32NT'
} else {
    $PSVersionTable.PSEdition -eq 'Desktop'
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:ctl = Join-Path (Get-RepoRoot) 'tools/network-check/Check-NetworkConnectivity.ps1'
}

Describe 'Check-NetworkConnectivity: argument validation' -Skip:(-not $IsRealWindows) {
    It 'missing -TargetList -> error' {
        $r = Invoke-Controller -ScriptPath $script:ctl -Arguments @()
        $r.ExitCode | Should -Not -Be 0
    }
    It 'non-existent target list -> exit 2' {
        $missing = Join-Path ([IO.Path]::GetTempPath()) ('nosuch-' + [Guid]::NewGuid().ToString('N') + '.lst')
        $r = Invoke-Controller -ScriptPath $script:ctl -Arguments @('-TargetList', $missing)
        $r.ExitCode | Should -Be 2
    }
}

Describe 'Check-NetworkConnectivity: localhost integration' -Skip:(-not $IsRealWindows) {
    BeforeEach { $script:work = New-TempWorkdir }
    AfterEach  { Remove-TempPath $script:work }

    It 'parses 4-field list and pings localhost' {
        $list = Join-Path $script:work 't.lst'
        Set-Content -LiteralPath $list -Value @(
            '# Comment',
            '',
            '127.0.0.1, -, ok, Localhost ping'
        )
        $r = Invoke-Controller -ScriptPath $script:ctl -Arguments @('-TargetList', $list, '-PingCount', '1', '-TimeoutSec', '2')
        # 0=OK / 1=some warnings; allow either since CI agents may filter ICMP
        $r.ExitCode | Should -BeIn @(0, 1)
    }

    It 'accepts 3-field (backward compatible) list' {
        $list = Join-Path $script:work 't.lst'
        Set-Content -LiteralPath $list -Value '127.0.0.1, -, Localhost (3-field)'
        $r = Invoke-Controller -ScriptPath $script:ctl -Arguments @('-TargetList', $list, '-PingCount', '1', '-TimeoutSec', '2')
        $r.ExitCode | Should -BeIn @(0, 1)
    }

    It '-HtmlReport writes an HTML file' {
        $list = Join-Path $script:work 't.lst'
        Set-Content -LiteralPath $list -Value '127.0.0.1, -, ok, Localhost'
        $html = Join-Path $script:work 'report.html'
        $r = Invoke-Controller -ScriptPath $script:ctl -Arguments @('-TargetList', $list, '-PingCount', '1', '-TimeoutSec', '2', '-HtmlReport', $html)
        Test-Path $html | Should -Be $true
        (Get-Content $html -Raw) | Should -Match '(?i)network'
    }
}
