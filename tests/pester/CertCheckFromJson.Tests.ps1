#Requires -Version 5.1
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:ps1     = Join-Path (Get-RepoRoot) 'tools\cert-check\CertCheck.ps1'
    $script:fixture = Join-Path $PSScriptRoot 'fixtures\from-json\cert_sample.json'
}

Describe 'CertCheck -FromJson' {
    It 'reads JSON and emits JSON with all records, exit 1 (WARN/NG present)' {
        $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('-FromJson', $script:fixture, '-Json')
        $r.ExitCode | Should -Be 1
        # PS5.1: ConvertFrom-Json does not enumerate its array result through the
        # pipeline, so assign first then wrap with @() to count elements.
        $parsed = $r.StdOut | ConvertFrom-Json
        $arr = @($parsed)
        $arr.Count | Should -Be 3
        ($arr | Where-Object { $_.host -eq 'ok.example.com' }).status | Should -Be 'OK'
    }

    It 'FailOnly hides OK rows' {
        $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('-FromJson', $script:fixture, '-Json', '-FailOnly')
        $parsed = $r.StdOut | ConvertFrom-Json
        $arr = @($parsed)
        $arr.Count | Should -Be 2
        ($arr | Where-Object { $_.status -eq 'OK' }).Count | Should -Be 0
    }

    It 'generates an HTML report containing host names' {
        $work = New-TempWorkdir
        try {
            $html = Join-Path $work 'cert.html'
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('-FromJson', $script:fixture, '-HtmlReport', $html)
            Test-Path -LiteralPath $html | Should -Be $true
            (Get-Content -LiteralPath $html -Raw) | Should -Match 'ng\.example\.com'
        } finally { Remove-TempPath $work }
    }

    It 'missing file exits 2' {
        $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('-FromJson', 'C:\no\such\file.json')
        $r.ExitCode | Should -Be 2
    }

    It 'broken JSON exits 1' {
        $work = New-TempWorkdir
        try {
            $bad = Join-Path $work 'bad.json'
            'not json {' | Set-Content -LiteralPath $bad -Encoding UTF8
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('-FromJson', $bad)
            $r.ExitCode | Should -Be 1
        } finally { Remove-TempPath $work }
    }

    It 'no -TargetList and no -FromJson exits 1' {
        $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @()
        $r.ExitCode | Should -Be 1
    }
}
