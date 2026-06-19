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

Describe 'ServerSnapshot compare new categories' {
    It 'detects tuning change and ignores time_sync _volatile' {
        $work = New-TempWorkdir
        try {
            $before = Join-Path $work 'b.json'; $after = Join-Path $work 'a.json'
            $b = @{ meta=@{hostname='h';os_type='windows';collected_at='t';categories=@('tuning','network')}
                    tuning=@{power_scheme='Balanced'}
                    network=@{ interfaces=@(); routes=@(); dns_servers=@(); hosts=@()
                               proxy=@{enabled=$false;server=''}
                               time_sync=@{ servers=@('s1'); synchronized=$true; _volatile=@{ last_sync='10:00' } } } }
            $a = @{ meta=@{hostname='h';os_type='windows';collected_at='t2';categories=@('tuning','network')}
                    tuning=@{power_scheme='High performance'}
                    network=@{ interfaces=@(); routes=@(); dns_servers=@(); hosts=@()
                               proxy=@{enabled=$false;server=''}
                               time_sync=@{ servers=@('s1'); synchronized=$true; _volatile=@{ last_sync='11:00' } } } }
            ($b | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $before -Encoding UTF8
            ($a | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $after  -Encoding UTF8
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('compare','-BeforePath',$before,'-AfterPath',$after)
            $r.Combined | Should -Match 'tuning'
            $r.Combined | Should -Match 'Balanced'
            $r.Combined | Should -Not -Match 'last_sync'
        } finally { Remove-TempPath $work }
    }
}

Describe 'ServerSnapshot middleware scaffold' {
    It 'collect accepts middleware and writes a middleware object' {
        $work = New-TempWorkdir
        try {
            $out = Join-Path $work 'snap.json'
            $r = Invoke-Controller -ScriptPath $script:ps1 `
                -Arguments @('collect','-Category','middleware','-OutputPath',$out)
            $r.ExitCode | Should -Be 0
            $obj = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
            $obj.PSObject.Properties.Name | Should -Contain 'middleware'
        } finally { Remove-TempPath $work }
    }
}

Describe 'ServerSnapshot middleware file helper' {
    It 'masks secrets and records sha256/size; missing file flagged' {
        $work = New-TempWorkdir
        try {
            $f = Join-Path $work 'app.conf'
            "user = admin`npassword = s3cr3t`nport = 8080" | Set-Content -LiteralPath $f -Encoding UTF8
            $out = Join-Path $work 'snap.json'
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('collect','-Category','middleware','-OutputPath',$out) -Env @{ _OPS_MW_PROBE = $f }
            $r.ExitCode | Should -Be 0
            $p = (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).middleware._probe
            $p.masked      | Should -BeTrue
            $p.content     | Should -Match 'password\s*=\s*\*\*\*'
            $p.content     | Should -Match 'user = admin'
            $p.size_bytes  | Should -BeGreaterThan 0
            $p.sha256      | Should -Match '^[0-9a-f]{64}$'
            $p.readable    | Should -BeTrue
        } finally { Remove-TempPath $work }
    }

    It 'masks secrets in JSON quoted-key form' {
        $work = New-TempWorkdir
        try {
            $f = Join-Path $work 'app.json'
            "{`n  `"username`": `"admin`",`n  `"password`": `"s3cr3t`"`n}" | Set-Content -LiteralPath $f -Encoding UTF8
            $out = Join-Path $work 'snap.json'
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('collect','-Category','middleware','-OutputPath',$out) -Env @{ _OPS_MW_PROBE = $f }
            $r.ExitCode | Should -Be 0
            $p = (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).middleware._probe
            $p.masked  | Should -BeTrue
            $p.content | Should -Match '"password"\s*:\s*"\*\*\*"'
            $p.content | Should -Match '"username"\s*:\s*"admin"'
        } finally { Remove-TempPath $work }
    }
}

Describe 'ServerSnapshot middleware tomcat' {
    It 'detects a tomcat base via CATALINA_BASE and collects masked server.xml + ports' {
        $work = New-TempWorkdir
        try {
            $base = Join-Path $work 'tomcat9'
            New-Item -ItemType Directory -Path (Join-Path $base 'conf') -Force | Out-Null
            @'
<Server port="8005">
  <Service name="Catalina">
    <Connector port="8080" protocol="HTTP/1.1"/>
    <Connector port="8443" secret="topsecret"/>
  </Service>
</Server>
'@ | Set-Content -LiteralPath (Join-Path $base 'conf\server.xml') -Encoding UTF8
            $out = Join-Path $work 'snap.json'
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('collect','-Category','middleware','-OutputPath',$out) -Env @{ CATALINA_BASE = $base }
            $r.ExitCode | Should -Be 0
            $mw = (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).middleware
            $inst = @($mw.tomcat) | Where-Object { $_.catalina_base -eq $base }
            @($inst).Count | Should -BeGreaterThan 0
            @($inst.connector_ports) | Should -Contain 8080
            $sx = $inst.config_files.PSObject.Properties | Where-Object { $_.Name -like '*server.xml' }
            $sx.Value.content | Should -Match 'secret="\*\*\*"'
        } finally { Remove-TempPath $work }
    }
}

Describe 'ServerSnapshot middleware sap (windows)' {
    It 'detects a SAP SID profile dir and collects masked profiles' {
        $work = New-TempWorkdir
        try {
            $prof = Join-Path $work 'usr\sap\PRD\SYS\profile'
            New-Item -ItemType Directory -Path $prof -Force | Out-Null
            "SAPSYSTEMNAME = PRD`nrdisp/wp_no_dia = 10`nlogin/password_downwards_compatibility = 0" |
                Set-Content -LiteralPath (Join-Path $prof 'DEFAULT.PFL') -Encoding UTF8
            "INSTANCE_NAME = D00`nws/conn_password = topsecret" |
                Set-Content -LiteralPath (Join-Path $prof 'PRD_D00_host') -Encoding UTF8
            $conf = Join-Path $work 'mw.conf'
            @"
[sap]
sids = PRD
profile_globs = $($work -replace '\\','\\')\usr\sap\%SID%\SYS\profile\*
[limits]
max_file_kb = 256
"@ | Set-Content -LiteralPath $conf -Encoding UTF8
            $out = Join-Path $work 'snap.json'
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('collect','-Category','middleware','-OutputPath',$out) -Env @{ _OPS_MW_CONF = $conf }
            $r.ExitCode | Should -Be 0
            $mw = (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).middleware
            $sap = @($mw.sap) | Where-Object { $_.sid -eq 'PRD' }
            @($sap).Count | Should -BeGreaterThan 0
            $names = @($sap.profiles.PSObject.Properties.Name | ForEach-Object { Split-Path $_ -Leaf })
            $names | Should -Contain 'DEFAULT.PFL'
            $names | Should -Contain 'PRD_D00_host'
            $pf = $sap.profiles.PSObject.Properties | Where-Object { $_.Name -like '*PRD_D00_host' }
            $pf.Value.content | Should -Match 'conn_password\s*=\s*\*\*\*'
        } finally { Remove-TempPath $work }
    }
}

Describe 'ServerSnapshot middleware sqlserver' {
    It 'sqlserver collection never throws; entries (if any) carry sp_configure_available' {
        $work = New-TempWorkdir
        try {
            $out = Join-Path $work 'snap.json'
            $r = Invoke-Controller -ScriptPath $script:ps1 -Arguments @('collect','-Category','middleware','-OutputPath',$out)
            $r.ExitCode | Should -Be 0
            $mw = (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).middleware
            # If SQL Server isn't installed, key is omitted (fine). If present, must carry the flag.
            if ($mw.PSObject.Properties.Name -contains 'sqlserver') {
                @($mw.sqlserver)[0].PSObject.Properties.Name | Should -Contain 'sp_configure_available'
            }
        } finally { Remove-TempPath $work }
    }
}
