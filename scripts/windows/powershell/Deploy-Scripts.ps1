#Requires -Version 7
<#
.SYNOPSIS
    リポジトリの scripts / config / lib / tests から指定対象だけを
    <OptRoot> 配下にローカル配備する。

.DESCRIPTION
    Bash 版 deploy_scripts.sh と同等。Windows サーバ向け（.ps1 を中心に
    配備、lib/powershell/ を必須付帯）。

    配備時にスクリプト内の lib import パスを
        Join-Path $PSScriptRoot '..' '..' '..' 'lib' ...
    から
        Join-Path $PSScriptRoot '..' 'lib' ...
    へ書換える（フラット配置に追従）。

    レイアウト:
      <OptRoot>/script/<File>.ps1
      <OptRoot>/conf/<file>.conf   ← default を基底に env で上書き
      <OptRoot>/tests/<File>.Tests.ps1
      <OptRoot>/lib/powershell/<File>.psm1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$PathList,

    [string]$OptRoot = 'C:\ProgramData\ops-scripts',

    # 環境名（OPS_ENV と同等）。省略時は $env:OPS_ENV、それも未設定なら config/default/ のみ参照
    [string]$Env = '',

    [ValidateSet('script-only','with-config','with-tests','all')]
    [string]$Mode = 'with-config',

    [switch]$Backup
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- フェーズ 2: 共通ライブラリ ---
$libPath = Join-Path $PSScriptRoot '..' '..' '..' 'lib' 'powershell' 'Logging.psm1'
if (-not (Test-Path $libPath)) { throw "Logging module not found at $libPath" }
Import-Module (Resolve-Path $libPath).Path -Force

$configModulePath = Join-Path $PSScriptRoot '..' '..' '..' 'lib' 'powershell' 'Config.psm1'
Import-Module (Resolve-Path $configModulePath).Path -Force

# -Env 未指定なら OPS_ENV 環境変数を使う
if (-not $PSBoundParameters.ContainsKey('Env') -and $env:OPS_ENV) { $Env = $env:OPS_ENV }

$cfg = Get-OpsConfig -Name 'deploy_scripts' -Env $Env
$cfgEnv = if ($Env) { $Env } else { 'default' }

if (-not $PSBoundParameters.ContainsKey('OptRoot') -and $cfg.ContainsKey('OptRoot')) { $OptRoot = [string]$cfg['OptRoot'] }
if (-not $PSBoundParameters.ContainsKey('Mode')    -and $cfg.ContainsKey('Mode'))    { $Mode    = [string]$cfg['Mode'] }
if (-not $PSBoundParameters.ContainsKey('Backup')  -and $cfg.ContainsKey('Backup')) {
    if ([System.Convert]::ToBoolean($cfg['Backup'])) { $Backup = [switch]::Present }
}
# CLI で -PathList 未指定なら config の PathList を採用。相対パスは repo root 起点で絶対化。
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

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path

# ----------------------------------------------------------------------------
# ヘルパ
# ----------------------------------------------------------------------------

function Get-FileSha256 { param([string]$Path) (Get-FileHash -Algorithm SHA256 -Path $Path).Hash }

