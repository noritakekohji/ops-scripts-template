#Requires -Version 5.1
<#
.SYNOPSIS
    現在の EC2 インスタンスの AWS コンテキスト（IAM ロール / Security Group /
    VPC・Subnet・ENI・Route / メタデータ・タグ）を IMDSv2 + AWS CLI で収集して
    JSON 出力する。Linux 版 aws_instance_audit.sh と同等。

.DESCRIPTION
    tools/ 配下の自己完結スクリプト（lib 非依存）。EC2 インスタンス上で実行する
    ことを前提とし、IMDSv2 で自分のメタデータを取得し、aws CLI で詳細を引く。
    JSON 組み立ては PowerShell ネイティブ（ConvertTo-Json）で行うため python3 は
    不要。HTML レポート（-HtmlReport）を生成するときだけ python3 が必要。

.PARAMETER Category
    収集カテゴリ。all / instance / iam / sg / network（カンマ区切り可）。既定: all

.PARAMETER OutputPath
    JSON 出力先。既定: aws_audit_<instance-id>_<ts>.json

.PARAMETER HtmlReport
    HTML レポート出力先（python3 が必要）。

.PARAMETER Region
    リージョン上書き（既定: IMDS から自動取得）。

.EXAMPLE
    .\Get-AwsInstanceAudit.ps1
    .\Get-AwsInstanceAudit.ps1 -Category iam,sg -OutputPath audit.json -HtmlReport audit.html

.NOTES
    終了コード: 0 成功 / 1 引数不正 / 2 IMDS 到達不可 / 5 出力失敗 /
                10 aws CLI 不在（HTML 指定時は python3 不在）/ 20 認証・権限エラー
#>
[CmdletBinding()]
param(
    [string]$Category = 'all',
    [string]$OutputPath = '',
    [string]$HtmlReport = '',
    [string]$Region = '',
    [string]$FromJson = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ImdsBase = 'http://169.254.169.254/latest'
$TokenTtl = 21600
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$renderPy  = Join-Path $scriptDir 'render_report.py'

function Write-Log {
    param([string]$Level, [string]$Message)
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    [Console]::Error.WriteLine("[$ts] [$Level] $Message")
}

function Want([string]$cat) {
    if ($Category -eq 'all') { return $true }
    return ($Category -split ',' | ForEach-Object { $_.Trim() }) -contains $cat
}

# StrictMode 下で「存在しないプロパティ」へのアクセスは例外になるため、
# aws CLI の JSON から省略されうるフィールドはこのヘルパー経由で安全に取り出す。
function Get-Prop($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $pp = $obj.PSObject.Properties[$name]
    if ($pp) { return $pp.Value }
    return $null
}

# ── FromJson: 保存済み JSON からレポートを再生成（収集・aws CLI 不要）──
if ($FromJson) {
    if (-not (Test-Path -LiteralPath $FromJson)) {
        Write-Log 'ERROR' "FromJson file not found: $FromJson"
        exit 2
    }
    try {
        $fj = Get-Content -LiteralPath $FromJson -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log 'ERROR' "Failed to parse JSON: $FromJson"
        exit 1
    }
    if (-not (Get-Prop $fj 'meta')) {
        Write-Log 'ERROR' 'Invalid structure: top-level "meta" object not found'
        exit 1
    }

    # HTML レポート（python3 + render_report.py、入力は FromJson 自身）
    if ($HtmlReport) {
        $pyCmd = Get-Command python3 -ErrorAction SilentlyContinue
        if (-not $pyCmd) { $pyCmd = Get-Command python -ErrorAction SilentlyContinue }
        if (-not $pyCmd) { Write-Log 'ERROR' 'python3 not found (required for HTML report)'; exit 10 }
        if (-not (Test-Path $renderPy)) { Write-Log 'ERROR' "render_report.py not found: $renderPy"; exit 5 }
        & $pyCmd.Source $renderPy $FromJson $HtmlReport
        if ($LASTEXITCODE -ne 0) { Write-Log 'ERROR' 'HTML render failed'; exit 5 }
        Write-Log 'INFO' "HTML report: $HtmlReport"
    }

    # OutputPath 指定時は JSON をコピー
    if ($OutputPath) {
        $outDir = Split-Path -Parent $OutputPath
        if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
        Copy-Item -LiteralPath $FromJson -Destination $OutputPath -Force
        Write-Log 'INFO' "JSON copied: $OutputPath"
    }

    $m = Get-Prop $fj 'meta'
    Write-Host ''
    Write-Host '  AWS instance audit (from JSON)'
    Write-Host "  instance_id : $([string](Get-Prop $m 'instance_id'))"
    Write-Host "  collected_at: $([string](Get-Prop $m 'collected_at'))"
    if ($OutputPath) { Write-Host "  JSON: $OutputPath" }
    if ($HtmlReport) { Write-Host "  HTML: $HtmlReport" }
    Write-Host ''
    exit 0
}

# ── 前提チェック ───────────────────────────────────────────────
$awsCmd = Get-Command aws -ErrorAction SilentlyContinue
if (-not $awsCmd) { Write-Log 'ERROR' 'aws CLI not found in PATH'; exit 10 }

# python3 は HTML レポート生成にのみ使用する。JSON 出力だけなら不要。
$pyCmd = $null
if ($HtmlReport) {
    $pyCmd = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $pyCmd) { $pyCmd = Get-Command python -ErrorAction SilentlyContinue }
    if (-not $pyCmd) { Write-Log 'ERROR' 'python3 not found (required for HTML report)'; exit 10 }
}

