Set-StrictMode -Version Latest

function Write-OpsLog {
    [CmdletBinding()]
    param(
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',

        [Parameter(Mandatory)]
        [string]$Message,

        [hashtable]$Properties = @{}
    )

    $obj = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        level     = $Level
        message   = $Message
        actor     = $env:USERNAME
        host      = $env:COMPUTERNAME
        pid       = $PID
    }
    foreach ($k in $Properties.Keys) { $obj[$k] = $Properties[$k] }

    $json = $obj | ConvertTo-Json -Compress -Depth 5

    if ($Level -eq 'ERROR') {
        [Console]::Error.WriteLine($json)
    }
    else {
        [Console]::Out.WriteLine($json)
    }
}

Export-ModuleMember -Function Write-OpsLog