function Copy-OpsFile {
    # 単一ファイルを冪等にコピー
    param([string]$Src, [string]$Dst)

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

function Update-OpsLibImport {
    # 配備先の PS スクリプトの lib import パスを書換え
    # Join-Path $PSScriptRoot '..' '..' '..' 'lib'  →  '..' 'lib'
    param([string]$File)
    if ($PSCmdlet.ShouldProcess($File, 'Rewrite lib import path') -eq $false) { return }
    if (-not (Test-Path -LiteralPath $File)) { return }
    $content = Get-Content -LiteralPath $File -Raw
    $newContent = $content -replace "(?:'\.\.'\s+){2,}'lib'", "'..' 'lib'"
    if ($newContent -ne $content) {
        Set-Content -LiteralPath $File -Value $newContent -NoNewline
    }
}

function Resolve-OpsScriptSource {
    # スクリプト名 → 実体パス。拡張子省略時は .ps1 を試行、
    # snake_case → PascalCase の変換も試す。
    param([string]$Name, [string]$Explicit)
    if ($Explicit) {
        $cand = Join-Path $repoRoot $Explicit
        if (Test-Path -LiteralPath $cand -PathType Leaf) { return $cand }
        if (Test-Path -LiteralPath $Explicit -PathType Leaf) { return $Explicit }
        return $null
    }
    # 検索候補名を作る
    $candidates = @()
    if ($Name -like '*.ps1' -or $Name -like '*.sh') {
        $candidates = @($Name)
    }
    else {
        $candidates += "$Name.ps1"
        # snake_case → PascalCase 変換も候補に
        if ($Name -like '*_*') {
            $pascal = ($Name -split '_' | ForEach-Object {
                if ($_) { $_.Substring(0, 1).ToUpper() + $_.Substring(1) }
            }) -join '-'
            $candidates += "$pascal.ps1"
        }
    }
    foreach ($cn in $candidates) {
        $found = @(Get-ChildItem -Path (Join-Path $repoRoot 'scripts') -Recurse -File -Filter $cn -ErrorAction SilentlyContinue)
        if ($found.Count -gt 0) {
            if ($found.Count -gt 1) {
                Write-OpsLog -Level WARN -Message "Multiple matches for '$Name' (using first): $(($found.FullName | Select-Object -First 5) -join ',')"
            }
            return $found[0].FullName
        }
    }
    return $null
}

# 1 エントリを配備（script + 関連 conf / tests）
function Invoke-OpsDeployEntry {
    param([hashtable]$Entry)

    $src = Resolve-OpsScriptSource -Name $Entry.Name -Explicit $Entry.Path
    if (-not $src) {
        Write-OpsLog -Level WARN -Message "Script not found in repo, skipping: name=$($Entry.Name)"
        $script:failed++
        return
    }

    $base = Split-Path -Leaf $src
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($base)

    # (1) 本体
    $dstScript = Join-Path $OptRoot 'script' $base
    if (Copy-OpsFile -Src $src -Dst $dstScript) {
        Update-OpsLibImport -File $dstScript
    }

    # (2) 設定ファイル
    # conf/ 直下にフラット配置。default を基底に env 指定があれば上書き。
    if ($Entry.Mode -in 'with-config','all') {
        # PS スクリプトの conf 名は snake_case 共有版（例: Backup-Ami.ps1 → backup_ami.conf）
        $confName = if ($Entry.Conf) {
            $Entry.Conf
        }
        elseif ($base -like '*.ps1') {
            ($stem -replace '-', '_').ToLower() + '.conf'
        }
        else {
            "$stem.conf"
        }

        # --- default の conf を先にコピー ---
        $confSrc = Join-Path $repoRoot 'config' 'default' $confName
        if (Test-Path -LiteralPath $confSrc -PathType Leaf) {
            Copy-OpsFile -Src $confSrc -Dst (Join-Path $OptRoot 'conf' $confName) | Out-Null
        }
        $opsSrc = Join-Path $repoRoot 'config' 'default' 'ops.conf'
        if (Test-Path -LiteralPath $opsSrc -PathType Leaf) {
            Copy-OpsFile -Src $opsSrc -Dst (Join-Path $OptRoot 'conf' 'ops.conf') | Out-Null
        }

        # --- env が指定されていれば上書き ---
        if ($Env) {
            $confSrc = Join-Path $repoRoot 'config' $Env $confName
            if (Test-Path -LiteralPath $confSrc -PathType Leaf) {
                Copy-OpsFile -Src $confSrc -Dst (Join-Path $OptRoot 'conf' $confName) | Out-Null
            }
            $opsSrc = Join-Path $repoRoot 'config' $Env 'ops.conf'
            if (Test-Path -LiteralPath $opsSrc -PathType Leaf) {
                Copy-OpsFile -Src $opsSrc -Dst (Join-Path $OptRoot 'conf' 'ops.conf') | Out-Null
            }
        }
    }

    # (3) テスト
    if ($Entry.Mode -in 'with-tests','all') {
        $testName = if ($Entry.Tests) {
            $Entry.Tests
        }
        elseif ($base -like '*.ps1') {
            "$stem.Tests.ps1"
        }
        else {
            "$stem.bats"
        }
        $testSrc = if ($base -like '*.sh') {
            Join-Path $repoRoot 'tests' 'bats' $testName
        }
        else {
            Join-Path $repoRoot 'tests' 'pester' $testName
        }
        if (Test-Path -LiteralPath $testSrc -PathType Leaf) {
            Copy-OpsFile -Src $testSrc -Dst (Join-Path $OptRoot 'tests' (Split-Path -Leaf $testSrc)) | Out-Null
        }
    }
}

# lib/powershell/ を配備（スクリプトが必須）
function Invoke-OpsDeployLib {
    Write-OpsLog -Level INFO -Message 'Deploying lib/powershell'
    $libDir = Join-Path $repoRoot 'lib' 'powershell'
    Get-ChildItem -Path $libDir -Filter '*.psm1' -File -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-OpsFile -Src $_.FullName -Dst (Join-Path $OptRoot 'lib' 'powershell' $_.Name) | Out-Null
    }
}

