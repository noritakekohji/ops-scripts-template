#Requires -Version 5.1
<#
.SYNOPSIS
    AWS スクリプト (Backup-Ami / Backup-EbsSnapshot / Ec2Ctl / S3Upload) の
    引数バリデーションのみテスト。実 AWS API は呼ばない。
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:awsDir = Join-Path (Get-RepoRoot) 'scripts_windows\aws'
}

Describe 'Backup-Ami: argument validation' {
    It 'no -InstanceId / -NamePrefix -> error' {
        $r = Invoke-Controller -ScriptPath (Join-Path $script:awsDir 'Backup-Ami.ps1') -Arguments @()
        $r.ExitCode | Should -Not -Be 0
    }
    It 'missing -NamePrefix -> error' {
        $r = Invoke-Controller -ScriptPath (Join-Path $script:awsDir 'Backup-Ami.ps1') -Arguments @('-InstanceId','i-0abcd1234')
        $r.ExitCode | Should -Not -Be 0
    }
}

Describe 'Backup-EbsSnapshot: argument validation' {
    It 'no -VolumeId / -NamePrefix -> error' {
        $r = Invoke-Controller -ScriptPath (Join-Path $script:awsDir 'Backup-EbsSnapshot.ps1') -Arguments @()
        $r.ExitCode | Should -Not -Be 0
    }
}

Describe 'Ec2Ctl: argument validation' {
    It 'no args -> error' {
        (Invoke-Controller -ScriptPath (Join-Path $script:awsDir 'Ec2Ctl.ps1') -Arguments @()).ExitCode | Should -Not -Be 0
    }
    It 'invalid action -> error' {
        (Invoke-Controller -ScriptPath (Join-Path $script:awsDir 'Ec2Ctl.ps1') -Arguments @('foo','-InstanceId','i-0test')).ExitCode | Should -Not -Be 0
    }
}

Describe 'S3Upload: argument validation' {
    It 'no args -> error' {
        (Invoke-Controller -ScriptPath (Join-Path $script:awsDir 'S3Upload.ps1') -Arguments @()).ExitCode | Should -Not -Be 0
    }
}
