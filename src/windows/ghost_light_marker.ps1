#Requires -Version 5.1
# GHOST light-worker PID-marker contract - the ONE copy of the marker IO that
# makes headless light workers visible to the status tools.
#
# Every light-worker launcher (launch_zcode_cli_light.ps1,
# launch_opencode_cli_light.ps1, launch_cline_cli_light.ps1,
# launch_claude_code_light.ps1 and the Linux .sh twin) writes ONE JSON marker
# into its clone home for the whole worker run and removes it on exit:
#
#     <clone-home>\.ghost-light-worker.json
#       { "suite", "instance", "pid", "mode", "startedAt" }   (key names only)
#
# The pid is the LAUNCHER's own process id ($PID) - the launcher stays alive
# in the foreground for the whole worker run in every mode (REPL, -Prompt,
# -Server, -Acp), so it is the honest liveness sentinel. Readers must treat a
# marker as RUNNING only when its pid is alive AND is a PowerShell/pwsh
# process (pid-recycling guard); anything else is a stale marker from a hard
# kill and reads as not-running.
#
# Key names only, never values that could hold secrets - same audit
# convention as the JSONL audit files.

function Write-GhostLightMarker {
    <#
    .SYNOPSIS
      Write/refresh the light-worker marker for one clone home. Warns loudly
      (never blocks) when a DIFFERENT live launcher already holds the marker -
      two light workers on one clone home share one store by design.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('zcode', 'opencode', 'cline', 'claudecode')][string]$Suite,
        [Parameter(Mandatory = $true)][string]$Instance,
        [Parameter(Mandatory = $true)][ValidateSet('repl', 'prompt', 'server', 'acp')][string]$Mode
    )
    # Stale-marker / concurrent-worker honesty: a live foreign pid is warned
    # about, the marker is still refreshed (last writer wins - the reader
    # only ever reports one worker per clone home).
    $existing = Get-GhostLightWorkerState -Path $Path
    if ($existing -and $existing.Alive -and $existing.Pid -ne $PID) {
        Write-Warning ("[light] another light worker appears RUNNING on this home (pid {0}, started {1}) - refreshing its marker." -f $existing.Pid, $existing.StartedAt)
    }
    $payload = [ordered]@{
        suite     = $Suite
        instance  = $Instance
        pid       = $PID
        mode      = $Mode
        startedAt = (Get-Date).ToString('o')
    }
    try {
        $json = $payload | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine)
    } catch {
        # Marker IO is best-effort visibility - a read-only clone home must
        # never stop the worker itself.
        Write-Warning ("[light] could not write the light-worker marker ({0}): {1}" -f $Path, $_.Exception.Message)
    }
}

function Remove-GhostLightMarker {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
    } catch { }
}

function Get-GhostLightWorkerState {
    <#
    .SYNOPSIS
      Read one light-worker marker. Returns $null when absent/unreadable.
      Returns a pscustomobject with .Alive set by PID liveness + a
      PowerShell/pwsh process-name sanity check (a recycled pid must not read
      as a running worker).
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch { return $null }
    if ($null -eq $json -or -not $json.pid) { return $null }

    $alive = $false
    try {
        $proc = Get-Process -Id ([int]$json.pid) -ErrorAction SilentlyContinue
        if ($proc -and ($proc.ProcessName -ieq 'powershell' -or $proc.ProcessName -ieq 'pwsh')) { $alive = $true }
    } catch { }

    return [pscustomobject]@{
        Suite     = [string]$json.suite
        Instance  = [string]$json.instance
        Pid       = [int]$json.pid
        Mode      = [string]$json.mode
        StartedAt = [string]$json.startedAt
        Alive     = $alive
    }
}
