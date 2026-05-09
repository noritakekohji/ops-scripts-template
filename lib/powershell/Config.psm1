Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Load behavior-defining variables from key=value config files.

.DESCRIPTION
    Returns a hashtable populated by merging:

        config/common/ops.conf
        config/common/<Name>.conf
        config/<Env>/ops.conf
        config/<Env>/<Name>.conf

    Later sources override earlier ones. Missing files are skipped silently.

    Format: key=value, one per line. Lines starting with '#' and blank lines
    are ignored. Surrounding whitespace and matching single/double quotes
    around the value are trimmed.

.PARAMETER Name
    Script name (without extension) — e.g. "Backup-Ami".

.PARAMETER Env
    Environment name. Defaults to $env:OPS_ENV, or 'common' if unset.

.PARAMETER RepoRoot
    Repository root path. Auto-detected by walking up from this module's
    location looking for .git or shell-specification.md.
#>
function Get-OpsConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Env,
        [string]$RepoRoot
    )

    if (-not $Env) { $Env = if ($env:OPS_ENV) { $env:OPS_ENV } else { 'common' } }

    if (-not $RepoRoot) {
        $RepoRoot = _Find-OpsRepoRoot
    }

    $config = @{}
    $sources = @(
        Join-Path $RepoRoot 'config' 'common' 'ops.conf'
        Join-Path $RepoRoot 'config' 'common' "$Name.conf"
    )
    if ($Env -ne 'common') {
        $sources += Join-Path $RepoRoot 'config' $Env 'ops.conf'
        $sources += Join-Path $RepoRoot 'config' $Env "$Name.conf"
    }

    foreach ($file in $sources) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        Write-Verbose "Loading config: $file"
        Get-Content -LiteralPath $file | ForEach-Object {
            $line = $_.Trim()
            if (-not $line -or $line.StartsWith('#')) { return }
            $eq = $line.IndexOf('=')
            if ($eq -lt 1) { return }
            $key = $line.Substring(0, $eq).Trim()
            $val = $line.Substring($eq + 1).Trim()
            if ($val -match '^"(.*)"$' -or $val -match "^'(.*)'$") { $val = $Matches[1] }
            $config[$key] = $val
        }
    }

    return $config
}

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

Export-ModuleMember -Function Get-OpsConfig
