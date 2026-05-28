#Requires -Version 5.1
<#
.SYNOPSIS
    Get-AwsInstanceAudit.ps1 の単体テスト
    実 AWS / 実 IMDS には依存せず、引数バリデーションと
    共通 python ヘルパー (render_report.py / _assemble_json.py) を検証する。
#>

# Discovery 時に評価する（-Skip: は BeforeAll より先に走るため）
$pyDisc = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $pyDisc) { $pyDisc = Get-Command python -ErrorAction SilentlyContinue }
$HasPython = [bool]$pyDisc

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:repoRoot = Get-RepoRoot
    $script:ctl      = Join-Path $script:repoRoot 'tools/aws-instance-audit/Get-AwsInstanceAudit.ps1'
    $script:renderPy = Join-Path $script:repoRoot 'tools/aws-instance-audit/render_report.py'
    $script:fixture  = Join-Path $script:repoRoot 'tests/fixtures/aws_audit_sample.json'

    $py = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
    $script:python = if ($py) { $py.Source } else { $null }
}

Describe 'Get-AwsInstanceAudit: prerequisites' {
    It 'exits 10 when aws CLI is not in PATH' {
        # PATH から aws を除いた状態で子プロセス実行する。
        # Invoke-Controller は -Command 経由なので、子プロセス側で $env:PATH を
        # 絞ってから本体を呼ぶラッパーにする。
        $work = New-TempWorkdir
        try {
            $wrapper = Join-Path $work 'w.ps1'
            $content = @"
`$env:PATH = 'C:\Windows\System32;C:\Windows'
& '$($script:ctl)'
exit `$LASTEXITCODE
"@
            Set-Content -LiteralPath $wrapper -Value $content -Encoding UTF8
            # aws.exe が System32 に無い前提（通常無い）。あればスキップ。
            if (Get-Command aws -ErrorAction SilentlyContinue) {
                $awsInSys32 = Test-Path 'C:\Windows\System32\aws.exe'
                if ($awsInSys32) { Set-ItResult -Skipped -Because 'aws present in System32'; return }
            }
            $r = Invoke-Controller -ScriptPath $wrapper
            $r.ExitCode | Should -Be 10
        } finally { Remove-TempPath $work }
    }
}

Describe 'render_report.py (shared HTML renderer)' -Skip:(-not $HasPython) {
    BeforeEach { $script:work = New-TempWorkdir }
    AfterEach  { Remove-TempPath $script:work }

    It 'renders HTML from the fixture JSON' {
        $out = Join-Path $script:work 'audit.html'
        & $script:python $script:renderPy $script:fixture $out
        $LASTEXITCODE | Should -Be 0
        Test-Path $out | Should -Be $true
        $content = Get-Content $out -Raw
        $content | Should -Match 'AWS Instance Audit Report'
        $content | Should -Match 'web-instance-role'
        $content | Should -Match 'sg-0web11111'
        $content | Should -Match 'vpc-0aaa1111'
    }

    It 'exits 1 when called with too few args' {
        & $script:python $script:renderPy $script:fixture | Out-Null
        $LASTEXITCODE | Should -Be 1
    }
}

Describe '_assemble_json.py (shared assembler)' -Skip:(-not $HasPython) {
    BeforeEach { $script:work = New-TempWorkdir }
    AfterEach  {
        Remove-TempPath $script:work
        # テストで設定した環境変数を片付ける
        'TMPD','OUT','CATS','HOSTNAME_S','REGION','INST_ID','INST_TYPE','AMI','AZ',
        'LOCAL_IP','PUBLIC_IP','VPC_ID','SUBNET_ID','IAM_ROLE' | ForEach-Object {
            Remove-Item "env:$_" -ErrorAction SilentlyContinue
        }
    }

    It 'assembles meta + instance + tags' {
        $assembler = Join-Path $script:repoRoot 'tools/aws-instance-audit/_assemble_json.py'
        $td = Join-Path $script:work 'tmp'
        New-Item -ItemType Directory -Path $td | Out-Null
        Set-Content -LiteralPath (Join-Path $td 'tags.json') -Encoding UTF8 -Value `
            '{ "Tags": [ { "Key": "Name", "Value": "web01" } ] }'
        $out = Join-Path $script:work 'out.json'

        $env:TMPD = $td; $env:OUT = $out; $env:CATS = 'instance'
        $env:HOSTNAME_S = 'web01'; $env:REGION = 'ap-northeast-1'
        $env:INST_ID = 'i-0test'; $env:INST_TYPE = 't3.micro'; $env:AMI = 'ami-0x'
        $env:AZ = 'ap-northeast-1a'; $env:LOCAL_IP = '10.0.1.5'; $env:PUBLIC_IP = ''
        $env:VPC_ID = 'vpc-0x'; $env:SUBNET_ID = 'subnet-0x'; $env:IAM_ROLE = ''

        & $script:python $assembler | Out-Null
        $LASTEXITCODE | Should -Be 0
        Test-Path $out | Should -Be $true
        $d = Get-Content $out -Raw | ConvertFrom-Json
        $d.meta.instance_id | Should -Be 'i-0test'
        $d.instance.instance_type | Should -Be 't3.micro'
        $d.instance.tags.Name | Should -Be 'web01'
    }
}
