#Requires -Version 5.1
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:ps1 = Join-Path (Get-RepoRoot) 'tools\server-snapshot\ServerSnapshot.ps1'
}
Describe 'ServerSnapshot new categories scaffold' {
    It 'collect accepts patches/tuning/scheduled and writes those keys' {
        $work = New-TempWorkdir
        try {
            $out = Join-Path $work 'snap.json'
            $r = Invoke-Controller -ScriptPath $script:ps1 `
                -Arguments @('collect','-Category','patches,tuning,scheduled','-OutputPath',$out)
            $r.ExitCode | Should -Be 0
            $obj = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
            $obj.PSObject.Properties.Name | Should -Contain 'patches'
            $obj.PSObject.Properties.Name | Should -Contain 'tuning'
            $obj.PSObject.Properties.Name | Should -Contain 'scheduled'
        } finally { Remove-TempPath $work }
    }
}