# ── AWS CLI 挙動の安定化 ───────────────────────────────────────
# AWS_PAGER='' : v2 のページャー入力待ちで固まるのを防ぐ
# タイムアウト / リトライ抑制で到達不可エンドポイント時の長時間ハングを防ぐ
$env:AWS_PAGER = ''
if (-not $env:AWS_MAX_ATTEMPTS) { $env:AWS_MAX_ATTEMPTS = '2' }
if (-not $env:AWS_RETRY_MODE)   { $env:AWS_RETRY_MODE   = 'standard' }
$AwsTimeoutOpts = @('--cli-connect-timeout', '5', '--cli-read-timeout', '30')

# ── IMDSv2 ─────────────────────────────────────────────────────
# IMDS はリンクローカル (169.254.169.254)。システムプロキシ経由になると
# 到達できず長時間ブロックするため、IMDS アクセスの間だけ既定プロキシを無効化する。
$script:savedProxy = $null
try { $script:savedProxy = [System.Net.WebRequest]::DefaultWebProxy } catch {}
try { [System.Net.WebRequest]::DefaultWebProxy = $null } catch {}

function Get-ImdsToken {
    try {
        return Invoke-RestMethod -Method Put -Uri "$ImdsBase/api/token" `
            -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = "$TokenTtl" } `
            -TimeoutSec 3 -ErrorAction Stop
    } catch { return $null }
}

$token = Get-ImdsToken
if (-not $token) {
    Write-Log 'ERROR' "Cannot reach IMDS ($ImdsBase). Not on an EC2 instance, or IMDS disabled."
    try { [System.Net.WebRequest]::DefaultWebProxy = $script:savedProxy } catch {}
    exit 2
}

function Get-Imds([string]$path) {
    try {
        return (Invoke-RestMethod -Method Get -Uri "$ImdsBase/meta-data/$path" `
            -Headers @{ 'X-aws-ec2-metadata-token' = $token } `
            -TimeoutSec 3 -ErrorAction Stop)
    } catch { return '' }
}

