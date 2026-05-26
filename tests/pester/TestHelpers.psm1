#Requires -Version 5.1
<#
.SYNOPSIS
    Pester テスト共通ヘルパー
    - リポジトリ root の解決
    - 一時 repo / workdir の作成
    - Get-Service / Start-Service / Stop-Service / Restart-Service の
      モック化ヘルパー（実サービスを触らずに制御スクリプトを検証する）
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepoRoot {
    # tests/pester/<file>.Tests.ps1 → 2 つ上の階層が repo root
    return (Resolve-Path ([IO.Path]::Combine($PSScriptRoot, '..', '..'))).Path
}

function New-TempRepo {
    $d = Join-Path ([IO.Path]::GetTempPath()) ("ops-test-repo-$([Guid]::NewGuid().ToString('N'))")
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $d '.git') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $d 'config\default') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $d 'config\dev') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $d 'shell-specification.md') -Force | Out-Null
    return $d
}

function New-TempWorkdir {
    $d = Join-Path ([IO.Path]::GetTempPath()) ("ops-test-work-$([Guid]::NewGuid().ToString('N'))")
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

function Remove-TempPath {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ─────────────────────────────────────────────────────────────
# サービスシミュレータ
#   Get-Service の戻り値となる PSCustomObject を作る。
#   .Status / .StartType / .DisplayName / .Name と
#   .WaitForStatus(target, timeout) メソッドを持つ。
#   WaitForStatus は、シミュレータの状態が target と一致するまで
#   待つフリをして即座に返す（テスト中は実時間を消費しない）。
# ─────────────────────────────────────────────────────────────
function New-MockServiceObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('Running','Stopped','Paused','StartPending','StopPending')]
        [string]$Status = 'Stopped',
        [ValidateSet('Automatic','Manual','Disabled')]
        [string]$StartType = 'Automatic',
        [string]$DisplayName = ''
    )
    if (-not $DisplayName) { $DisplayName = $Name }
    $obj = [PSCustomObject]@{
        Name        = $Name
        Status      = $Status
        StartType   = $StartType
        DisplayName = $DisplayName
        _waitCalls  = 0
    }
    # WaitForStatus(target, timeout) を疑似実装
    $waitScript = {
        param($Target, $Timeout)
        $this._waitCalls++
        if ([string]$this.Status -ne [string]$Target) {
            # 通常はここで現在状態のまま「タイムアウト」になる挙動を模倣する。
            # ただしテストでは即時に状態が一致したと見なす方が便利なので、
            # 「目標状態に強制遷移」ではなく「タイムアウト例外」を投げる。
            # 個別テストで成功遷移をシミュレートしたいときは
            # Update-MockServiceStatus でフェイクの状態を変えてから呼ぶこと。
            throw [System.ServiceProcess.TimeoutException]::new(
                "WaitForStatus timeout (mock): target=$Target current=$($this.Status)"
            )
        }
    }
    Add-Member -InputObject $obj -MemberType ScriptMethod -Name WaitForStatus -Value $waitScript -PassThru | Out-Null
    return $obj
}

function Update-MockServiceStatus {
    param(
        [Parameter(Mandatory)][PSCustomObject]$Service,
        [Parameter(Mandatory)][string]$NewStatus
    )
    $Service.Status = $NewStatus
}

# ─────────────────────────────────────────────────────────────
# 子プロセス起動ユーティリティ
#   Set-StrictMode やグローバル状態がテストランナーへ漏れないよう、
#   制御スクリプトは必ず別 powershell.exe プロセスで実行する。
# ─────────────────────────────────────────────────────────────
function Invoke-Controller {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = '',
        [hashtable]$Env = @{}
    )
    # Linux/Docker でも実行できるよう、PowerShell ホストを動的に解決する。
    # Windows: powershell.exe (5.1) → pwsh の順
    # Linux:   pwsh のみ
    $psExe = $null
    foreach ($candidate in @('powershell.exe', 'powershell', 'pwsh')) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) { $psExe = $cmd.Source; break }
    }
    if (-not $psExe) { throw 'No PowerShell host found in PATH (powershell.exe / pwsh).' }

    # -File は Mandatory でない ValidateSet パラメータに不正値が来ると pwsh が
    # コマンドラインエラーとみなして help を出し exit 0 で抜けてしまう（テスト
    # としては失敗扱いにしたい）。-Command + `& <path> args` で呼び出すと
    # ValidateSet 違反などのスクリプトエラーが正しく非ゼロ exit で返る。
    $argTokens = $Arguments | ForEach-Object {
        if ($_ -match '^-[A-Za-z][A-Za-z0-9]*$') { $_ }
        else { "'" + ($_ -replace "'", "''") + "'" }
    }
    $argLine = $argTokens -join ' '
    # ErrorActionPreference=Stop + try/catch で parameter binding エラーも
    # 非ゼロ exit に変換する。catch ブロックでメッセージを stderr に流して
    # exit 1 で抜ける。スクリプトが自分で exit したい場合は $LASTEXITCODE を
    # 通す。
    $scriptPathEscaped = $ScriptPath -replace "'", "''"
    $command = @"
