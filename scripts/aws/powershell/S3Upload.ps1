#Requires -Version 7
<#
.SYNOPSIS
    Upload one or more local files to Amazon S3, with per-entry overrides.

.DESCRIPTION
    Targets are resolved from -Path (single file) and / or -PathList (text
    file). Each list line is:

        <local_path> [Key=Value ...]

    Recognised keys (CLI と同じ名前、case-sensitive):
      Bucket, Prefix, Region, StorageClass, ServerSideEncryption,
      KmsKeyId, Mode (= archive|mirror)

    Resolution: per-line > CLI > config/<env>/s3upload.conf > script default.

    Modes:
      archive  S3 key = <prefix>/<filename>.<UTC yyyyMMdd-HHmmss>   (default)
      mirror   S3 key = <prefix>/<filename>                          (overwrite)

    Authentication: relies on the default AWS credential chain.
    Empty local files are skipped (idempotent).

.EXAMPLE
    .\S3Upload.ps1 -Path C:\backup\db.bak -Bucket my-backups -Prefix db/prod
.EXAMPLE
    .\S3Upload.ps1 -PathList C:\ops\s3-list.txt -Bucket my-backups
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Path,
    [string]$PathList,
    [string]$Bucket,
    [string]$Prefix,
    [string]$Region,
    [ValidateSet('STANDARD','STANDARD_IA','ONEZONE_IA','INTELLIGENT_TIERING','GLACIER','GLACIER_IR','DEEP_ARCHIVE')]
    [string]$StorageClass = 'STANDARD',
    [ValidateSet('none','AES256','aws:kms')]
    [string]$ServerSideEncryption = 'none',
    [string]$KmsKeyId,
    [ValidateSet('archive','mirror')]
    [string]$Mode = 'archive'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- フェーズ 2: 共通ライブラリ ----------------------------------------------------
$libPath = Join-Path $PSScriptRoot '..' '..' '..' 'lib' 'powershell' 'Logging.psm1'
if (-not (Test-Path $libPath)) { throw "Logging module not found at $libPath" }
Import-Module (Resolve-Path $libPath).Path -Force

$configModulePath = Join-Path $PSScriptRoot '..' '..' '..' 'lib' 'powershell' 'Config.psm1'
Import-Module (Resolve-Path $configModulePath).Path -Force
$cfg = Get-OpsConfig -Name 's3upload'
$cfgEnv = if ($env:OPS_ENV) { $env:OPS_ENV } else { 'common' }
foreach ($k in 'Bucket','Prefix','Region','StorageClass','ServerSideEncryption','KmsKeyId','Mode') {
    if (-not $PSBoundParameters.ContainsKey($k) -and $cfg.ContainsKey($k)) {
        Set-Variable -Name $k -Value ([string]$cfg[$k])
    }
}

$defaults = @{
    Bucket               = $Bucket
    Prefix               = $Prefix
    Region               = $Region
    StorageClass         = $StorageClass
    ServerSideEncryption = $ServerSideEncryption
    KmsKeyId             = $KmsKeyId
    Mode                 = $Mode
}

function ConvertFrom-S3ListLine {
    param([string]$Line, [hashtable]$Defaults)
    $trimmed = $Line.Trim()
    $tokens = $trimmed -split '\s+'
    $entry = @{}
    foreach ($k in $Defaults.Keys) { $entry[$k] = $Defaults[$k] }
    $entry.Path = $tokens[0]
    for ($i = 1; $i -lt $tokens.Count; $i++) {
        $tok = $tokens[$i]
        $eq = $tok.IndexOf('=')
        if ($eq -lt 1) { Write-OpsLog -Level WARN -Message "Invalid token: line='$trimmed' token='$tok'"; continue }
        $key = $tok.Substring(0, $eq)
        $val = $tok.Substring($eq + 1)
        if ($val -match '^"(.*)"$' -or $val -match "^'(.*)'$") { $val = $Matches[1] }
        if ($key -eq 'StorageClass' -and $val -notin 'STANDARD','STANDARD_IA','ONEZONE_IA','INTELLIGENT_TIERING','GLACIER','GLACIER_IR','DEEP_ARCHIVE') {
            Write-OpsLog -Level WARN -Message "Invalid StorageClass: line='$trimmed' value='$val'"; continue
        }
        if ($key -eq 'ServerSideEncryption' -and $val -notin 'none','AES256','aws:kms') {
            Write-OpsLog -Level WARN -Message "Invalid ServerSideEncryption: line='$trimmed' value='$val'"; continue
        }
        if ($key -eq 'Mode' -and $val -notin 'archive','mirror') {
            Write-OpsLog -Level WARN -Message "Invalid Mode: line='$trimmed' value='$val'"; continue
        }
        if ($entry.ContainsKey($key)) { $entry[$key] = $val }
        else { Write-OpsLog -Level WARN -Message "Unknown key: line='$trimmed' key='$key'" }
    }
    return $entry
}

$exitCode = 0
$status = 'unknown'
$uploaded = 0
$skipped = 0
$failed = 0

