#Requires -Version 5.1
<#
.SYNOPSIS
    現在の EC2 インスタンスの AWS コンテキスト（IAM ロール / Security Group /
    VPC・Subnet・ENI・Route / メタデータ・タグ）を IMDSv2 + AWS CLI で収集して
    JSON 出力する。Linux 版 aws_instance_audit.sh と同等。

.DESCRIPTION
    tools/ 配下の自己完結スクリプト（lib 非依存）。EC2 インスタンス上で実行する
    ことを前提とし、IMDSv2 で自分のメタデータを取得し、aws CLI で詳細を引く。

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
                10 aws CLI / python3 不在 / 20 認証・権限エラー
#>
[CmdletBinding()]
param(
    [string]$Category = 'all',
    [string]$OutputPath = '',
    [string]$HtmlReport = '',
    [string]$Region = ''
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

# ── 前提チェック ───────────────────────────────────────────────
$awsCmd = Get-Command aws -ErrorAction SilentlyContinue
if (-not $awsCmd) { Write-Log 'ERROR' 'aws CLI not found in PATH'; exit 10 }

$pyCmd = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $pyCmd) { $pyCmd = Get-Command python -ErrorAction SilentlyContinue }
if (-not $pyCmd) { Write-Log 'ERROR' 'python3 not found (required to assemble JSON)'; exit 10 }

# ── IMDSv2 ─────────────────────────────────────────────────────
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

# ── 一時ディレクトリ ───────────────────────────────────────────
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aws-audit-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function Invoke-AwsJson {
    param([string[]]$AwsArgs, [string]$OutFile)
    try {
        $raw = & aws @AwsArgs --output json 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) {
            $raw | Out-File -LiteralPath $OutFile -Encoding utf8
        } else {
            'null' | Out-File -LiteralPath $OutFile -Encoding utf8
            Write-Log 'WARN' "aws $($AwsArgs -join ' ') failed (exit $LASTEXITCODE)"
        }
    } catch {
        'null' | Out-File -LiteralPath $OutFile -Encoding utf8
        Write-Log 'WARN' "aws $($AwsArgs -join ' ') error: $($_.Exception.Message)"
    }
}

try {
    # 認証確認
    & aws sts get-caller-identity --output json > (Join-Path $tmp 'caller.json') 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Log 'ERROR' 'AWS auth failed (sts get-caller-identity)'
        exit 20
    }

    foreach ($f in 'iam_attached','iam_inline','iam_role','sg','vpc','subnet','eni','rt','tags') {
        'null' | Out-File -LiteralPath (Join-Path $tmp "$f.json") -Encoding utf8
    }

    if ((Want 'iam') -and $iamRole) {
        Write-Log 'INFO' "Collecting IAM role/policies: $iamRole"
        Invoke-AwsJson @('iam','list-attached-role-policies','--role-name',$iamRole) (Join-Path $tmp 'iam_attached.json')
        Invoke-AwsJson @('iam','list-role-policies','--role-name',$iamRole)          (Join-Path $tmp 'iam_inline.json')
        Invoke-AwsJson @('iam','get-role','--role-name',$iamRole)                    (Join-Path $tmp 'iam_role.json')
    }

    if (Want 'sg') {
        Write-Log 'INFO' 'Collecting security groups'
        if ($sgIdsRaw) {
            $sgIds = $sgIdsRaw -split "`n" | Where-Object { $_ }
            Invoke-AwsJson (@('ec2','describe-security-groups','--group-ids') + $sgIds) (Join-Path $tmp 'sg.json')
        }
    }

    if (Want 'network') {
        Write-Log 'INFO' 'Collecting network (vpc/subnet/eni/route)'
        if ($vpcId)    { Invoke-AwsJson @('ec2','describe-vpcs','--vpc-ids',$vpcId)          (Join-Path $tmp 'vpc.json') }
        if ($subnetId) { Invoke-AwsJson @('ec2','describe-subnets','--subnet-ids',$subnetId) (Join-Path $tmp 'subnet.json') }
        if ($instanceId) {
            Invoke-AwsJson @('ec2','describe-network-interfaces','--filters',"Name=attachment.instance-id,Values=$instanceId") (Join-Path $tmp 'eni.json')
        }
        if ($vpcId) {
            Invoke-AwsJson @('ec2','describe-route-tables','--filters',"Name=vpc-id,Values=$vpcId") (Join-Path $tmp 'rt.json')
        }
    }

    if ((Want 'instance') -and $instanceId) {
        Invoke-AwsJson @('ec2','describe-tags','--filters',"Name=resource-id,Values=$instanceId") (Join-Path $tmp 'tags.json')
    }

    # ── python3 で JSON 束ね（Linux 版と同じアセンブラを使う）──────
    $assembler = Join-Path $scriptDir '_assemble_json.py'
    $env:TMPD       = $tmp
    $env:INST_ID    = $instanceId
    $env:INST_TYPE  = $instanceType
    $env:AMI        = $amiId
    $env:AZ         = $az
    $env:REGION     = $Region
    $env:LOCAL_IP   = $localIp
    $env:PUBLIC_IP  = $publicIp
    $env:VPC_ID     = $vpcId
    $env:SUBNET_ID  = $subnetId
    $env:IAM_ROLE   = $iamRole
    $env:CATS       = $Category
    $env:HOSTNAME_S = $env:COMPUTERNAME
    $env:OUT        = $OutputPath

    & $pyCmd.Source $assembler
    if ($LASTEXITCODE -ne 0) { Write-Log 'ERROR' 'Failed to assemble JSON output'; exit 5 }
    Write-Log 'INFO' "JSON written: $OutputPath"

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
    if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
