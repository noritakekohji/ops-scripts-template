#Requires -Version 5.1
<#
.SYNOPSIS
    リポジトリの scripts/ / config/ から指定対象だけを
    <OptRoot> 配下にローカル配備する。

.DESCRIPTION
    Bash 版 deploy_scripts.sh と同等。Windows サーバ向け。

    リストファイル形式:
      CONF, <filename>                config/default/<filename>       → <OptRoot>/config/<filename>
      SRC,  <repo_filepath>           <repo_filepath>                 → <OptRoot>/bin/<basename>
      LIB,  linux/<f>|windows/<f>     scripts_<platform>/lib/<file>  → <OptRoot>/lib/<platform>/<file>

    env が指定された場合、CONF は default を先に配備し、その後
    config/<env>/<filename> が存在すれば上書きする。

.PARAMETER PathList
    対象リストファイルのパス。

.PARAMETER OptRoot
    配備先 root ディレクトリ（既定: C:\ProgramData\ops-scripts）。
    config の opt_root_dir でも指定可（CLI 優先）。

.PARAMETER Env
    環境名（dev / staging / production 等）。
    省略時は $env:OPS_ENV、それも未設定なら config/default/ のみ参照。

.PARAMETER Backup
    上書き前に既存ファイルを <OptRoot>/.backup/ に退避する。

.EXAMPLE
    .\Deploy-Scripts.ps1 -PathList C:\ops\deploy.list -Env production -Backup

.EXAMPLE
    .\Deploy-Scripts.ps1 -PathList C:\ops\deploy.list -Env dev -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$PathList,

    [string]$OptRoot = 'C:\ProgramData\ops-scripts',

    # 環境名（OPS_ENV と同等）。省略時は $env:OPS_ENV、それも未設定なら config/default/ のみ参照
    [string]$Env = '',

    [switch]$Backup
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- lib resolution -----------------------------------------------------------
# $env:OPS_LIB takes precedence. Otherwise walk up from $PSScriptRoot looking
# for lib\Logging.psm1 (flat) or lib\windows\Logging.psm1 (OS-split layout).
# Stop at .ops-deploy-root marker so we never walk out of the install tree.
function script:Find-OpsLibDir {
    param([string]$StartDir)
    $d = $StartDir
    while ($d) {
        $flat = [IO.Path]::Combine($d, 'lib', 'Logging.psm1')
        $os   = [IO.Path]::Combine($d, 'lib', 'windows', 'Logging.psm1')
        if (Test-Path -LiteralPath $flat) { return (Split-Path -Parent $flat) }
        if (Test-Path -LiteralPath $os)   { return (Split-Path -Parent $os) }
        if (Test-Path -LiteralPath ([IO.Path]::Combine($d, '.ops-deploy-root'))) { return $null }
        $parent = Split-Path -Parent $d
        if (-not $parent -or $parent -eq $d) { break }
        $d = $parent
    }
    return $null
}
$_opsLibDir = if ($env:OPS_LIB) { $env:OPS_LIB } else { script:Find-OpsLibDir $PSScriptRoot }
if (-not $_opsLibDir -or -not (Test-Path -LiteralPath (Join-Path $_opsLibDir 'Logging.psm1'))) {
    throw "Logging.psm1 not found from $PSScriptRoot (set OPS_LIB to override)"
}
Import-Module (Join-Path $_opsLibDir 'Logging.psm1') -Force
Import-Module (Join-Path $_opsLibDir 'Config.psm1')  -Force

# -Env 未指定なら OPS_ENV 環境変数を使う
if (-not $PSBoundParameters.ContainsKey('Env') -and $env:OPS_ENV) { $Env = $env:OPS_ENV }

$cfg = Get-OpsConfig -Name 'deploy_scripts' -Env $Env
$cfgEnv = if ($Env) { $Env } else { 'default' }
$logFile  = if ($cfg.ContainsKey('LogFile'))  { [string]$cfg['LogFile'] }  else { '' }
$logLevel = if ($cfg.ContainsKey('LogLevel')) { [string]$cfg['LogLevel'] } else { 'INFO' }
Set-OpsLogConfig -LogFile $logFile -LogLevel $logLevel

if (-not $PSBoundParameters.ContainsKey('OptRoot') -and $cfg.ContainsKey('opt_root_dir')) {
    $OptRoot = [string]$cfg['opt_root_dir']
}
if (-not $PSBoundParameters.ContainsKey('Backup') -and $cfg.ContainsKey('Backup')) {
    if ([System.Convert]::ToBoolean($cfg['Backup'])) { $Backup = $true }
}
if (-not $PSBoundParameters.ContainsKey('PathList') -and $cfg.ContainsKey('PathList')) {
    $PathList = [string]$cfg['PathList']
    if ($PathList -and -not [System.IO.Path]::IsPathRooted($PathList)) {
        $PathList = Join-Path (Get-OpsRepoRoot) $PathList
    }
}

