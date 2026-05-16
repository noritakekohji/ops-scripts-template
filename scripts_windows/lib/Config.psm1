Set-StrictMode -Version Latest

<#
.SYNOPSIS
    key=value 形式の設定ファイルから挙動パラメータを読み込む。

.DESCRIPTION
    次のルールでファイルを読み込みハッシュテーブルを返す：

        Env 未指定: config/default/global.conf + config/default/<Name>.conf
        Env 指定時: config/<Env>/global.conf   + config/<Env>/<Name>.conf

    存在しないファイルは黙ってスキップ。

    フォーマット: 1 行 1 設定 (`key=value`)。行頭 `#` の行と空行は無視。
    前後の空白は trim、値を囲む `"..."` / `'...'` は除去される。

.PARAMETER Name
    スクリプト名（拡張子なし）。例：`backup_ami`、`ec2ctl`。

.PARAMETER Env
    環境名。指定なしなら `$env:OPS_ENV`、それも未設定なら `config/default/` のみ読む。

.PARAMETER RepoRoot
    リポジトリのルートパス。指定なしなら、本モジュールの位置から
    `.git` または `shell-specification.md` を探して自動検出する。
#>
function Get-OpsConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Env,
        [string]$RepoRoot
    )

    # OPS_ENV 未設定なら空文字（default のみ読む）
    if (-not $Env) { $Env = if ($env:OPS_ENV) { $env:OPS_ENV } else { '' } }

    if (-not $RepoRoot) {
        $RepoRoot = _Find-OpsRepoRoot
    }

    # env 指定なし → config/default/、env 指定あり → config/<env>/ のみ読む
    $config = @{}
    $configDir = if ($Env) { [IO.Path]::Combine($RepoRoot, 'config', $Env) } else { [IO.Path]::Combine($RepoRoot, 'config', 'default') }
    $sources = @(
        Join-Path $configDir 'global.conf'
        Join-Path $configDir "$Name.conf"
    )

    foreach ($file in $sources) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        Write-Verbose "Loading config: $file"
        Get-Content -LiteralPath $file -Encoding UTF8 | ForEach-Object {
            $line = $_.Trim()
            # 空行とコメント行はスキップ
            if (-not $line -or $line.StartsWith('#')) { return }
            $eq = $line.IndexOf('=')
            if ($eq -lt 1) { return }
            $key = $line.Substring(0, $eq).Trim()
            $val = $line.Substring($eq + 1).Trim()
            # 値の前後を囲む引用符は除去
            if ($val -match '^"(.*)"$' -or $val -match "^'(.*)'$") { $val = $Matches[1] }
            $config[$key] = $val
        }
    }

    return $config
}

# 内部: モジュールの位置から親ディレクトリを辿ってリポジトリ root を検出
function _Find-OpsRepoRoot {
    $current = $PSScriptRoot
    while ($current) {
        if ((Test-Path (Join-Path $current '.git')) -or
            (Test-Path (Join-Path $current 'shell-specification.md'))) {
            return $current
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
    throw 'Cannot determine ops-scripts repo root from Config.psm1 location'
}

function Get-OpsRepoRoot {
    <#
    .SYNOPSIS
        ops-scripts のリポジトリ root を解決して返す。

    .DESCRIPTION
        config の `PathList` のような相対パスを絶対化したいときに使う。
        本モジュールの位置を起点に親方向に `.git` または
        `shell-specification.md` を探す。
    #>
    [CmdletBinding()]
    param()
    return _Find-OpsRepoRoot
}

Export-ModuleMember -Function Get-OpsConfig, Get-OpsRepoRoot
