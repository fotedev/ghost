#Requires -Version 5.1
<#
diagnose_zcode_throttle.ps1 - explain ZCode "Reconnecting... x/10" and
"The system is busy" failures from the shared agent runtime log.

Verified root cause (2026-10-27): these are SERVER-SIDE Start Plan
admission controls, not a local fault and not a device/IP ban. The agent
log records model.main_turn.retry_start_plan_admission_busy while the
client's auto-recovery loop retries (maxAttempts 11 - the UI's "x/10"
counter; it recovers when any attempt gets through), and a turn.failed
carrying StartPlanBusyAutoRetryExhaustedError -> "model concurrency limit
exceeded" (providerCode 3009, code model_rate_limited) once every attempt
was refused - the UI's "automatic retries have reached the maximum count".
The Z.ai backend refuses NEW model streams while the Start Plan pool is
saturated; auth and billing keep working throughout (a real device/IP ban
surfaces as 401/403, never as "busy"). Zero occurrences on 2026-10-24..26,
then bursty events on 10-27 - and DIFFERENT accounts failed in the same
minute, so the limit sits on the plan tier (or the machine's aggregate
concurrency), not on one account.

This tool is strictly read-only. It parses the SHARED agent runtime JSONL
logs at ~\.zcode\cli\log\zcode-<date>.jsonl - every instance (Primary +
clones) writes there, because the CLI resolves ~ via the real user profile
and the HOME override never reaches it on Windows - so events cannot be
attributed to a single instance; correlate the timeline with how many
instances were running at each burst.

Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\diagnose_zcode_throttle.ps1          # last 2 days
  ... -Days 7                                                                                    # wider window