# ── メタデータ収集 ─────────────────────────────────────────────
$instanceId   = [string](Get-Imds 'instance-id')
$instanceType = [string](Get-Imds 'instance-type')
$amiId        = [string](Get-Imds 'ami-id')
$az           = [string](Get-Imds 'placement/availability-zone')
$localIp      = [string](Get-Imds 'local-ipv4')
$publicIp     = [string](Get-Imds 'public-ipv4')
$mac          = [string](Get-Imds 'mac')
if (-not $Region) { $Region = [string](Get-Imds 'placement/region') }
if (-not $Region -and $az) { $Region = $az.Substring(0, $az.Length - 1) }

$vpcId = ''; $subnetId = ''; $sgIdsRaw = ''
if ($mac) {
    $vpcId    = [string](Get-Imds "network/interfaces/macs/$mac/vpc-id")
    $subnetId = [string](Get-Imds "network/interfaces/macs/$mac/subnet-id")
    $sgIdsRaw = [string](Get-Imds "network/interfaces/macs/$mac/security-group-ids")
}
$iamRole = [string](Get-Imds 'iam/security-credentials/')

Write-Log 'INFO' "Instance: id=$instanceId type=$instanceType region=$Region vpc=$vpcId role=$(if($iamRole){$iamRole}else{'<none>'})"

$env:AWS_DEFAULT_REGION = $Region

if (-not $OutputPath) {
    $ts = (Get-Date).ToUniversalTime().AddHours(9).ToString('yyyyMMdd-HHmmss')
    $idPart = if ($instanceId) { $instanceId } else { 'unknown' }
    $OutputPath = "aws_audit_${idPart}_${ts}.json"
}

# ── aws CLI 呼び出し（生 JSON を ConvertFrom-Json で解析して返す）──
function Invoke-AwsObj {
    param([string[]]$AwsArgs)
    try {
        $raw = & aws @AwsArgs @AwsTimeoutOpts --output json 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) {
            return ($raw | ConvertFrom-Json)
        }
        Write-Log 'WARN' "aws $($AwsArgs -join ' ') failed (exit $LASTEXITCODE)"
        return $null
    } catch {
        Write-Log 'WARN' "aws $($AwsArgs -join ' ') error: $($_.Exception.Message)"
        return $null
    }
}

# SG の IpPermissions / IpPermissionsEgress を共通スキーマに正規化する。
# 戻り値はカンマ演算子 (, $out) で配列性を保ち、単一要素のアンロールを防ぐ。
function Convert-Perms($perms) {
    $out = @()
    foreach ($p in @($perms)) {
        if ($null -eq $p) { continue }
        $proto = [string](Get-Prop $p 'IpProtocol')
        if ($proto -eq '-1') { $proto = 'all' }

        $cidrs = @()
        foreach ($r in @(Get-Prop $p 'IpRanges'))    { $c = [string](Get-Prop $r 'CidrIp');    if ($c) { $cidrs += $c } }
        foreach ($r in @(Get-Prop $p 'Ipv6Ranges'))  { $c = [string](Get-Prop $r 'CidrIpv6');  if ($c) { $cidrs += $c } }

        $sgRefs = @()
        foreach ($g in @(Get-Prop $p 'UserIdGroupPairs')) { $s = [string](Get-Prop $g 'GroupId'); if ($s) { $sgRefs += $s } }

        $out += ,([ordered]@{
            protocol  = $proto
            from_port = Get-Prop $p 'FromPort'
            to_port   = Get-Prop $p 'ToPort'
            cidrs     = @($cidrs)
            sg_refs   = @($sgRefs)
        })
    }
    return ,@($out)
}

