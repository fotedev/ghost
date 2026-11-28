Describe 'AutoClaw2 chat handoff gate' {
    BeforeAll {
        $worker = Join-Path $PSScriptRoot '..\tools\watch_autoclaw2_chat_sync.ps1'
        $t = $e = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($worker, [ref]$t, [ref]$e)
        if ($e.Count) { throw ($e | Out-String) }
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ChatHandoffExitCode' }, $true)
        Invoke-Expression $fn.Extent.Text
        function New-Verdict([string]$Status,[bool]$Open,[bool]$Ready,[string]$Reason='') {
            @{code=0; report=[pscustomobject]@{targets=[pscustomobject]@{
                Primary=[pscustomobject]@{status=$Status; open=$Open; ready=$Ready; reason=$Reason}
            }}}
        }
    }

    It 'refuses launch on a successful but queued sync pass' {
        Get-ChatHandoffExitCode (New-Verdict queued $true $false 'target-running') 'Primary' | Should -Be 2
    }

    It 'does not permit a new launch when Primary is open and current' {
        Get-ChatHandoffExitCode (New-Verdict up-to-date $true $false) 'Primary' | Should -Be 2
    }

    It 'retries while a source is temporarily unreadable' {
        Get-ChatHandoffExitCode (New-Verdict queued $false $false 'active-source-unreadable') 'Primary' | Should -Be 2
    }

    It 'permits launch only after a positive closed-target verification' {
        Get-ChatHandoffExitCode (New-Verdict applied $false $true) 'Primary' | Should -Be 0
        Get-ChatHandoffExitCode (New-Verdict up-to-date $false $true) 'Primary' | Should -Be 0
        Get-ChatHandoffExitCode (New-Verdict up-to-date $false $false) 'Primary' | Should -Be 1
    }

    It 'does not open on an account skip, missing result or hard error' {
        Get-ChatHandoffExitCode (New-Verdict skipped $false $false 'not-signed-in') 'Primary' | Should -Be 1
        Get-ChatHandoffExitCode @{ code=0; report=$null } 'Primary' | Should -Be 1
        Get-ChatHandoffExitCode @{ code=2; report=@{refused='mesh-busy'} } 'Primary' | Should -Be 2
    }

    It 'dispatches the stock exe only after the handoff gate, without killing apps' {
        $launcher = Join-Path $PSScriptRoot '..\tools\launch_autoclaw2_primary_sync.ps1'
        $raw = Get-Content -LiteralPath $launcher -Raw
        $raw | Should -Match 'if \(-not \$ready\)[\s\S]+\[Diagnostics\.Process\]::Start\(\$start\)'
        $raw | Should -Match '-RunOnce -Target Primary\s+`\s+-RequireConverged'
        $raw | Should -Not -Match 'Stop-Process|taskkill|CloseMainWindow'
    }
}
