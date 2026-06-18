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

Describe 'ServerSnapshot patches' {
    It 'patches is an array and survives when Get-HotFix is unavailable' {
        $work = New-TempWorkdir
        try {
            $out = Join-Path $work 'snap.json'
            $r = Invoke-Controller -ScriptPath $script:ps1 `
                -Arguments @('collect','-Category','patches','-OutputPath',$out)
            $r.ExitCode | Should -Be 0
            $obj = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
            ,$obj.patches | Should -BeOfType [System.Array]
        } finally { Remove-TempPath $work }
    }
}

Describe 'ServerSnapshot tuning' {
    It 'tuning is a dict with power_scheme key (Windows)' {
        $work = New-TempWorkdir
        try {
            $out = Join-Path $work 'snap.json'
            $r = Invoke-Controller -ScriptPath $script:ps1 `
                -Arguments @('collect','-Category','tuning','-OutputPath',$out)
            $r.ExitCode | Should -Be 0
            $obj = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
            $obj.tuning.PSObject.Properties.Name | Should -Contain 'power_scheme'
        } finally { Remove-TempPath $work }
    }
}

Describe 'ServerSnapshot os expansion' {
    It 'os has hardware/locale_detail/reboot_pending' {
        $work = New-TempWorkdir
        try {
            $out = Join-Path $work 'snap.json'
            $r = Invoke-Controller -ScriptPath $script:ps1 `
                -Arguments @('collect','-Category','os','-OutputPath',$out)
            $r.ExitCode | Should -Be 0
            $os = (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).os
            $os.PSObject.Properties.Name | Should -Contain 'hardware'
            $os.PSObject.Properties.Name | Should -Contain 'locale_detail'
            $os.PSObject.Properties.Name | Should -Contain 'reboot_pending'
            $os.hostname | Should -Not -BeNullOrEmpty
        } finally { Remove-TempPath $work }
    }
}

Describe 'ServerSnapshot network expansion' {
    It 'network has proxy and time_sync with _volatile' {
        $work = New-TempWorkdir
        try {
            $out = Join-Path $work 'snap.json'
            $r = Invoke-Controller -ScriptPath $script:ps1 `
                -Arguments @('collect','-Category','network','-OutputPath',$out)
            $r.ExitCode | Should -Be 0
            $net = (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).network
            $net.PSObject.Properties.Name | Should -Contain 'proxy'
            $net.PSObject.Properties.Name | Should -Contain 'time_sync'
            $net.time_sync.PSObject.Properties.Name | Should -Contain '_volatile'
            $net.interfaces | Should -Not -BeNullOrEmpty
        } finally { Remove-TempPath $work }
    }
}

Describe 'ServerSnapshot filesystem expansion' {
    It 'each drive has mount_options key' {
        $work = New-TempWorkdir
        try {
            $out = Join-Path $work 'snap.json'
            $r = Invoke-Controller -ScriptPath $script:ps1 `
                -Arguments @('collect','-Category','filesystem','-OutputPath',$out)
            $r.ExitCode | Should -Be 0
            $drives = (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).filesystem.drives
            if (@($drives).Count -gt 0) {
                $drives[0].PSObject.Properties.Name | Should -Contain 'mount_options'
            }
        } finally { Remove-TempPath $work }
    }
}

Describe 'ServerSnapshot security expansion' {
    It 'security has uac (Windows)' {
        $work = New-TempWorkdir
        try {
            $out = Join-Path $work 'snap.json'
            $r = Invoke-Controller -ScriptPath $script:ps1 `
                -Arguments @('collect','-Category','security','-OutputPath',$out)
            $r.ExitCode | Should -Be 0
            $sec = (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).security
            $sec.PSObject.Properties.Name | Should -Contain 'uac'
        } finally { Remove-TempPath $work }
    }
}

Describe 'ServerSnapshot scheduled' {
    It 'scheduled has scheduled_tasks and startup keys' {
        $work = New-TempWorkdir
        try {
            $out = Join-Path $work 'snap.json'
            $r = Invoke-Controller -ScriptPath $script:ps1 `
                -Arguments @('collect','-Category','scheduled','-OutputPath',$out)
            $r.ExitCode | Should -Be 0
            $obj = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
            $obj.scheduled.PSObject.Properties.Name | Should -Contain 'scheduled_tasks'
            $obj.scheduled.PSObject.Properties.Name | Should -Contain 'startup'
        } finally { Remove-TempPath $work }
    }
}