try {
    do {
        Write-OpsLog -Level INFO -Message "Config loaded: env=$cfgEnv keys=$($cfg.Count)"
        Write-OpsLog -Level INFO -Message "Args validated: path='$Path' pathList='$PathList' bucket='$Bucket' prefix='$Prefix' region='$Region' storageClass=$StorageClass sse=$ServerSideEncryption mode=$Mode"

        # --- フェーズ 3: プレチェック ---------------------------------------------
        Write-OpsLog -Level INFO -Message 'Pre-check start'

        if (-not (Get-Module -ListAvailable AWS.Tools.S3)) {
            Write-OpsLog -Level ERROR -Message 'AWS.Tools.S3 module is not installed; install with: Install-Module AWS.Tools.S3 -Scope CurrentUser'
            $exitCode = 10; $status = 'failed'; break
        }
        Import-Module AWS.Tools.S3

        $entries = [System.Collections.Generic.List[hashtable]]::new()
        if ($Path) { $entries.Add((ConvertFrom-S3ListLine -Line $Path -Defaults $defaults)) }
        if ($PathList) {
            if (-not (Test-Path -LiteralPath $PathList -PathType Leaf)) {
                Write-OpsLog -Level ERROR -Message "Path list file not found: pathList=$PathList"
                $exitCode = 2; $status = 'failed'; break
            }
            $listLines = Get-Content -LiteralPath $PathList |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -and -not $_.StartsWith('#') }
            foreach ($l in $listLines) { $entries.Add((ConvertFrom-S3ListLine -Line $l -Defaults $defaults)) }
            Write-OpsLog -Level INFO -Message "Loaded entries from list: pathList=$PathList count=$($listLines.Count)"
        }
        if ($entries.Count -eq 0) {
            Write-OpsLog -Level ERROR -Message 'Specify -Path or -PathList (or both)'
            $exitCode = 1; $status = 'failed'; break
        }

        Write-OpsLog -Level INFO -Message "Pre-check passed: entryCount=$($entries.Count)"

        # --- フェーズ 4: メイン処理 ---------------------------------------
        Write-OpsLog -Level INFO -Message 'Main start'
        $stamp = Get-OpsJstStamp

        foreach ($e in $entries) {
            if (-not $e.Bucket) {
                Write-OpsLog -Level WARN -Message "No bucket for entry, skipping: path=$($e.Path)"
                $failed++; continue
            }
            if (-not (Test-Path -LiteralPath $e.Path -PathType Leaf)) {
                Write-OpsLog -Level WARN -Message "File not found, skipping: path=$($e.Path)"
                $failed++; continue
            }
            $file = Get-Item -LiteralPath $e.Path
            if ($file.Length -eq 0) {
                Write-OpsLog -Level INFO -Message "Skip empty: file=$($file.FullName)"
                $skipped++; continue
            }

            $prefixTrim = ($e.Prefix ?? '').Trim('/')
            $key = if ($prefixTrim) { "$prefixTrim/$($file.Name)" } else { "$($file.Name)" }
            if ($e.Mode -eq 'archive') { $key = "$key.$stamp" }

            $writeArgs = @{
                BucketName    = $e.Bucket
                Key           = $key
                File          = $file.FullName
                StorageClass  = $e.StorageClass
            }
            if ($e.Region) { $writeArgs.Region = $e.Region }
            if ($e.ServerSideEncryption -and $e.ServerSideEncryption -ne 'none') {
                $writeArgs.ServerSideEncryption = $e.ServerSideEncryption
                if ($e.ServerSideEncryption -eq 'aws:kms' -and $e.KmsKeyId) {
                    $writeArgs.ServerSideEncryptionKeyManagementServiceKeyId = $e.KmsKeyId
                }
            }

            if (-not $PSCmdlet.ShouldProcess("s3://$($e.Bucket)/$key", "Upload $($file.FullName)")) { continue }

            try {
                Write-S3Object @writeArgs | Out-Null
                Write-OpsLog -Level INFO -Message "Uploaded: file=$($file.FullName) bucket=$($e.Bucket) key=$key bytes=$($file.Length) storageClass=$($e.StorageClass) sse=$($e.ServerSideEncryption) mode=$($e.Mode)"
                $uploaded++
            }
            catch {
                Write-OpsLog -Level ERROR -Message "Upload failed: file=$($file.FullName) bucket=$($e.Bucket) key=$key error=$($_.Exception.Message)"
                $failed++
            }
        }

        if ($uploaded -eq 0 -and $failed -eq 0) {
            Write-OpsLog -Level INFO -Message 'Skipped (idempotent): reason=no_uploadable_files'
            $status = 'skipped'
        }
        elseif ($failed -gt 0 -and $uploaded -eq 0) {
            $exitCode = 4; $status = 'failed'
        }
        else {
            Write-OpsLog -Level INFO -Message 'Main complete'
            $status = if ($failed -gt 0) { 'partial' } else { 'success' }
        }
    } while ($false)
}
catch {
    Write-OpsLog -Level ERROR -Message "Operation failed: error=$($_.Exception.Message)"
    if ($exitCode -eq 0) { $exitCode = 4 }
    $status = 'failed'
}
finally {
    Write-OpsLog -Level INFO -Message "Script end: status=$status exitCode=$exitCode uploaded=$uploaded skipped=$skipped failed=$failed"
}

exit $exitCode