try {
    # 認証確認（生データは使わず、戻りコードのみ見る）
    & aws sts get-caller-identity @AwsTimeoutOpts --output json > $null 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log 'ERROR' 'AWS auth failed (sts get-caller-identity)'
        exit 20
    }

    $nowJst = (Get-Date).ToUniversalTime().AddHours(9).ToString('yyyy-MM-dd HH:mm:ss')
    $result = [ordered]@{
        meta = [ordered]@{
            tool         = 'aws_instance_audit'
            collected_at = $nowJst
            hostname     = [string]$env:COMPUTERNAME
            region       = $Region
            instance_id  = $instanceId
            categories   = if ($Category) { $Category } else { 'all' }
        }
    }

    # ── instance + tags ────────────────────────────────────────
    if (Want 'instance') {
        $tags = [ordered]@{}
        if ($instanceId) {
            $td = Invoke-AwsObj @('ec2','describe-tags','--filters',"Name=resource-id,Values=$instanceId")
            foreach ($t in @(Get-Prop $td 'Tags')) {
                $k = [string](Get-Prop $t 'Key')
                if ($k) { $tags[$k] = [string](Get-Prop $t 'Value') }
            }
        }
        $result.instance = [ordered]@{
            instance_id       = $instanceId
            instance_type     = $instanceType
            ami_id            = $amiId
            availability_zone = $az
            region            = $Region
            private_ip        = $localIp
            public_ip         = $publicIp
            vpc_id            = $vpcId
            subnet_id         = $subnetId
            tags              = $tags
        }
    }

    # ── IAM ────────────────────────────────────────────────────
    if (Want 'iam') {
        $iam = [ordered]@{
            role_name         = $iamRole
            role_arn          = ''
            attached_policies = @()
            inline_policies   = @()
        }
        if ($iamRole) {
            Write-Log 'INFO' "Collecting IAM role/policies: $iamRole"
            $rj = Invoke-AwsObj @('iam','get-role','--role-name',$iamRole)
            $role = Get-Prop $rj 'Role'
            if ($role) {
                $iam.role_arn     = [string](Get-Prop $role 'Arn')
                $iam.create_date  = [string](Get-Prop $role 'CreateDate')
            }
            $aj = Invoke-AwsObj @('iam','list-attached-role-policies','--role-name',$iamRole)
            $att = @()
            foreach ($p in @(Get-Prop $aj 'AttachedPolicies')) {
                $att += ,([ordered]@{ name = [string](Get-Prop $p 'PolicyName'); arn = [string](Get-Prop $p 'PolicyArn') })
            }
            $iam.attached_policies = @($att)
            $ij = Invoke-AwsObj @('iam','list-role-policies','--role-name',$iamRole)
            $iam.inline_policies   = @(@(Get-Prop $ij 'PolicyNames') | Where-Object { $_ } | ForEach-Object { [string]$_ })
        }
        $result.iam = $iam
    }

    # ── Security Groups ────────────────────────────────────────
    if (Want 'sg') {
        $sgs = @()
        if ($sgIdsRaw) {
            Write-Log 'INFO' 'Collecting security groups'
            $sgIds = @($sgIdsRaw -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $sj = Invoke-AwsObj (@('ec2','describe-security-groups','--group-ids') + $sgIds)
            foreach ($g in @(Get-Prop $sj 'SecurityGroups')) {
                $sgs += ,([ordered]@{
                    group_id    = [string](Get-Prop $g 'GroupId')
                    group_name  = [string](Get-Prop $g 'GroupName')
                    description = [string](Get-Prop $g 'Description')
                    vpc_id      = [string](Get-Prop $g 'VpcId')
                    ingress     = Convert-Perms (Get-Prop $g 'IpPermissions')
                    egress      = Convert-Perms (Get-Prop $g 'IpPermissionsEgress')
                })
            }
        }
        $result.security_groups = @($sgs)
    }

    # ── Network ────────────────────────────────────────────────
    if (Want 'network') {
        Write-Log 'INFO' 'Collecting network (vpc/subnet/eni/route)'
        $net = [ordered]@{}

        if ($vpcId) {
            $vj = Invoke-AwsObj @('ec2','describe-vpcs','--vpc-ids',$vpcId)
            $v = @(Get-Prop $vj 'Vpcs') | Select-Object -First 1
            if ($v) {
                $net.vpc = [ordered]@{
                    vpc_id     = [string](Get-Prop $v 'VpcId')
                    cidr       = [string](Get-Prop $v 'CidrBlock')
                    is_default = [bool](Get-Prop $v 'IsDefault')
                }
            }
        }
        if ($subnetId) {
            $sj = Invoke-AwsObj @('ec2','describe-subnets','--subnet-ids',$subnetId)
            $s = @(Get-Prop $sj 'Subnets') | Select-Object -First 1
            if ($s) {
                $net.subnet = [ordered]@{
                    subnet_id     = [string](Get-Prop $s 'SubnetId')
                    cidr          = [string](Get-Prop $s 'CidrBlock')
                    az            = [string](Get-Prop $s 'AvailabilityZone')
                    map_public_ip = [bool](Get-Prop $s 'MapPublicIpOnLaunch')
                }
            }
        }
        if ($instanceId) {
            $ej = Invoke-AwsObj @('ec2','describe-network-interfaces','--filters',"Name=attachment.instance-id,Values=$instanceId")
            $enis = @()
            foreach ($e in @(Get-Prop $ej 'NetworkInterfaces')) {
                $groups = @()
                foreach ($g in @(Get-Prop $e 'Groups')) { $gid = [string](Get-Prop $g 'GroupId'); if ($gid) { $groups += $gid } }
                $enis += ,([ordered]@{
                    eni_id      = [string](Get-Prop $e 'NetworkInterfaceId')
                    private_ip  = [string](Get-Prop $e 'PrivateIpAddress')
                    subnet_id   = [string](Get-Prop $e 'SubnetId')
                    description = [string](Get-Prop $e 'Description')
                    groups      = @($groups)
                })
            }
            $net.enis = @($enis)
        }
        if ($vpcId) {
            $rj = Invoke-AwsObj @('ec2','describe-route-tables','--filters',"Name=vpc-id,Values=$vpcId")
            $rts = @()
            foreach ($r in @(Get-Prop $rj 'RouteTables')) {
                $routes = @()
                foreach ($rt in @(Get-Prop $r 'Routes')) {
                    $dest = [string](Get-Prop $rt 'DestinationCidrBlock')
                    if (-not $dest) { $dest = [string](Get-Prop $rt 'DestinationPrefixListId') }
                    $target = ''
                    foreach ($k in 'GatewayId','NatGatewayId','NetworkInterfaceId','TransitGatewayId') {
                        $tv = [string](Get-Prop $rt $k)
                        if ($tv) { $target = $tv; break }
                    }
                    $routes += ,([ordered]@{ dest = $dest; target = $target })
                }
                $rts += ,([ordered]@{ route_table_id = [string](Get-Prop $r 'RouteTableId'); routes = @($routes) })
            }
            $net.route_tables = @($rts)
        }
        $result.network = $net
    }

    # ── JSON 出力（PowerShell ネイティブ）──────────────────────
    $outDir = Split-Path -Parent $OutputPath
    if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $json = $result | ConvertTo-Json -Depth 12
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutputPath, $json, $utf8NoBom)
    Write-Log 'INFO' "JSON written: $OutputPath"

    # ── HTML レポート（python3 + render_report.py）─────────────
    if ($HtmlReport) {
        if (Test-Path $renderPy) {
            & $pyCmd.Source $renderPy $OutputPath $HtmlReport
            if ($LASTEXITCODE -ne 0) { Write-Log 'ERROR' 'HTML render failed'; exit 5 }
            Write-Log 'INFO' "HTML report: $HtmlReport"
        } else {
            Write-Log 'ERROR' "render_report.py not found: $renderPy"; exit 5
        }
    }

    Write-Host ''
    Write-Host '  AWS instance audit complete'
    Write-Host "  JSON: $OutputPath"
    if ($HtmlReport) { Write-Host "  HTML: $HtmlReport" }
    Write-Host ''
    exit 0
}
finally {
    # IMDS 用に無効化した既定プロキシを元に戻す
    try { [System.Net.WebRequest]::DefaultWebProxy = $script:savedProxy } catch {}
}
