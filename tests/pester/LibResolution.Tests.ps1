#Requires -Version 5.1
<#
.SYNOPSIS
    PowerShell スクリプトの lib 解決ロジック（walk-up + OPS_LIB / OPS_CONFIG_DIR /
    .ops-deploy-root マーカー）の単体テスト。
    TomcatCtl.ps1 を deploy 後レイアウトに模した一時ディレクトリで動かして検証する。
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:repoRoot = Get-RepoRoot
    $script:realCtl  = Join-Path $script:repoRoot 'scripts_windows\tomcat\TomcatCtl.ps1'
    $script:realLog  = Join-Path $script:repoRoot 'scripts_windows\lib\Logging.psm1'
    $script:realCfg  = Join-Path $script:repoRoot 'scripts_windows\lib\Config.psm1'
}

# ラッパー: deploy 後構造を作って、その中で Get-Service / Start/Stop/Restart-Service
# をモック化したラッパースクリプトから本物の TomcatCtl.ps1 を実行する。
function Invoke-DeployedCtl {
    param(
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$Arguments = @(),
        [hashtable]$Env = @{}
    )
    $wrapper = Join-Path $WorkDir 'wrapper.ps1'
    $callLog = Join-Path $WorkDir 'calls.log'

    $arr = ($Arguments | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', '
    $content = @"
`$ErrorActionPreference = 'Stop'
function Get-Service {
    param([string]`$Name)
    Add-Content -Path '$callLog' -Value "Get-Service: `$Name"
    `$obj = [PSCustomObject]@{ Name=`$Name; Status='Running'; StartType='Automatic'; DisplayName=`$Name }
    Add-Member -InputObject `$obj -MemberType ScriptMethod -Name WaitForStatus -Value { param(`$t, `$to) }
    return `$obj
}
function Start-Service   { param([string]`$Name) Add-Content -Path '$callLog' -Value "Start-Service: `$Name" }
function Stop-Service    { param([string]`$Name, [switch]`$Force) Add-Content -Path '$callLog' -Value "Stop-Service: `$Name" }
function Restart-Service { param([string]`$Name, [switch]`$Force) Add-Content -Path '$callLog' -Value "Restart-Service: `$Name" }
& '$ScriptPath' $arr
exit `$LASTEXITCODE
"@
    Set-Content -LiteralPath $wrapper -Value $content -Encoding UTF8
    $r = Invoke-Controller -ScriptPath $wrapper -Env $Env
    $calls = if (Test-Path $callLog) { Get-Content $callLog } else { @() }
    return [PSCustomObject]@{
        ExitCode = $r.ExitCode
        Combined = $r.Combined
        Calls    = $calls
    }
}

Describe 'PS lib resolution: flat deploy layout (bin\<script>, lib\Logging.psm1)' {
    It 'finds lib one level up' {
        $work = New-TempWorkdir
        try {
            New-Item -ItemType Directory -Path (Join-Path $work 'bin') | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $work 'lib') | Out-Null
            Copy-Item $script:realLog (Join-Path $work 'lib\Logging.psm1')
            Copy-Item $script:realCfg (Join-Path $work 'lib\Config.psm1')
            Copy-Item $script:realCtl (Join-Path $work 'bin\TomcatCtl.ps1')
            New-Item -ItemType File -Path (Join-Path $work '.ops-deploy-root') -Force | Out-Null

            $r = Invoke-DeployedCtl -WorkDir $work -ScriptPath (Join-Path $work 'bin\TomcatCtl.ps1') -Arguments @('status','Tomcat10')
            $r.ExitCode | Should -Be 0
        } finally { Remove-TempPath $work }
    }
}

Describe 'PS lib resolution: OS-split deploy layout (lib\windows\Logging.psm1)' {
    It 'finds lib at lib\windows' {
        $work = New-TempWorkdir
        try {
            New-Item -ItemType Directory -Path (Join-Path $work 'bin')         | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $work 'lib\windows') | Out-Null
            Copy-Item $script:realLog (Join-Path $work 'lib\windows\Logging.psm1')
            Copy-Item $script:realCfg (Join-Path $work 'lib\windows\Config.psm1')
            Copy-Item $script:realCtl (Join-Path $work 'bin\TomcatCtl.ps1')
            New-Item -ItemType File -Path (Join-Path $work '.ops-deploy-root') -Force | Out-Null

            $r = Invoke-DeployedCtl -WorkDir $work -ScriptPath (Join-Path $work 'bin\TomcatCtl.ps1') -Arguments @('status','Tomcat10')
            $r.ExitCode | Should -Be 0
        } finally { Remove-TempPath $work }
    }
}

Describe 'PS lib resolution: domain subdir deploy layout (bin\<dom>\<script>)' {
    It 'walks 2 levels up to find lib' {
        $work = New-TempWorkdir
        try {
            New-Item -ItemType Directory -Path (Join-Path $work 'bin\tomcat') | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $work 'lib')         | Out-Null
            Copy-Item $script:realLog (Join-Path $work 'lib\Logging.psm1')
            Copy-Item $script:realCfg (Join-Path $work 'lib\Config.psm1')
            Copy-Item $script:realCtl (Join-Path $work 'bin\tomcat\TomcatCtl.ps1')
            New-Item -ItemType File -Path (Join-Path $work '.ops-deploy-root') -Force | Out-Null

            $r = Invoke-DeployedCtl -WorkDir $work -ScriptPath (Join-Path $work 'bin\tomcat\TomcatCtl.ps1') -Arguments @('status','Tomcat10')
            $r.ExitCode | Should -Be 0
        } finally { Remove-TempPath $work }
    }
}

Describe 'PS lib resolution: OPS_LIB env var override' {
    It 'uses OPS_LIB when set, ignoring discovery' {
        $work = New-TempWorkdir
        try {
            New-Item -ItemType Directory -Path (Join-Path $work 'random\place')  | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $work 'explicit_lib')  | Out-Null
            Copy-Item $script:realLog (Join-Path $work 'explicit_lib\Logging.psm1')
            Copy-Item $script:realCfg (Join-Path $work 'explicit_lib\Config.psm1')
            Copy-Item $script:realCtl (Join-Path $work 'random\place\TomcatCtl.ps1')
            New-Item -ItemType File -Path (Join-Path $work '.ops-deploy-root') -Force | Out-Null

            $r = Invoke-DeployedCtl `
                -WorkDir $work `
                -ScriptPath (Join-Path $work 'random\place\TomcatCtl.ps1') `
                -Arguments @('status','Tomcat10') `
                -Env @{ OPS_LIB = (Join-Path $work 'explicit_lib') }
            $r.ExitCode | Should -Be 0
        } finally { Remove-TempPath $work }
    }
}

Describe 'PS config resolution: OPS_CONFIG_DIR override + deployed flat layout' {
    It 'OPS_CONFIG_DIR picks up tomcatctl.conf and applies WaitTimeoutSec' {
        $work = New-TempWorkdir
        try {
            New-Item -ItemType Directory -Path (Join-Path $work 'bin')           | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $work 'lib')           | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $work 'explicit_conf') | Out-Null
            Copy-Item $script:realLog (Join-Path $work 'lib\Logging.psm1')
            Copy-Item $script:realCfg (Join-Path $work 'lib\Config.psm1')
            Copy-Item $script:realCtl (Join-Path $work 'bin\TomcatCtl.ps1')
            New-Item -ItemType File -Path (Join-Path $work '.ops-deploy-root') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $work 'explicit_conf\tomcatctl.conf') -Value "WaitTimeoutSec = 77"

            $r = Invoke-DeployedCtl `
                -WorkDir $work `
                -ScriptPath (Join-Path $work 'bin\TomcatCtl.ps1') `
                -Arguments @('status','Tomcat10') `
                -Env @{ OPS_CONFIG_DIR = (Join-Path $work 'explicit_conf') }
            $r.ExitCode | Should -Be 0
            $r.Combined | Should -Match 'timeoutSec=77'
        } finally { Remove-TempPath $work }
    }

    It 'picks up deployed flat config (<root>\config\tomcatctl.conf)' {
        $work = New-TempWorkdir
        try {
            New-Item -ItemType Directory -Path (Join-Path $work 'bin')    | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $work 'lib')    | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $work 'config') | Out-Null
            Copy-Item $script:realLog (Join-Path $work 'lib\Logging.psm1')
            Copy-Item $script:realCfg (Join-Path $work 'lib\Config.psm1')
            Copy-Item $script:realCtl (Join-Path $work 'bin\TomcatCtl.ps1')
            New-Item -ItemType File -Path (Join-Path $work '.ops-deploy-root') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $work 'config\tomcatctl.conf') -Value "WaitTimeoutSec = 99"

            $r = Invoke-DeployedCtl -WorkDir $work -ScriptPath (Join-Path $work 'bin\TomcatCtl.ps1') -Arguments @('status','Tomcat10')
            $r.ExitCode | Should -Be 0
            $r.Combined | Should -Match 'timeoutSec=99'
        } finally { Remove-TempPath $work }
    }
}