$exitCode = 0
$status = 'unknown'
$script:deployed = 0
$script:unchanged = 0
$script:backedUp = 0
$script:failed = 0

$repoRoot = (Resolve-Path ([IO.Path]::Combine($PSScriptRoot, '..', '..'))).Path

# ----------------------------------------------------------------------------
# ヘルパ
# ----------------------------------------------------------------------------

function Get-FileSha256 { param([string]$Path) (Get-FileHash -Algorithm SHA256 -Path $Path).Hash }

function Copy-OpsFile {
    param([string]$Src, [string]$Dst)

    if (-not (Test-Path -LiteralPath $Src -PathType Leaf)) {
        Write-OpsLog -Level WARN -Message "Source not found, skipping: src=$Src"
        $script:failed++
        return $false
    }

    if (Test-Path -LiteralPath $Dst) {
        if ((Get-FileSha256 $Src) -eq (Get-FileSha256 $Dst)) {
            Write-OpsLog -Level INFO -Message "Unchanged: dst=$Dst"
            $script:unchanged++
            return $true
        }
        if ($Backup) {
            $stamp = Get-OpsJstStamp
            $backupDir = Join-Path $OptRoot '.backup'
            $backupPath = Join-Path $backupDir "$([System.IO.Path]::GetFileName($Dst)).$stamp"
            if ($PSCmdlet.ShouldProcess($Dst, "Backup to $backupPath")) {
                New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
                Copy-Item -LiteralPath $Dst -Destination $backupPath -Force
                Write-OpsLog -Level INFO -Message "Backed up: from=$Dst to=$backupPath"
            }
            $script:backedUp++
        }
        else {
            Write-OpsLog -Level WARN -Message "Overwriting without backup: dst=$Dst"
        }
    }

    if (-not $PSCmdlet.ShouldProcess($Dst, "Deploy from $Src")) {
        $script:deployed++
        return $true
    }

    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $Dst) -Force | Out-Null
        Copy-Item -LiteralPath $Src -Destination $Dst -Force
        Write-OpsLog -Level INFO -Message "Deployed: src=$Src dst=$Dst"
        $script:deployed++
        return $true
    }
    catch {
        Write-OpsLog -Level ERROR -Message "Copy failed: src=$Src dst=$Dst error=$($_.Exception.Message)"
        $script:failed++
        return $false
    }
}

# CONF エントリ:
#   Env 未指定 → config/default/<filename> → <OptRoot>/config/<filename>
#   Env 指定時 → config/<Env>/<filename>   → <OptRoot>/config/<filename>
function Invoke-OpsDeployConf {
    param([string]$FilePath)
    $filename = Split-Path -Leaf $FilePath
    $dst = [IO.Path]::Combine($OptRoot, 'config', $filename)

    $configDir = if ($Env) { [IO.Path]::Combine($repoRoot, 'config', $Env) } else { [IO.Path]::Combine($repoRoot, 'config', 'default') }
    $src = Join-Path $configDir $FilePath

    if (Test-Path -LiteralPath $src -PathType Leaf) {
        Copy-OpsFile -Src $src -Dst $dst | Out-Null
    }
    else {
        Write-OpsLog -Level WARN -Message "Config not found: src=$src"
        $script:failed++
    }
}

# SRC エントリ: <repo_filepath> → <OptRoot>/bin/<basename>
function Invoke-OpsDeploySrc {
    param([string]$FilePath)
    $filename = Split-Path -Leaf $FilePath
    $src = [IO.Path]::Combine($repoRoot, $FilePath)
    $dst = [IO.Path]::Combine($OptRoot, 'bin', $filename)
    Copy-OpsFile -Src $src -Dst $dst | Out-Null
}

# LIB エントリ: linux/<file> or windows/<file> → <OptRoot>/lib/<platform>/<file>
function Invoke-OpsDeployLib {
    param([string]$FilePath)
    $parts    = $FilePath -split '[/\\]'
    $platform = $parts[0]
    $filename = $parts[-1]
    $src = [IO.Path]::Combine($repoRoot, "scripts_$platform", 'lib', $filename)
    $dst = [IO.Path]::Combine($OptRoot, 'lib', $FilePath)
    Copy-OpsFile -Src $src -Dst $dst | Out-Null
}

