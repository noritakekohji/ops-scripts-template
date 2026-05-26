#Requires -Version 5.1
<#
.SYNOPSIS
    SAPCtl.ps1 の単体テスト（引数バリデーションのみ + conf 補完）
    実行系（sapcontrol / Get-Service "SAP$SID_$NN"）はモック越しに動かす。
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:ctl = Join-Path (Get-RepoRoot) 'scripts_windows\sap\SAPCtl.ps1'
}

Describe 'SAPCtl: argument validation' {
    It 'invalid action -> error' {
        (Invoke-Controller -ScriptPath $script:ctl -Arguments @('foo','-SID','S4H','-InstanceNumber','00')).ExitCode | Should -Not -Be 0
    }
    It 'lower-case SID -> ValidatePattern error' {
        (Invoke-Controller -ScriptPath $script:ctl -Arguments @('status','-SID','s4h','-InstanceNumber','00')).ExitCode | Should -Not -Be 0
    }
    It 'one-digit InstanceNumber -> ValidatePattern error' {
        (Invoke-Controller -ScriptPath $script:ctl -Arguments @('status','-SID','S4H','-InstanceNumber','0')).ExitCode | Should -Not -Be 0
    }
    It 'WaitTimeoutSec out of range -> error' {
        (Invoke-Controller -ScriptPath $script:ctl -Arguments @('start','-SID','S4H','-InstanceNumber','00','-WaitTimeoutSec','10')).ExitCode | Should -Not -Be 0
    }
}

Describe 'SAPCtl: behaviour with mocked service' {
    It 'service named SAP[SID]_[NN] not found -> exit 2' {
        (Invoke-ControllerWithServiceMock -ScriptPath $script:ctl -Arguments @('status','-SID','S4H','-InstanceNumber','00') -InitialStatus 'None').ExitCode | Should -Be 2
    }
    It 'status is read-only' {
        $r = Invoke-ControllerWithServiceMock -ScriptPath $script:ctl -Arguments @('status','-SID','S4H','-InstanceNumber','00') -InitialStatus 'Running'
        $r.ExitCode | Should -Be 0
        @($r.Calls | Where-Object { $_ -match 'Start-Service|Stop-Service|Restart-Service' }).Count | Should -Be 0
    }
    It 'start when Running -> skipped' {
        $r = Invoke-ControllerWithServiceMock -ScriptPath $script:ctl -Arguments @('start','-SID','S4H','-InstanceNumber','00') -InitialStatus 'Running'
        $r.ExitCode | Should -Be 0
        $r.Combined | Should -Match 'Skipped'
    }
}
