Set-StrictMode -Version Latest

function Write-OpsLog {
    <#
    .SYNOPSIS
        Emit a single-line plain-text log entry.

    .DESCRIPTION
        Output format:
            [YYYY-MM-DD hh:mm:ss] [Level] (shellname:pid) Message

        - Timezone: Asia/Tokyo (JST, UTC+9) — fixed regardless of OS setting
        - Level:    5-char left-padded (INFO , WARN , ERROR, DEBUG)
        - Streams:  WARN/ERROR -> stderr, INFO/DEBUG -> stdout
        - Newlines in Message are replaced with single spaces.

        Structured properties are intentionally NOT supported — the caller
        is responsible for embedding any "key=value" pairs into Message.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    # Fix timestamps to Japan Standard Time (JST, UTC+9), regardless of OS tz.
    # PS 7+ accepts IANA names on all platforms; fall back to Windows id.
    try { $script:_OpsJstTz = [TimeZoneInfo]::FindSystemTimeZoneById('Asia/Tokyo') }
    catch { $script:_OpsJstTz = [TimeZoneInfo]::FindSystemTimeZoneById('Tokyo Standard Time') }
    $ts = [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $script:_OpsJstTz).ToString('yyyy-MM-dd HH:mm:ss')

    # Resolve caller script basename via call stack (skip frame 0 = this function)
    $shell = '<unknown>'
    foreach ($frame in (Get-PSCallStack | Select-Object -Skip 1)) {
        if ($frame.ScriptName) {
            $shell = Split-Path -Leaf $frame.ScriptName
            break
        }
    }

    # Strip newlines so each log entry stays on one line
    $msg = $Message -replace "`r?`n", ' '

    # Pad level to 5 chars (INFO , WARN , ERROR, DEBUG)
    $lvl = $Level.PadRight(5)

    $line = "[$ts] [$lvl] (${shell}:$PID) $msg"

    if ($Level -in 'WARN', 'ERROR') {
        [Console]::Error.WriteLine($line)
    }
    else {
        [Console]::Out.WriteLine($line)
    }
}

Export-ModuleMember -Function Write-OpsLog
