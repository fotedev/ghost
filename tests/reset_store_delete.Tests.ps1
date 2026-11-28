# Use the real Windows PowerShell 5.1 -> Python bridge with disposable profiles.
# The ZCode fixture omits elevation/console setup and replaces process controls
# before running the original reset steps. No installed app is required.
Describe 'Windows reset store deletion' {
    BeforeAll {
        $windows = Join-Path $PSScriptRoot '..\src\windows'
        $utils = (Resolve-Path -LiteralPath (Join-Path $windows 'identity_utils.ps1')).Path
        . $utils
        $python = Get-PythonCommandInfo
        $fixtures = Join-Path $TestDrive 'Reset fixtures with spaces'
        [void][IO.Directory]::CreateDirectory($fixtures)
        $bom = [Text.UTF8Encoding]::new($true)
        $preamble = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($env:GHOST_RESET_TEST -ne '1') { throw 'Start this fixture through the test runner.' }
. $env:GHOST_RESET_TEST_UTILS
function Get-PythonCommandInfo { $env:GHOST_RESET_TEST_PYTHON }
function Start-Process { throw 'Unexpected Start-Process in reset fixture' }
function Stop-Process { throw 'Unexpected Stop-Process in reset fixture' }
function taskkill { throw 'Unexpected taskkill in reset fixture' }
function Get-CimInstance { throw 'Unexpected live process probe in reset fixture' }
'@
        function Read-ResetAst([string]$File) {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $windows $File), [ref]$tokens, [ref]$errors)
            if ($errors.Count -gt 0) { throw ($errors -join "`n") }
            return $ast
        }

        function Write-ResetFixtureFile([string]$Path, [string]$Text) {
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
            [IO.File]::WriteAllText($Path, $Text)
        }

        function Invoke-ResetFixture([string]$ScriptPath, [string]$Root, [string[]]$ScriptArgs = @()) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" {1}' -f $ScriptPath, ($ScriptArgs -join ' ')
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.WorkingDirectory = $Root
            foreach ($entry in @{ APPDATA = 'appdata'; LOCALAPPDATA = 'local'; USERPROFILE = 'home'; HOME = 'home'; TEMP = 'temp'; TMP = 'temp' }.GetEnumerator()) {
                $dir = Join-Path $Root $entry.Value
                [void][IO.Directory]::CreateDirectory($dir)
                $psi.EnvironmentVariables[$entry.Key] = $dir
            }
            $psi.EnvironmentVariables['GHOST_RESET_TEST'] = '1'
            $psi.EnvironmentVariables['GHOST_RESET_TEST_UTILS'] = $utils
            $psi.EnvironmentVariables['GHOST_RESET_TEST_PYTHON'] = $python
            $psi.EnvironmentVariables['PYTHONDONTWRITEBYTECODE'] = '1'
            $proc = [System.Diagnostics.Process]::Start($psi)
            try {
                $stdout = $proc.StandardOutput.ReadToEndAsync()
                $stderr = $proc.StandardError.ReadToEndAsync()
                if (-not $proc.WaitForExit(60000)) {
                    $proc.Kill()
                    throw "Reset fixture timed out: $ScriptPath"
                }
                [pscustomobject]@{
                    ExitCode = $proc.ExitCode
                    Output = $stdout.GetAwaiter().GetResult()
                    ErrorOutput = $stderr.GetAwaiter().GetResult()
                }
            } finally {
                $proc.Dispose()
            }
        }
    }

    It '<Suite>: forwards a relative backup label and journals present/missing stores' -ForEach @(
        @{ Suite = 'zcode'; Wrapper = 'Invoke-StoreDelete'; Action = 'delete' }
        @{ Suite = 'qoder'; Wrapper = 'Invoke-StoreDelete'; Action = 'rename' }
        @{ Suite = 'qoderwork'; Wrapper = 'Invoke-ClearBinaryIdentityStore'; Action = 'delete' }
        @{ Suite = 'minimax_opencode'; Wrapper = 'Invoke-StoreDelete'; Action = 'delete' }
    ) {
        if (-not $python) { Set-ItResult -Skipped -Because 'Python 3 is not installed'; return }
        $ast = Read-ResetAst "reset_$Suite.ps1"
        $functions = @($ast.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $_.Name -in @('Invoke-GhostCore', 'Get-AppRelativeBackupLabel', $Wrapper)
        })
        $functions.Count | Should -Be 3
        $scriptPath = Join-Path $fixtures "store-$Suite.ps1"
        $body = @'