# ----------------------------------------------------------------------------
# メインフロー
# ----------------------------------------------------------------------------
try {
    do {
        Write-OpsLog -Level INFO -Message "Config loaded: env=$cfgEnv keys=$($cfg.Count)"
        Write-OpsLog -Level INFO -Message "Args validated: pathList='$PathList' optRoot='$OptRoot' env=$cfgEnv backup=$Backup whatIf=$($PSCmdlet.MyInvocation.BoundParameters.ContainsKey('WhatIf'))"

        # --- プレチェック ---
        Write-OpsLog -Level INFO -Message 'Pre-check start'

        if (-not $PathList) {
            Write-OpsLog -Level ERROR -Message 'Specify -PathList or set PathList in deploy_scripts.conf'
            $exitCode = 1; $status = 'failed'; break
        }
        if (-not (Test-Path -LiteralPath $PathList -PathType Leaf)) {
            Write-OpsLog -Level ERROR -Message "List file not found: $PathList"
            $exitCode = 2; $status = 'failed'; break
        }

        if ($PSCmdlet.ShouldProcess($OptRoot, 'Ensure OptRoot exists and is writable')) {
            try {
                New-Item -ItemType Directory -Path $OptRoot -Force | Out-Null
                $probe = Join-Path $OptRoot ".probe.$([Guid]::NewGuid().ToString('N'))"
                Set-Content -LiteralPath $probe -Value 'x'
                Remove-Item -LiteralPath $probe -Force
            }
            catch {
                Write-OpsLog -Level ERROR -Message "Cannot write to opt_root_dir: $OptRoot error=$($_.Exception.Message)"
                $exitCode = 5; $status = 'failed'; break
            }
        }

        # リスト解析
        $entryTypes = [System.Collections.Generic.List[string]]::new()
        $entryPaths = [System.Collections.Generic.List[string]]::new()

        $lines = Get-Content -LiteralPath $PathList -Encoding UTF8 |
            ForEach-Object { ($_ -replace '#.*$', '').Trim() } |
            Where-Object { $_ }

        foreach ($line in $lines) {
            $comma = $line.IndexOf(',')
            if ($comma -lt 1) {
                Write-OpsLog -Level WARN -Message "Invalid format, skipping: line='$line'"
                continue
            }
            $t = $line.Substring(0, $comma).Trim().ToUpper()
            $p = $line.Substring($comma + 1).Trim()

            if ($t -in 'CONF', 'SRC', 'LIB') {
                $entryTypes.Add($t)
                $entryPaths.Add($p)
            }
            else {
                Write-OpsLog -Level WARN -Message "Unknown type, skipping: type=$t line='$line'"
            }
        }

        if ($entryTypes.Count -eq 0) {
            Write-OpsLog -Level WARN -Message 'No entries to deploy (skipped)'
            $status = 'skipped'; break
        }
        Write-OpsLog -Level INFO -Message "Pre-check passed: entryCount=$($entryTypes.Count)"

        # --- メイン処理 ---
        Write-OpsLog -Level INFO -Message 'Main start'

        for ($i = 0; $i -lt $entryTypes.Count; $i++) {
            switch ($entryTypes[$i]) {
                'CONF' { Invoke-OpsDeployConf -FilePath $entryPaths[$i] }
                'SRC'  { Invoke-OpsDeploySrc  -FilePath $entryPaths[$i] }
                'LIB'  { Invoke-OpsDeployLib  -FilePath $entryPaths[$i] }
            }
        }

        # --- マーカー作成 ---
        # 配備が 1 件でも成功（または unchanged）したら、配備ルートに
        # .ops-deploy-root マーカーを置く。配備先スクリプトの lib / config
        # 解決はこのマーカーで「配備ルートをどこで止めるか」を判定する。
        if (-not $PSCmdlet.MyInvocation.BoundParameters.ContainsKey('WhatIf') -and
            ($script:deployed -gt 0 -or $script:unchanged -gt 0)) {
            $marker = Join-Path $OptRoot '.ops-deploy-root'
            $jst = (Get-Date).ToUniversalTime().AddHours(9).ToString('yyyy-MM-ddTHH:mm:ss')
            try {
                @(
                    "deployed_at=$jst"
                    "env=$cfgEnv"
                    "deployed_by=$env:USERNAME"
                    "host=$env:COMPUTERNAME"
                    "list_file=$PathList"
                ) | Set-Content -LiteralPath $marker -Encoding UTF8
                Write-OpsLog -Level INFO -Message "Deploy-root marker: $marker"
            }
            catch {
                Write-OpsLog -Level WARN -Message "Could not write deploy-root marker: $marker error=$($_.Exception.Message)"
            }
        }

        if ($script:failed -gt 0 -and $script:deployed -eq 0 -and $script:unchanged -eq 0) {
            Write-OpsLog -Level ERROR -Message 'All entries failed'
            $exitCode = 4; $status = 'failed'; break
        }
        elseif ($script:failed -gt 0) {
            Write-OpsLog -Level INFO -Message 'Main complete (with failures)'
            $status = 'partial'
        }
        else {
            Write-OpsLog -Level INFO -Message 'Main complete'
            $status = 'success'
        }
    } while ($false)
}
catch {
    Write-OpsLog -Level ERROR -Message "Operation failed: error=$($_.Exception.Message)"
    if ($exitCode -eq 0) { $exitCode = 4 }
    $status = 'failed'
}
finally {
    Write-OpsLog -Level INFO -Message "Script end: status=$status exitCode=$exitCode deployed=$($script:deployed) unchanged=$($script:unchanged) backedUp=$($script:backedUp) failed=$($script:failed)"
}

exit $exitCode
