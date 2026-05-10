#Requires -Version 5.1
<#
.SYNOPSIS
    lib/powershell/Logging.psm1 のユニットテスト（Pester 5+）。

    実行方法（リポジトリ root から）:
        Invoke-Pester -Path tests/pester/Logging.Tests.ps1
#>

BeforeAll {
    $repoRoot = (Resolve-Path ([IO.Path]::Combine($PSScriptRoot, '..', '..'))).Path
    Import-Module ([IO.Path]::Combine($repoRoot, 'lib', 'powershell', 'Logging.psm1')) -Force
}

Describe 'Get-OpsJstStamp' {

    It '既定で yyyyMMdd-HHmmss 形式の 15 文字を返す' {
        $stamp = Get-OpsJstStamp
        $stamp | Should -Match '^[0-9]{8}-[0-9]{6}$'
        $stamp.Length | Should -Be 15
    }

    It 'カスタムフォーマットを受け付ける' {
        $stamp = Get-OpsJstStamp 'yyyy-MM-dd'
        $stamp | Should -Match '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    }

    It 'JST 固定（UTC+9 の時刻と一致、誤差 ±10 秒以内）' {
        $expectedJst = [DateTime]::UtcNow.AddHours(9)
        $stamp = Get-OpsJstStamp 'yyyy-MM-dd HH:mm:ss'
        $parsed = [DateTime]::ParseExact($stamp, 'yyyy-MM-dd HH:mm:ss', $null)
        ($parsed - $expectedJst).TotalSeconds | Should -BeGreaterThan -10
        ($parsed - $expectedJst).TotalSeconds | Should -BeLessThan 10
    }
}

Describe 'Write-OpsLog' {

    It '不正なレベルは ValidateSet で拒否される' {
        { Write-OpsLog -Level FATAL -Message 'x' } | Should -Throw
    }

    It '空メッセージを許容する（AllowEmptyString）' {
        { Write-OpsLog -Level INFO -Message '' } | Should -Not -Throw
    }

    It 'INFO は仕様フォーマットで stdout に出力される' {
        # [Console]::Out を一時的に StringWriter に差し替えて出力を捕捉
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try {
            Write-OpsLog -Level INFO -Message 'hello'
        }
        finally {
            [Console]::SetOut($orig)
        }
        $line = $sw.ToString().TrimEnd()
        # フォーマット: [YYYY-MM-DD hh:mm:ss] [INFO ] (shellname:pid) hello
        $line | Should -Match '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] \[INFO \] \([^:]+:\d+\) hello$'
    }

    It 'ERROR は stderr に出力される（stdout には出ない）' {
        $stdoutSw = [System.IO.StringWriter]::new()
        $stderrSw = [System.IO.StringWriter]::new()
        $origOut = [Console]::Out
        $origErr = [Console]::Error
        [Console]::SetOut($stdoutSw)
        [Console]::SetError($stderrSw)
        try {
            Write-OpsLog -Level ERROR -Message 'oops'
        }
        finally {
            [Console]::SetOut($origOut)
            [Console]::SetError($origErr)
        }
        $stdoutSw.ToString() | Should -BeNullOrEmpty
        $stderrSw.ToString() | Should -Match '\[ERROR\] .* oops'
    }

    It 'メッセージ中の改行は単一スペースに置換される' {
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try {
            Write-OpsLog -Level INFO -Message "line1`nline2"
        }
        finally {
            [Console]::SetOut($orig)
        }
        $sw.ToString() | Should -Match 'line1 line2'
    }

    It 'レベルは 5 文字に左詰めされる（INFO の後ろに空白）' {
        $sw = [System.IO.StringWriter]::new()
        $orig = [Console]::Out
        [Console]::SetOut($sw)
        try { Write-OpsLog -Level INFO -Message 'x' } finally { [Console]::SetOut($orig) }
        $sw.ToString() | Should -Match '\[INFO \]'
    }
}

Describe 'Set-OpsLogConfig / file logging' {

    BeforeEach {
        $script:tmpLog = Join-Path ([System.IO.Path]::GetTempPath()) ("ops-log-test-$([Guid]::NewGuid().ToString('N')).log")
        Set-OpsLogConfig -LogFile $script:tmpLog -LogLevel 'INFO'
    }

    AfterEach {
        Set-OpsLogConfig -LogFile '' -LogLevel 'INFO'
        if ($script:tmpLog -and (Test-Path -LiteralPath $script:tmpLog)) {
            Remove-Item -LiteralPath $script:tmpLog -Force
        }
    }

    It 'INFO メッセージがファイルに書き込まれる' {
        Write-OpsLog -Level INFO -Message 'file-test'
        (Get-Content -LiteralPath $script:tmpLog -Encoding UTF8) | Should -Match 'file-test'
    }

    It 'LogLevel=WARN のとき INFO はファイルに書かれない' {
        Set-OpsLogConfig -LogFile $script:tmpLog -LogLevel 'WARN'
        Write-OpsLog -Level INFO -Message 'should-not-appear'
        Test-Path -LiteralPath $script:tmpLog | Should -Be $false
    }

    It 'LogLevel=WARN のとき WARN はファイルに書かれる' {
        Set-OpsLogConfig -LogFile $script:tmpLog -LogLevel 'WARN'
        Write-OpsLog -Level WARN -Message 'warn-test'
        (Get-Content -LiteralPath $script:tmpLog -Encoding UTF8) | Should -Match 'warn-test'
    }

    It 'LogFile 未設定のときファイルは生成されない' {
        Set-OpsLogConfig -LogFile '' -LogLevel 'INFO'
        Write-OpsLog -Level INFO -Message 'no-file'
        Test-Path -LiteralPath $script:tmpLog | Should -Be $false
    }
}
