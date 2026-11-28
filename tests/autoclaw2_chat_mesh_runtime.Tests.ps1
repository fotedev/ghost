Describe 'AutoClaw2 chat runtime probe' {
    BeforeAll {
        $script:Probe = Join-Path $PSScriptRoot '..\tools\inspect_autoclaw2_chat_runtime.ps1'
    }

    It 'uses the observed profile marker rather than the color of the exe' {
        $roaming = Join-Path $env:APPDATA 'AutoClaw-oversea-official'
        $procs = @(
            [pscustomobject]@{ ProcessId = 101; ParentProcessId = 9; CommandLine = 'AutoClaw2-Blue.exe' }
            [pscustomobject]@{ ProcessId = 102; ParentProcessId = 101; CommandLine = "AutoClaw2-Blue.exe --type=renderer --user-data-dir=`"$roaming`"" }
        )
        # pwsh 7.6 unwraps a single-element JSON array on ConvertFrom-Json;
        # @() normalizes it back so indexing is safe on every host.
        $busy = @((& $script:Probe -Processes $procs) | ConvertFrom-Json)
        $busy.Count | Should -Be 1
        $busy[0] | Should -Be 'Primary'
    }

    It 'queues every target when a process cannot be attributed' {
        $procs = @([pscustomobject]@{ ProcessId = 101; ParentProcessId = 9; CommandLine = 'AutoClaw2-Blue.exe' })
        $busy = @((& $script:Probe -Processes $procs) | ConvertFrom-Json)
        $busy.Count | Should -Be 6
    }

    It 'reports no busy profiles when the family is absent' {
        (& $script:Probe -Processes @()) | Should -Be '[]'
    }
}