`$ErrorActionPreference = 'Stop'
try {
    & '$scriptPathEscaped' $argLine
    exit `$LASTEXITCODE
} catch {
    [Console]::Error.WriteLine(`$_.Exception.Message)
    if (`$LASTEXITCODE -and `$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE } else { exit 1 }
}
"@

    $psArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-Command', $command)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    foreach ($a in $psArgs) { $psi.ArgumentList.Add($a) | Out-Null }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    foreach ($k in $Env.Keys) { $psi.Environment[$k] = [string]$Env[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return [PSCustomObject]@{
        ExitCode = $p.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
        Combined = "$stdout`n$stderr"
    }
}

# ─────────────────────────────────────────────────────────────
# サービスシミュレータ付き呼び出し
#   - Service コマンドレットをラッパースクリプトで関数として上書き
#   - その関数は呼び出しを CallLog に追記し、状態遷移を模倣する
#   - 本体スクリプトを `&` で呼ぶことで、ラッパー関数が解決される
#
# 戻り値:
#   ExitCode / Combined / Calls (呼び出し履歴の配列)
# ─────────────────────────────────────────────────────────────
function Invoke-ControllerWithServiceMock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [ValidateSet('Running','Stopped','None')] [string]$InitialStatus = 'Running'
    )
    $wrapper = Join-Path ([IO.Path]::GetTempPath()) ("ctl-wrapper-$([Guid]::NewGuid().ToString('N')).ps1")
    $callLog = Join-Path ([IO.Path]::GetTempPath()) ("ctl-call-$([Guid]::NewGuid().ToString('N')).log")

    # 引数渡しの注意:
    #   - & '<script>' 'a' 'b'        だと quoted string は positional 扱い
    #   - & '<script>' @argArray      だと parameter set ありのスクリプトで
    #                                  named arg が認識されないケースあり
    #   - Invoke-Expression で文字列として渡すのが最も確実。-SID のような
    #     ハイフン始まり要素はそのまま、値要素は single-quote で囲む。
    $argTokens = $Arguments | ForEach-Object {
        if ($_ -match '^-[A-Za-z][A-Za-z0-9]*$') { $_ }  # -Foo はそのまま (named parameter)
        else { "'" + ($_ -replace "'", "''") + "'" }      # 値は quoting
    }
    $argLine = $argTokens -join ' '
    $wrapperContent = @"
`$ErrorActionPreference = 'Stop'
`$CallLog = '$callLog'
`$global:_MockStatus = '$InitialStatus'

function Get-Service {
    # CmdletBinding を付けると common parameters (-ErrorAction 等) が
    # 自動付与されるので、呼び出し側の -ErrorAction SilentlyContinue を吸収できる
    [CmdletBinding()]
    param(
        [Parameter(Position=0)][string]`$Name
    )
    Add-Content -Path `$CallLog -Value "Get-Service: `$Name"
    if (`$global:_MockStatus -eq 'None') {
        return `$null   # control scripts call Get-Service -ErrorAction SilentlyContinue
    }
    `$obj = [PSCustomObject]@{
        Name        = `$Name
        Status      = `$global:_MockStatus
        StartType   = 'Automatic'
        DisplayName = `$Name
    }
    Add-Member -InputObject `$obj -MemberType ScriptMethod -Name WaitForStatus -Value {
        param(`$Target, `$Timeout)
        `$global:_MockStatus = [string]`$Target
    }
    return `$obj
}

function Start-Service   { param([Parameter(Mandatory)][string]`$Name) Add-Content -Path `$CallLog -Value "Start-Service: `$Name";   `$global:_MockStatus = 'Running' }
function Stop-Service    { param([Parameter(Mandatory)][string]`$Name, [switch]`$Force) Add-Content -Path `$CallLog -Value "Stop-Service: `$Name"; `$global:_MockStatus = 'Stopped' }
function Restart-Service { param([Parameter(Mandatory)][string]`$Name, [switch]`$Force) Add-Content -Path `$CallLog -Value "Restart-Service: `$Name"; `$global:_MockStatus = 'Running' }

Invoke-Expression "& '$ScriptPath' $argLine"
exit `$LASTEXITCODE
"@
    Set-Content -LiteralPath $wrapper -Value $wrapperContent -Encoding UTF8
    try {
        $r = Invoke-Controller -ScriptPath $wrapper
        $calls = if (Test-Path $callLog) { Get-Content $callLog } else { @() }
        return [PSCustomObject]@{
            ExitCode = $r.ExitCode
            Combined = $r.Combined
            Calls    = $calls
        }
    }
    finally {
        Remove-Item -LiteralPath $wrapper -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $callLog -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function *
