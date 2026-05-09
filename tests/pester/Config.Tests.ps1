#Requires -Version 7
<#
.SYNOPSIS
    lib/powershell/Config.psm1 のユニットテスト（Pester 5+）。

    各テストでは一時ディレクトリを `-RepoRoot` で渡し、実リポジトリの
    config を読み込まないように隔離する。
#>

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    Import-Module (Join-Path $repoRoot 'lib' 'powershell' 'Config.psm1') -Force
}

Describe 'Get-OpsConfig' {

    BeforeEach {
        # テスト用の一時 repo root を作成（毎テスト独立）
        $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:TestRoot '.git') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:TestRoot 'config' 'common') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:TestRoot 'config' 'dev')    -Force | Out-Null
    }

    AfterEach {
        if ($script:TestRoot -and (Test-Path -LiteralPath $script:TestRoot)) {
            Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
        }
    }

    It 'common/ops.conf からキーを読み込む' {
        Set-Content -Path (Join-Path $script:TestRoot 'config' 'common' 'ops.conf') `
            -Value "Region = ap-northeast-1`nWait = true"
        $cfg = Get-OpsConfig -Name 'foo' -Env 'common' -RepoRoot $script:TestRoot
        $cfg['Region'] | Should -Be 'ap-northeast-1'
        $cfg['Wait']   | Should -Be 'true'
    }

    It 'common/<name>.conf が common/ops.conf を上書きする' {
        Set-Content -Path (Join-Path $script:TestRoot 'config' 'common' 'ops.conf') -Value 'Region = ap-northeast-1'
        Set-Content -Path (Join-Path $script:TestRoot 'config' 'common' 'foo.conf') -Value 'Region = us-east-1'
        $cfg = Get-OpsConfig -Name 'foo' -Env 'common' -RepoRoot $script:TestRoot
        $cfg['Region'] | Should -Be 'us-east-1'
    }

    It 'env/<name>.conf が common/<name>.conf を上書きする' {
        Set-Content -Path (Join-Path $script:TestRoot 'config' 'common' 'foo.conf') -Value 'Region = us-east-1'
        Set-Content -Path (Join-Path $script:TestRoot 'config' 'dev'    'foo.conf') -Value 'Region = eu-west-1'
        $cfg = Get-OpsConfig -Name 'foo' -Env 'dev' -RepoRoot $script:TestRoot
        $cfg['Region'] | Should -Be 'eu-west-1'
    }

    It 'env/ops.conf が common/<name>.conf を上書きする' {
        Set-Content -Path (Join-Path $script:TestRoot 'config' 'common' 'foo.conf') -Value 'Wait = false'
        Set-Content -Path (Join-Path $script:TestRoot 'config' 'dev'    'ops.conf') -Value 'Wait = true'
        $cfg = Get-OpsConfig -Name 'foo' -Env 'dev' -RepoRoot $script:TestRoot
        $cfg['Wait'] | Should -Be 'true'
    }

    It 'env が common のときは common/ のみ読み込まれる' {
        Set-Content -Path (Join-Path $script:TestRoot 'config' 'common' 'foo.conf') -Value 'Region = us-east-1'
        Set-Content -Path (Join-Path $script:TestRoot 'config' 'dev'    'foo.conf') -Value 'Region = eu-west-1'
        $cfg = Get-OpsConfig -Name 'foo' -Env 'common' -RepoRoot $script:TestRoot
        $cfg['Region'] | Should -Be 'us-east-1'
    }

    It 'コメント行と空行を無視する' {
        $content = @'
# 行頭コメント

Region = ap-northeast-1

# 別のコメント
Wait = true
'@
        Set-Content -Path (Join-Path $script:TestRoot 'config' 'common' 'foo.conf') -Value $content
        $cfg = Get-OpsConfig -Name 'foo' -Env 'common' -RepoRoot $script:TestRoot
        $cfg.Count    | Should -Be 2
        $cfg['Region']| Should -Be 'ap-northeast-1'
    }

    It '値の前後の引用符を除去する（ダブル / シングル両方）' {
        Set-Content -Path (Join-Path $script:TestRoot 'config' 'common' 'foo.conf') -Value @'
Description = "weekly backup"
Note        = 'with spaces'
'@
        $cfg = Get-OpsConfig -Name 'foo' -Env 'common' -RepoRoot $script:TestRoot
        $cfg['Description'] | Should -Be 'weekly backup'
        $cfg['Note']        | Should -Be 'with spaces'
    }

    It '前後空白を trim する' {
        Set-Content -Path (Join-Path $script:TestRoot 'config' 'common' 'foo.conf') -Value '   Region   =   ap-northeast-1   '
        $cfg = Get-OpsConfig -Name 'foo' -Env 'common' -RepoRoot $script:TestRoot
        $cfg['Region'] | Should -Be 'ap-northeast-1'
    }

    It 'ファイルが存在しない場合は空のハッシュテーブルを返す' {
        $cfg = Get-OpsConfig -Name 'no-such-script' -Env 'common' -RepoRoot $script:TestRoot
        $cfg.Count | Should -Be 0
    }

    It '不正な行（= がない）は黙ってスキップする' {
        Set-Content -Path (Join-Path $script:TestRoot 'config' 'common' 'foo.conf') -Value @'
Region = ap-northeast-1
this line is malformed
Wait = true
'@
        $cfg = Get-OpsConfig -Name 'foo' -Env 'common' -RepoRoot $script:TestRoot
        $cfg.Count    | Should -Be 2
        $cfg['Region']| Should -Be 'ap-northeast-1'
        $cfg['Wait']  | Should -Be 'true'
    }
}
