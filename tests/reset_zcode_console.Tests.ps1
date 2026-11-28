# Exercise the real QuickEdit guard in a disposable Win32 console. Only the
# guard is copied into the fixture; no reset code or live profile is involved.
Describe 'ZCode reset console' {
    It 'leaves dry-run input mode untouched and clears QuickEdit on the input buffer' {
        $source = Join-Path $PSScriptRoot '..\src\windows\reset_zcode.ps1'
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        $guard = @($ast.EndBlock.Statements | Where-Object { $_.Extent.Text -match 'Ghost\.ResetConsole(?:Input)?\b' })
        $guard.Count | Should -Be 1

        $preamble = @'
param([string]$ResultPath)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -MemberDefinition '
    [DllImport("kernel32.dll")] public static extern bool AllocConsole();
    [DllImport("kernel32.dll")] public static extern bool FreeConsole();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)] public static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFileW(string name, int access, int share, IntPtr sec, int disposition, int flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(Microsoft.Win32.SafeHandles.SafeFileHandle handle, out int mode);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(Microsoft.Win32.SafeHandles.SafeFileHandle handle, int mode);
' -Name ResetConsoleFixture -Namespace Ghost.Tests
# Only this child detaches, so even if the caller has a console the test never
# changes its mode. A private console is required before any SetConsoleMode.
[void][Ghost.Tests.ResetConsoleFixture]::FreeConsole()
if (-not [Ghost.Tests.ResetConsoleFixture]::AllocConsole()) {
    [IO.File]::WriteAllText($ResultPath, '{"Available":false}')
    exit 0
}
$fixtureHandle = $null
try {
    $fixtureHandle = [Ghost.Tests.ResetConsoleFixture]::CreateFileW('CONIN$', 0xC0000000, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($fixtureHandle.IsInvalid) { throw "Fixture could not open CONIN`$: Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
    function Get-FixtureInputMode {
        $mode = 0
        if (-not [Ghost.Tests.ResetConsoleFixture]::GetConsoleMode($fixtureHandle, [ref]$mode)) {
            throw "Fixture could not read console input mode: Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
        return $mode
    }
    $seedMode = (Get-FixtureInputMode) -bor 0x00C0
    if (-not [Ghost.Tests.ResetConsoleFixture]::SetConsoleMode($fixtureHandle, $seedMode)) {
        throw "Fixture could not enable QuickEdit (mode $seedMode): Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    $before = Get-FixtureInputMode
'@
        $fixture = @(
            $preamble
            # PowerShell's host caches its original output handle. Capture
            # messages rather than paint text in the newly allocated console.
            '$DryRun = $true'
            '$planMessages = @(& {'
            $guard[0].Extent.Text
            '} 6>&1)'
            '$afterDryRun = Get-FixtureInputMode'
            '$DryRun = $false'
            '$resetMessages = @(& {'
            $guard[0].Extent.Text
            '} 6>&1)'
            @'
    $result = @{
        Available = $true
        Before = $before
        AfterDryRun = $afterDryRun
        AfterReset = (Get-FixtureInputMode)
        PlanMessages = @($planMessages | ForEach-Object { $_.ToString() })
        ResetMessages = @($resetMessages | ForEach-Object { $_.ToString() })
    }
    [IO.File]::WriteAllText($ResultPath, ($result | ConvertTo-Json -Compress))
} finally {
    if ($null -ne $fixtureHandle) { $fixtureHandle.Dispose() }
    [void][Ghost.Tests.ResetConsoleFixture]::FreeConsole()
}
'@
        ) -join "`r`n"
        $fixturePath = Join-Path $TestDrive 'console fixture.ps1'
        $resultPath = Join-Path $TestDrive 'console result.json'
        [IO.File]::WriteAllText($fixturePath, $fixture, [Text.UTF8Encoding]::new($true))

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ResultPath "{1}"' -f $fixturePath, $resultPath
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        try {
            $proc.StandardInput.Close()
            $stdout = $proc.StandardOutput.ReadToEndAsync()
            $stderr = $proc.StandardError.ReadToEndAsync()
            if (-not $proc.WaitForExit(30000)) {
                $proc.Kill()
                throw 'Console fixture timed out.'
            }
            $proc.ExitCode | Should -Be 0 -Because ($stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult())
        } finally {
            $proc.Dispose()
        }

        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if (-not $result.Available) { Set-ItResult -Skipped -Because 'Windows did not allocate a private console'; return }
        ($result.Before -band 0x0040) | Should -Be 0x0040 -Because 'the fixture must begin with QuickEdit enabled'
        $result.AfterDryRun | Should -Be $result.Before
        ($result.AfterReset -band 0x0040) | Should -Be 0
        $result.PlanMessages.Count | Should -Be 0
        $result.ResetMessages.Count | Should -Be 1
        $result.ResetMessages[0] | Should -Be '[console] QuickEdit disabled for this console (verified).'
        # ENABLE_EXTENDED_FLAGS is a control bit for SetConsoleMode.
        ($result.AfterReset -band (-bnot 0x00C0)) | Should -Be ($result.Before -band (-bnot 0x00C0))
    }
}
