#Requires -Version 5.1
# Discovery 時に評価する（-Skip: は BeforeAll より先に走るため）
$pyDisc = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $pyDisc) { $pyDisc = Get-Command python -ErrorAction SilentlyContinue }
$HasPython = [bool]$pyDisc

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:ps1     = Join-Path (Get-RepoRoot) 'tools\aws-instance-audit\Get-AwsInstanceAudit.ps1'
    $script:fixture = Join-Path $PSScriptRoot 'fixtures\from-json\aws_sample.json'
}

Describe 'Get-AwsInstanceAudit -FromJson' {
    It 'copies JSON to -OutputPath and exits 0' {
        $work = New-TempWorkdir
        try {
            $out = Join-Path $work 'copied.json'
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('-FromJson', $script:fixture, '-OutputPath', $out)
            $r.ExitCode | Should -Be 0
            Test-Path -LiteralPath $out | Should -Be $true
            $obj = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
            $obj.meta.instance_id | Should -Be 'i-0abc123def456'
        } finally { Remove-TempPath $work }
    }

    It 'generates an HTML report from saved JSON' -Skip:(-not $HasPython) {
        $work = New-TempWorkdir
        try {
            $html = Join-Path $work 'aws.html'
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('-FromJson', $script:fixture, '-HtmlReport', $html)
            $r.ExitCode | Should -Be 0
            Test-Path -LiteralPath $html | Should -Be $true
            (Get-Content -LiteralPath $html -Raw) | Should -Match 'i-0abc123def456'
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
}