$root = Join-Path $env:APPDATA 'profile with spaces'
$present = Join-Path $root 'session\Shared Storage'
$missing = Join-Path $root 'session\Shared Storage-wal'
$audit = @()
$actions = @(__WRAPPER__ -Paths @($present, $missing) -Action __ACTION__ `
    -BackupRoot (Join-Path $env:TEMP 'store backup') -Audit ([ref]$audit) -RootPath $root)
@{ Audit = $audit; Actions = $actions } | ConvertTo-Json -Depth 6 -Compress
'@
        $source = @($preamble; $functions.Extent.Text; $body.Replace('__WRAPPER__', $Wrapper).Replace('__ACTION__', $Action)) -join "`r`n"
        [IO.File]::WriteAllText($scriptPath, $source, $bom)
        $root = Join-Path $fixtures "stores $Suite"
        $present = Join-Path $root 'appdata\profile with spaces\session\Shared Storage'
        $backup = Join-Path $root 'temp\store backup\session\Shared Storage'
        Write-ResetFixtureFile $present 'fixture store bytes'

        $result = Invoke-ResetFixture -ScriptPath $scriptPath -Root $root
        $result.ExitCode | Should -Be 0 -Because ($result.Output + $result.ErrorOutput)
        $result.ErrorOutput | Should -BeNullOrEmpty
        $report = $result.Output | ConvertFrom-Json
        $report.Audit.Count | Should -Be 2
        $report.Audit[0].ok | Should -BeTrue
        $report.Audit[1].ok | Should -BeTrue
        $report.Audit[1].before | Should -Be 'missing'
        $report.Audit[1].after | Should -Be 'skipped'
        $report.Actions.Count | Should -Be 1
        $report.Actions[0].originalPath | Should -Be $present
        $report.Actions[0].backupPath | Should -Be $backup
        $report.Actions[0].action | Should -Be $Action
        [IO.File]::ReadAllText($backup) | Should -BeExactly 'fixture store bytes'
        Test-Path -LiteralPath $present | Should -BeFalse
        if ($Action -eq 'rename') {
            $report.Actions[0].renamedPath | Should -Be "$present.backup"
            [IO.File]::ReadAllText("$present.backup") | Should -BeExactly 'fixture store bytes'
        }
    }

    Context 'ZCode reset pipeline' {
        BeforeAll {
            $ast = Read-ResetAst 'reset_zcode.ps1'
            $removedFunctions = @('Stop-ZcodeTargetTree', 'Stop-QoderProcessesOnly', 'Stop-ZcodeQoderProcessesAggressive', 'Test-CaptchaWatchdogRunning', 'Get-ZcodeTargetMains')
            $statements = foreach ($node in $ast.EndBlock.Statements) {
                if ($node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $removedFunctions) { continue }
                $text = $node.Extent.Text
                if ($text -eq '. "$PSScriptRoot\identity_utils.ps1"' -or $text -eq 'Assert-Administrator' -or
                    $text -match 'Ghost\.ResetConsole|^\$zcodeIsAdmin\s*=|Start-Process powershell -Verb RunAs') { continue }
                $text
            }
            $processStubs = @'
function Test-CaptchaWatchdogRunning { return $false }
function Get-ZcodeTargetMains {
    $mains = @{}
    foreach ($label in $script:ZcodeAllLabels) { $mains[$label] = @() }
    return $mains
}
function Stop-ZcodeTargetTree { return $true }
function Stop-QoderProcessesOnly {
    Write-Host 'fixture: Qoder stop requested'
    return $true
}
'@
            $pipeline = Join-Path $fixtures 'ZCode pipeline.ps1'
            $source = @($ast.ParamBlock.Extent.Text; $preamble; $processStubs; $statements) -join "`r`n"
            [IO.File]::WriteAllText($pipeline, $source, $bom)
        }

        It 'marks Qoder out of scope in a clone dry run' {
            if (-not $python) { Set-ItResult -Skipped -Because 'Python 3 is not installed'; return }
            $root = Join-Path $fixtures 'dry run'
            $session = Join-Path $root 'appdata\ZCode-Third\session\SharedStorage'
            $qoder = Join-Path $root 'appdata\Qoder\Network\Cookies'
            Write-ResetFixtureFile $session 'keep session'
            Write-ResetFixtureFile $qoder 'keep Qoder'

            $result = Invoke-ResetFixture -ScriptPath $pipeline -Root $root -ScriptArgs @('-Target', 'Third', '-DryRun')
            $result.ExitCode | Should -Be 0 -Because ($result.Output + $result.ErrorOutput)
            $result.ErrorOutput | Should -BeNullOrEmpty
            $result.Output | Should -Match 'outside this reset target'
            $result.Output | Should -Not -Match 'Qoder processes would be killed'
            [IO.File]::ReadAllText($session) | Should -BeExactly 'keep session'
            [IO.File]::ReadAllText($qoder) | Should -BeExactly 'keep Qoder'
            Test-Path -LiteralPath (Join-Path $root 'appdata\ZCode-Third\ID_Backups') | Should -BeFalse
        }

        It '<Case>: completes step 27 with the expected Qoder scope' -ForEach @(
            @{ Case = 'clone'; Target = 'Third'; Roaming = 'ZCode-Third'; Data = 'ZCodeThirdHome\.zcode'; IncludeQoder = $false; Flags = @() }
            @{ Case = 'primary'; Target = 'Primary'; Roaming = 'ZCode'; Data = '.zcode'; IncludeQoder = $true; Flags = @() }
            @{ Case = 'primary without Qoder'; Target = 'Primary'; Roaming = 'ZCode'; Data = '.zcode'; IncludeQoder = $false; Flags = @('-SkipQoder') }
        ) {
            if (-not $python) { Set-ItResult -Skipped -Because 'Python 3 is not installed'; return }
            $root = Join-Path $fixtures $Case
            $roamingRoot = Join-Path $root "appdata\$Roaming"
            $dataRoot = Join-Path $root "home\$Data"
            $shared = Join-Path $roamingRoot 'session\SharedStorage'
            $chat = Join-Path $roamingRoot 'session\Local Storage\leveldb\chat'
            $planCache = Join-Path $dataRoot 'v2\coding-plan-cache.json'
            $qoderArgv = Join-Path $root 'home\.qoder\argv.json'
            $qoderCache = Join-Path $root 'home\.qoder\cache\keep.txt'
            $qoderCookies = Join-Path $root 'appdata\Qoder\Network\Cookies'
            Write-ResetFixtureFile $shared 'fixture shared store'
            Write-ResetFixtureFile $chat 'unchanged chat data'
            Write-ResetFixtureFile $planCache '{}'
            Write-ResetFixtureFile (Join-Path $dataRoot 'v2\setting.json') '{"webRemoteControlExternalRelayDevice":{"deviceSid":"old"}}'
            Write-ResetFixtureFile $qoderArgv '{"crash-reporter-id":"unchanged"}'
            Write-ResetFixtureFile $qoderCache 'fixture Qoder cache'
            Write-ResetFixtureFile $qoderCookies 'fixture Qoder cookies'

            $result = Invoke-ResetFixture -ScriptPath $pipeline -Root $root -ScriptArgs (@('-Target', $Target) + $Flags)
            $result.ExitCode | Should -Be 0 -Because ($result.Output + $result.ErrorOutput)
            $result.ErrorOutput | Should -BeNullOrEmpty
            $result.Output | Should -Match '(?m)^\[27/27\]'
            $result.Output | Should -Match '(?m)^Fail: 0\b'
            $result.Output | Should -Match 'ZCode/Qoder reset v1\.5 \[.+\] completed successfully\.'
            Test-Path -LiteralPath $shared | Should -BeFalse
            [IO.File]::ReadAllText($chat) | Should -BeExactly 'unchanged chat data'

            $backup = Get-ChildItem -LiteralPath (Join-Path $roamingRoot 'ID_Backups') -Directory
            $backupPath = Join-Path $backup.FullName 'session\SharedStorage'
            [IO.File]::ReadAllText($backupPath) | Should -BeExactly 'fixture shared store'
            $audit = Get-Content -LiteralPath (Join-Path $backup.FullName "audit_$($backup.Name).json") -Raw | ConvertFrom-Json
            ($audit | Where-Object file -eq $planCache).after | Should -Be 'deleted'
            ($audit | Where-Object file -eq $shared).after | Should -Be 'deleted'
            ($audit | Where-Object file -eq "$shared-wal").after | Should -Be 'skipped'
            $restore = Get-Content -LiteralPath (Join-Path $backup.FullName "restore_ZCode_$($backup.Name).ps1") -Raw
            $manifest = [regex]::Match($restore, '(?ms)^\$manifestJson = @''\r?\n(.*?)\r?\n''@').Groups[1].Value | ConvertFrom-Json
            ($manifest | Where-Object originalPath -eq $shared).backupPath | Should -Be $backupPath

            if ($IncludeQoder) {
                $result.Output | Should -Match 'fixture: Qoder stop requested'
                (Get-Content -LiteralPath $qoderArgv -Raw | ConvertFrom-Json).'crash-reporter-id' | Should -Match '^[a-f0-9-]{36}$'
                Test-Path -LiteralPath $qoderCache | Should -BeFalse
                Test-Path -LiteralPath $qoderCookies | Should -BeFalse
            } else {
                $result.Output | Should -Not -Match 'fixture: Qoder stop requested'
                [IO.File]::ReadAllText($qoderArgv) | Should -BeExactly '{"crash-reporter-id":"unchanged"}'
                [IO.File]::ReadAllText($qoderCache) | Should -BeExactly 'fixture Qoder cache'
                [IO.File]::ReadAllText($qoderCookies) | Should -BeExactly 'fixture Qoder cookies'
            }
        }
    }
}