#>
param(
    [ValidateRange(1, 30)]
    [int]$Days = 2
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$logDir = Join-Path $env:USERPROFILE '.zcode\cli\log'

function Write-Hdr([string]$Text) {
    Write-Output ''
    Write-Output ('==== ' + $Text + ' ====')
}

# Safe nested property read - PS 5.1 has no ?. operator and a missing
# property along the path must not throw. Returns '' when anything is absent.
function Get-JsonPath([string]$Path, $Node) {
    $cur = $Node
    foreach ($seg in $Path.Split('.')) {
        if ($null -eq $cur) { return '' }
        $p = $cur.PSObject.Properties[$seg]
        if ($null -eq $p) { return '' }
        $cur = $p.Value
    }
    if ($null -eq $cur) { return '' }
    return [string]$cur
}

function Convert-ToLocal([string]$Iso) {
    if ($Iso -eq '') { return '' }
    try {
        return [DateTimeOffset]::Parse($Iso).LocalDateTime.ToString('MM-dd HH:mm:ss')
    } catch {
        return $Iso
    }
}

function Get-ShortSession([string]$SessionId) {
    if ($SessionId.Length -gt 6) { return ('...' + $SessionId.Substring($SessionId.Length - 6)) }
    return $SessionId
}

$Dates = @(0..($Days - 1) | ForEach-Object { (Get-Date).Date.AddDays(-$_).ToString('yyyy-MM-dd') })

$Retries = @()    # objects: TsLocal, SessionShort, Day
$Failures = @()   # objects: TsLocal, SessionShort, Day, Exhausted, RateLimited, Cancelled, ProviderCode, Model, Attempts
$ProviderCodes = @{}
$ModelsSeen = @{}
$filesScanned = 0
$script:SawLogs = $false

# Classify one turn.failed line: walk the error -> cause -> cause chain
# collecting the failure class, provider code, model and attempt ceiling.
function Read-FailureLine($Json, [string]$Line) {
    $exhausted = $false; $rateLimited = $false; $cancelled = $false
    $providerCode = ''; $model = ''; $attempts = ''
    $errNode = $null
    $p = $Json.PSObject.Properties['error']
    if ($null -ne $p) { $errNode = $p.Value }
    $node = $errNode
    for ($depth = 0; $depth -lt 4 -and $null -ne $node; $depth++) {
        $name = Get-JsonPath 'name' $node
        $code = Get-JsonPath 'code' $node
        if ($name -eq 'StartPlanBusyAutoRetryExhaustedError') { $exhausted = $true }
        if ($code -eq 'model_rate_limited') { $rateLimited = $true }
        if ($code -eq 'TURN_CANCELLED' -or $code -eq 'model_request_cancelled') { $cancelled = $true }
        $pc = Get-JsonPath 'context.providerCode' $node
        if ($pc -ne '' -and $providerCode -eq '') { $providerCode = $pc }
        $mid = Get-JsonPath 'context.modelId' $node
        if ($mid -ne '' -and $model -eq '') { $model = $mid }
        $att = Get-JsonPath 'context.maxAttempts' $node
        if ($att -ne '' -and $attempts -eq '') { $attempts = $att }
        $next = $null
        $c = $node.PSObject.Properties['cause']
        if ($null -ne $c) { $next = $c.Value }
        $node = $next
    }
    if (-not ($exhausted -or $rateLimited -or $cancelled)) {
        # Parse fallback (oversized/odd line): regex the same facts out.
        if ($Line -match 'StartPlanBusyAutoRetryExhaustedError') { $exhausted = $true }
        if ($Line -match '"code":"model_rate_limited"') { $rateLimited = $true }
        if ($Line -match '"code":"(TURN_CANCELLED|model_request_cancelled)"') { $cancelled = $true }
        if ($Line -match '"providerCode":"(\d+)"') { $providerCode = $Matches[1] }
        if ($Line -match '"modelId":"([^"]+)"') { $model = $Matches[1] }
        if ($Line -match '"maxAttempts":(\d+)') { $attempts = $Matches[1] }
    }
    return [pscustomobject]@{
        Exhausted = $exhausted; RateLimited = $rateLimited; Cancelled = $cancelled
        ProviderCode = $providerCode; Model = $model; Attempts = $attempts
    }
}

Write-Hdr ('[1] Start Plan admission throttling, last ' + $Days + ' day(s)')
Write-Output ('-- shared agent log: ' + $logDir + '  (all instances write here)')
if (-not (Test-Path $logDir)) {
    Write-Output '   no agent log dir - the CLI never ran on this profile'
}
foreach ($date in $Dates) {
    $logFile = Join-Path $logDir ('zcode-' + $date + '.jsonl')
    if (-not (Test-Path $logFile)) { continue }
    $filesScanned++
    $script:SawLogs = $true
    $lines = $null
    try {
        # -Encoding UTF8: the JSONL is UTF-8; PS 5.1 would otherwise misread
        # every multibyte character as two ANSI characters.
        $lines = Get-Content -LiteralPath $logFile -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Output ('   log unreadable (in use?): ' + (Split-Path $logFile -Leaf))
        continue
    }
    $dayEvents = @()
    $dayRetries = 0; $dayExhausted = 0; $dayOtherFails = 0
    foreach ($line in $lines) {
        if ($line -notmatch '"event":"(model\.main_turn\.retry_start_plan_admission_busy|turn\.failed)"') { continue }
        $json = $null
        try { $json = $line | ConvertFrom-Json -ErrorAction Stop } catch { $json = $null }
        $session = Get-ShortSession (Get-JsonPath 'sessionId' $json)
        $tsLocal = Convert-ToLocal (Get-JsonPath 'timestamp' $json)
        if ($line -match '"event":"model\.main_turn\.retry_start_plan_admission_busy"') {
            $dayRetries++
            $dayEvents += [pscustomobject]@{ Ts = $tsLocal; Text = ('admission-busy retry            (session ' + $session + ')') }
            $Retries += [pscustomobject]@{ TsLocal = $tsLocal; SessionShort = $session; Day = $date }
        } else {
            $cls = $null
            if ($null -ne $json) {
                $cls = Read-FailureLine $json $line
            } else {
                $cls = Read-FailureLine ([pscustomobject]@{}) $line
            }
            $tag = ''
            if ($cls.Exhausted) { $tag = 'EXHAUSTED recovery loop' }
            elseif ($cls.RateLimited) { $tag = 'rate-limited (turn failed)' }
            elseif ($cls.Cancelled) { $tag = 'cancelled (user)' }
            else { $tag = 'other failure' }
            $detail = ''
            if ($cls.ProviderCode -ne '') { $detail = ' | providerCode ' + $cls.ProviderCode }
            if ($cls.Model -ne '') { $detail = $detail + ' | ' + $cls.Model }
            if ($cls.Attempts -ne '') { $detail = $detail + ' (max ' + $cls.Attempts + ' attempts)' }
            $turnNo = Get-JsonPath 'context.turnNumber' $json
            $turnTxt = ''
            if ($turnNo -ne '') { $turnTxt = ', turn ' + $turnNo }
            if ($cls.Exhausted) { $dayExhausted++ } elseif (-not $cls.Cancelled) { $dayOtherFails++ }
            $dayEvents += [pscustomobject]@{ Ts = $tsLocal; Text = ('FAILED turn ' + $tag.PadRight(38) + ' (session ' + $session + $turnTxt + ')' + $detail) }
            $Failures += [pscustomobject]@{
                TsLocal = $tsLocal; SessionShort = $session; Day = $date
                Exhausted = [bool]$cls.Exhausted; RateLimited = [bool]$cls.RateLimited; Cancelled = [bool]$cls.Cancelled
                ProviderCode = $cls.ProviderCode; Model = $cls.Model; Attempts = $cls.Attempts
            }
            if ($cls.ProviderCode -ne '') {
                if (-not $ProviderCodes.ContainsKey($cls.ProviderCode)) { $ProviderCodes[$cls.ProviderCode] = 0 }
                $ProviderCodes[$cls.ProviderCode]++
            }
            if ($cls.Model -ne '') { $ModelsSeen[$cls.Model] = $true }
        }
    }
    if ($dayEvents.Count -eq 0) {
        Write-Output ('-- ' + $date + '.jsonl: clean - no admission/retry events')
        continue
    }
    Write-Output ('-- ' + $date + '.jsonl: ' + $dayRetries + ' admission-busy retry(ies), ' + $dayExhausted + ' exhausted loop(s), ' + $dayOtherFails + ' other failure(s)')
    foreach ($e in ($dayEvents | Sort-Object { if ($_.Ts -eq '') { '9999' } else { $_.Ts } })) {
        Write-Output ('   ' + $e.Ts + '  ' + $e.Text)
    }
}
if (-not $script:SawLogs) {
    Write-Output ('   no zcode-*.jsonl logs for the scanned dates (' + ($Dates -join ', ') + ')')
}

# ---- [2] hourly histogram ----------------------------------------------------
Write-Hdr '[2] Hourly histogram (local time)'
$hours = @{}
foreach ($r in $Retries) {
    if ($r.TsLocal.Length -ge 8) {
        $h = $r.TsLocal.Substring(0, 8) + ':00'
        if (-not $hours.ContainsKey($h)) { $hours[$h] = @{ R = 0; F = 0 } }
        $hours[$h].R++
    }
}
foreach ($f in $Failures) {
    if ($f.TsLocal.Length -ge 8 -and $f.Exhausted) {
        $h = $f.TsLocal.Substring(0, 8) + ':00'
        if (-not $hours.ContainsKey($h)) { $hours[$h] = @{ R = 0; F = 0 } }
        $hours[$h].F++
    }
}
if ($hours.Count -eq 0) {
    Write-Output '   no throttled hours in the scanned window'
} else {
    foreach ($h in ($hours.Keys | Sort-Object)) {
        $bar = ''
        for ($i = 0; $i -lt ($hours[$h].R + $hours[$h].F); $i++) { $bar = $bar + '#' }
        Write-Output ('   ' + $h + '  retries ' + $hours[$h].R + ', exhausted ' + $hours[$h].F + '  ' + $bar)
    }
}

# ---- [3] per-session rollup ----------------------------------------------------
Write-Hdr '[3] Per-session rollup'
$sessions = @{}
foreach ($r in $Retries) {
    if (-not $sessions.ContainsKey($r.SessionShort)) {
        $sessions[$r.SessionShort] = @{ R = 0; F = 0; First = $r.TsLocal; Last = $r.TsLocal }
    }
    $sessions[$r.SessionShort].R++
    if ($r.TsLocal -lt $sessions[$r.SessionShort].First) { $sessions[$r.SessionShort].First = $r.TsLocal }
    if ($r.TsLocal -gt $sessions[$r.SessionShort].Last) { $sessions[$r.SessionShort].Last = $r.TsLocal }
}
foreach ($f in $Failures) {
    if (-not $sessions.ContainsKey($f.SessionShort)) {
        $sessions[$f.SessionShort] = @{ R = 0; F = 0; First = $f.TsLocal; Last = $f.TsLocal }
    }
    if ($f.Exhausted) { $sessions[$f.SessionShort].F++ }
    if ($f.TsLocal -lt $sessions[$f.SessionShort].First) { $sessions[$f.SessionShort].First = $f.TsLocal }
    if ($f.TsLocal -gt $sessions[$f.SessionShort].Last) { $sessions[$f.SessionShort].Last = $f.TsLocal }
}
if ($sessions.Count -eq 0) {
    Write-Output '   no affected sessions'
} else {
    foreach ($s in ($sessions.Keys | Sort-Object)) {
        $d = $sessions[$s]
        Write-Output ('   ' + $s + '  retries ' + $d.R + ', exhausted ' + $d.F + '  (first ' + $d.First + ', last ' + $d.Last + ')')
    }
}

# ---- [4] verdict ----------------------------------------------------------------
Write-Hdr '[4] Verdict'
$exhaustedTotal = @($Failures | Where-Object { $_.Exhausted }).Count
$retriesTotal = $Retries.Count
if ($exhaustedTotal -gt 0 -or $retriesTotal -gt 0) {
    Write-Output ('   Start Plan admission throttling found: ' + $retriesTotal + ' refused admission retry(ies), ' + $exhaustedTotal + ' exhausted recovery loop(s), ' + $filesScanned + ' log file(s) scanned.')
    if ($ProviderCodes.Count -gt 0) {
        $codes = ($ProviderCodes.Keys | Sort-Object | ForEach-Object { $_ + ' x' + $ProviderCodes[$_] }) -join ', '
        Write-Output ('   provider codes: ' + $codes)
    }
    if ($ModelsSeen.Count -gt 0) {
        Write-Output ('   model(s) refused: ' + (($ModelsSeen.Keys | Sort-Object) -join ', '))
    }
    Write-Output '   - "Reconnecting... x/10" is the client''s own auto-recovery loop (max'
    Write-Output '     11 attempts) against the busy admission: it recovers when any attempt'
    Write-Output '     gets through, and only fails ("automatic retries have reached the'
    Write-Output '     maximum count") when every attempt is refused.'
    Write-Output '   - providerCode 3009 "model concurrency limit exceeded" is the Z.ai'
    Write-Output '     backend refusing NEW model streams while the Start Plan pool is'
    Write-Output '     saturated. Auth and billing keep working - a real device/IP ban'
    Write-Output '     surfaces as 401/403, never as "busy". This is NOT a ban.'
    Write-Output '   - Different accounts failing in the same minute put the limit on the'
    Write-Output '     plan tier (or this machine''s aggregate concurrency), not one account.'
    Write-Output '   Discrimination test for the next incident - close every instance'
    Write-Output '   except ONE and retry the same task:'
    Write-Output '   - works again   -> the limit is this machine''s aggregate concurrency:'
    Write-Output '     run fewer instances / fewer parallel subagents at once.'
    Write-Output '   - still fails   -> the pool itself is saturated: wait 10-15 min,'
    Write-Output '     switch model (separate pool), or use a tier with higher admission'
    Write-Output '     priority.'
    Write-Output '   Mitigations: stagger heavy parallel work off the burst hours above and'
    Write-Output '   keep fewer instances during peaks - every clone is still a Start Plan'
    Write-Output '   account behind the same admission control.'
} else {
    Write-Output ('   no Start Plan throttling in the scanned window (last ' + $Days + ' day(s)).')
    Write-Output '   If the UI still shows "Reconnecting x/10" right now: it may recover on'
    Write-Output '   its own (the loop retries 11 times), or the failure has a different'
    Write-Output '   cause - check the latest turn.failed entries in section [1] and'
    Write-Output '   docs/troubleshooting.md.'
}
Write-Output ''
