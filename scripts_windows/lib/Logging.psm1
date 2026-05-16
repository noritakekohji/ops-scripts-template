Set-StrictMode -Version Latest

# JST タイムゾーン情報のキャッシュ（モジュール初回利用時に解決）
$script:_OpsJstTz = $null

$script:_OpsLogFile  = $null
$script:_OpsLogLevel = 'INFO'
$script:_LevelOrder  = @{ DEBUG = 0; INFO = 1; WARN = 2; ERROR = 3 }

function _Get-OpsJstTz {
    # JST (Asia/Tokyo) のタイムゾーン情報を取得して返す。
    # 優先順: IANA 'Asia/Tokyo' → Windows 'Tokyo Standard Time' → UTC+9 固定オフセット
    if ($null -eq $script:_OpsJstTz) {
        try { $script:_OpsJstTz = [TimeZoneInfo]::FindSystemTimeZoneById('Asia/Tokyo') }
        catch {
            try { $script:_OpsJstTz = [TimeZoneInfo]::FindSystemTimeZoneById('Tokyo Standard Time') }
            catch {
                # tzdata 未インストール環境向け: UTC+9 固定オフセット（DST なし）
                $script:_OpsJstTz = [TimeZoneInfo]::CreateCustomTimeZone(
                    'JST', [TimeSpan]::FromHours(9), 'Japan Standard Time', 'Japan Standard Time')
            }
        }
    }
    return $script:_OpsJstTz
}

function Set-OpsLogConfig {
    <#
    .SYNOPSIS
        Configure file output for Write-OpsLog.
    .PARAMETER LogFile
        Path to the log file. Empty string disables file logging.
    .PARAMETER LogLevel
        Minimum severity level written to the log file (DEBUG/INFO/WARN/ERROR).
        Default: INFO.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][AllowNull()][string]$LogFile = '',
        [ValidateSet('DEBUG','INFO','WARN','ERROR')][string]$LogLevel = 'INFO'
    )
    $script:_OpsLogFile  = if ($LogFile) { $LogFile } else { $null }
    $script:_OpsLogLevel = $LogLevel
}

function Get-OpsJstStamp {
    <#
    .SYNOPSIS
        現在時刻を JST（日本時刻）で文字列に整形して返す。

    .DESCRIPTION
        リソース名やタグ値、S3 キー suffix など「OS のタイムゾーン設定に
        左右されたくないタイムスタンプ」を生成するためのヘルパー。
        既定は `yyyyMMdd-HHmmss`（例：`20260510-153045`）。

    .PARAMETER Format
        .NET の DateTime.ToString フォーマット文字列。

    .EXAMPLE
        $stamp = Get-OpsJstStamp                 # 20260510-153045
        $iso   = Get-OpsJstStamp 'yyyy-MM-ddTHH:mm:ss'
    #>
    [CmdletBinding()]
    param([string]$Format = 'yyyyMMdd-HHmmss')
    $tz = _Get-OpsJstTz
    return [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $tz).ToString($Format)
}

function Write-OpsLog {
    <#
    .SYNOPSIS
        1 行のプレーンテキストログを出力する。

    .DESCRIPTION
        出力フォーマット:
            [YYYY-MM-DD hh:mm:ss] [Level] (shellname:pid) Message

        - タイムゾーン: Asia/Tokyo（JST、UTC+9）固定。OS の TZ には依存しない
        - レベル: 5 文字左詰め（INFO , WARN , ERROR, DEBUG）
        - ストリーム: WARN/ERROR は stderr、INFO/DEBUG は stdout
        - Message 中の改行は単一スペースに置換される

        構造化プロパティ引数は意図的にサポートしていない。`key=value` の
        組み立ては呼び出し側で行い、Message 文字列に埋め込むこと。
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    # JST 固定のタイムスタンプを生成
    $ts = [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, (_Get-OpsJstTz)).ToString('yyyy-MM-dd HH:mm:ss')

    # 呼び出し元スクリプトの basename をコールスタックから解決（フレーム 0 は本関数なのでスキップ）
    $shell = '<unknown>'
    foreach ($frame in (Get-PSCallStack | Select-Object -Skip 1)) {
        if ($frame.ScriptName) {
            $shell = Split-Path -Leaf $frame.ScriptName
            break
        }
    }

    # 1 行 1 イベントを保証するため、メッセージ中の改行を空白に置換
    $msg = $Message -replace "`r?`n", ' '

    # レベルを 5 文字に左詰め（INFO , WARN , ERROR, DEBUG）
    $lvl = $Level.PadRight(5)

    $line = "[$ts] [$lvl] (${shell}:$PID) $msg"

    if ($Level -in 'WARN', 'ERROR') {
        [Console]::Error.WriteLine($line)
    }
    else {
        [Console]::Out.WriteLine($line)
    }

    # Write to log file if configured and level meets the threshold
    if ($script:_OpsLogFile -and ($script:_LevelOrder[$Level] -ge $script:_LevelOrder[$script:_OpsLogLevel])) {
        try {
            $logDir = Split-Path -Parent $script:_OpsLogFile
            if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }
            Add-Content -LiteralPath $script:_OpsLogFile -Value $line -Encoding UTF8
        }
        catch {
            [Console]::Error.WriteLine("[WARN ] Log file write failed: $($_.Exception.Message)")
        }
    }
}

Export-ModuleMember -Function Write-OpsLog, Get-OpsJstStamp, Set-OpsLogConfig