# ----------------------------------------------------------------------------
# メインフロー
# ----------------------------------------------------------------------------
try {
    do {
        Write-OpsLog -Level INFO -Message "Config loaded: env=$cfgEnv keys=$($cfg.Count)"
        Write-OpsLog -Level INFO -Message "Args validated: pathList='$PathList' optRoot='$OptRoot' env=$cfgEnv mode=$Mode backup=$Backup whatIf=$($PSCmdlet.MyInvocation.BoundParameters.ContainsKey('WhatIf'))"

        # --- フェーズ 3: プレチェック ---
        Write-OpsLog -Level INFO -Message 'Pre-check start'

        if (-not $PathList) {
            Write-OpsLog -Level ERROR -Message 'Specify -PathList or set PathList in config'
            $exitCode = 1; $status = 'failed'; break
        }
        if (-not (Test-Path -LiteralPath $PathList -PathType Leaf)) {
            Write-OpsLog -Level ERROR -Message "List file not found: $PathList"
            $exitCode = 2; $status = 'failed'; break
        }

        if ($PSCmdlet.ShouldProcess($OptRoot, 'Ensure OptRoot exists and is writable')) {
            try {
                New-Item -ItemType Directory -Path $OptRoot -Force | Out-Null
                # 書込みテスト
                $probe = Join-Path $OptRoot ".probe.$([Guid]::NewGuid().ToString('N'))"
                Set-Content -LiteralPath $probe -Value 'x'
                Remove-Item -LiteralPath $probe -Force
            }
            catch {
                Write-OpsLog -Level ERROR -Message "Cannot write to optRoot: $OptRoot error=$($_.Exception.Message)"
                $exitCode = 5; $status = 'failed'; break
            }
        }

        # リストパース
        $entries = @()
        $lines = Get-Content -LiteralPath $PathList |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') }
        foreach ($line in $lines) {
            $tokens = $line -split '\s+'
            $entry = @{
                Name = $tokens[0]
                Mode = $Mode
                Path = ''
                Conf = ''
                Tests = ''
            }
            for ($i = 1; $i -lt $tokens.Count; $i++) {
                $tok = $tokens[$i]
                $eq = $tok.IndexOf('=')
                if ($eq -lt 1) { Write-OpsLog -Level WARN -Message "Invalid token: line='$line' token='$tok'"; continue }
                $key = $tok.Substring(0, $eq)
                $val = $tok.Substring($eq + 1)
                switch ($key) {
                    'Mode' {
                        if ($val -in 'script-only','with-config','with-tests','all') { $entry.Mode = $val }
                        else { Write-OpsLog -Level WARN -Message "Invalid Mode: line='$line' value='$val'" }
                    }
                    'Path'  { $entry.Path  = $val }
                    'Conf'  { $entry.Conf  = $val }
                    'Tests' { $entry.Tests = $val }
                    default { Write-OpsLog -Level WARN -Message "Unknown key: line='$line' key='$key'" }
                }
            }
            $entries += $entry
        }

        if ($entries.Count -eq 0) {
            Write-OpsLog -Level WARN -Message 'No entries to deploy (skipped)'
            $status = 'skipped'; break
        }
        Write-OpsLog -Level INFO -Message "Pre-check passed: entryCount=$($entries.Count)"

        # --- フェーズ 4: メイン処理 ---
        Write-OpsLog -Level INFO -Message 'Main start'
        foreach ($e in $entries) {
            Invoke-OpsDeployEntry -Entry $e
        }
        Invoke-OpsDeployLib

        if ($script:failed -gt 0 -and $script:deployed -eq 0) {
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
