#Requires -Version 5.1
<#
.SYNOPSIS
    Get-AwsInstanceAudit.ps1 の単体テスト
    実 AWS / 実 IMDS には依存しない。
    - 引数 / 前提チェック（aws CLI 不在）
    - JSON 組み立て（aws / Invoke-RestMethod を関数モック化した end-to-end。python3 不要）
    - render_report.py（HTML、python3 がある場合のみ）
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

Describe 'Get-AwsInstanceAudit: native JSON assembly (no python)' {
    BeforeEach { $script:work = New-TempWorkdir }
    AfterEach  { Remove-TempPath $script:work }

    It 'assembles full JSON via ConvertTo-Json without python3' {
        $out = Join-Path $script:work 'out.json'
        $wrapper = Join-Path $script:work 'w.ps1'

        # aws / Invoke-RestMethod を関数で上書きして本体を呼ぶ。
        # 関数は外部コマンド / cmdlet より優先されるため、IMDS / AWS CLI を疑似化できる。
        $tmpl = @'
$ErrorActionPreference = 'Stop'

function Invoke-RestMethod {
    [CmdletBinding()]
    param([string]$Method, [string]$Uri, $Headers, $TimeoutSec, $Body)
    switch -Wildcard ($Uri) {
        '*/api/token'             { 'TOK'; return }
        '*instance-id'            { 'i-0test123'; return }
        '*instance-type'          { 't3.micro'; return }
        '*ami-id'                 { 'ami-0abc'; return }
        '*availability-zone'      { 'ap-northeast-1a'; return }
        '*placement/region'       { 'ap-northeast-1'; return }
        '*local-ipv4'             { '10.0.1.23'; return }
        '*public-ipv4'            { ''; return }
        '*meta-data/mac'          { '0a:11:22:33:44:55'; return }
        '*/vpc-id'                { 'vpc-0aaa'; return }
        '*/subnet-id'             { 'subnet-0bbb'; return }
        '*/security-group-ids'    { 'sg-0web'; return }
        '*security-credentials/'  { 'web-instance-role'; return }
        default                   { ''; return }
    }
}

function aws {
    $global:LASTEXITCODE = 0
    $svc = $args[0]; $act = $args[1]
    if ($svc -eq 'sts') { return }
    switch ($act) {
        'describe-tags'                { '{"Tags":[{"Key":"Name","Value":"web01"},{"Key":"Env","Value":"prod"}]}' }
        'get-role'                     { '{"Role":{"Arn":"arn:aws:iam::123:role/web-instance-role","CreateDate":"2024-01-01T00:00:00+00:00"}}' }
        'list-attached-role-policies'  { '{"AttachedPolicies":[{"PolicyName":"AmazonS3ReadOnlyAccess","PolicyArn":"arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"}]}' }
        'list-role-policies'           { '{"PolicyNames":["app-secrets-read"]}' }
        'describe-security-groups'     { '{"SecurityGroups":[{"GroupId":"sg-0web","GroupName":"web-sg","Description":"web tier","VpcId":"vpc-0aaa","IpPermissions":[{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}],"IpPermissionsEgress":[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]}]}' }
        'describe-vpcs'                { '{"Vpcs":[{"VpcId":"vpc-0aaa","CidrBlock":"10.0.0.0/16","IsDefault":false}]}' }
        'describe-subnets'             { '{"Subnets":[{"SubnetId":"subnet-0bbb","CidrBlock":"10.0.1.0/24","AvailabilityZone":"ap-northeast-1a","MapPublicIpOnLaunch":true}]}' }
        'describe-network-interfaces'  { '{"NetworkInterfaces":[{"NetworkInterfaceId":"eni-0eee","PrivateIpAddress":"10.0.1.23","SubnetId":"subnet-0bbb","Description":"primary","Groups":[{"GroupId":"sg-0web"}]}]}' }
        'describe-route-tables'        { '{"RouteTables":[{"RouteTableId":"rtb-0fff","Routes":[{"DestinationCidrBlock":"local"},{"DestinationCidrBlock":"0.0.0.0/0","GatewayId":"igw-0ggg"}]}]}' }
        default                        { 'null' }
    }
}

& '__CTL__' -OutputPath '__OUT__'
exit $LASTEXITCODE
'@
        $content = $tmpl.Replace('__CTL__', $script:ctl).Replace('__OUT__', $out)
        Set-Content -LiteralPath $wrapper -Value $content -Encoding UTF8

        $r = Invoke-Controller -ScriptPath $wrapper
        $r.ExitCode | Should -Be 0
        Test-Path $out | Should -Be $true

        $d = Get-Content $out -Raw | ConvertFrom-Json
        $d.meta.instance_id        | Should -Be 'i-0test123'
        $d.instance.tags.Name      | Should -Be 'web01'
        $d.instance.tags.Env       | Should -Be 'prod'
        $d.iam.role_arn            | Should -Be 'arn:aws:iam::123:role/web-instance-role'
        $d.iam.attached_policies[0].name | Should -Be 'AmazonS3ReadOnlyAccess'
        $d.iam.inline_policies     | Should -Contain 'app-secrets-read'
        $d.security_groups[0].group_id            | Should -Be 'sg-0web'
        $d.security_groups[0].ingress[0].from_port | Should -Be 443
        $d.security_groups[0].ingress[0].cidrs    | Should -Contain '0.0.0.0/0'
        # -1 -> all、ポート無し -> null
        $d.security_groups[0].egress[0].protocol  | Should -Be 'all'
        $d.security_groups[0].egress[0].from_port | Should -BeNullOrEmpty
        $d.network.vpc.cidr        | Should -Be '10.0.0.0/16'
        $d.network.vpc.is_default  | Should -Be $false
        $d.network.subnet.map_public_ip | Should -Be $true
        $d.network.enis[0].groups  | Should -Contain 'sg-0web'
        $d.network.route_tables[0].routes.dest | Should -Contain '0.0.0.0/0'
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
