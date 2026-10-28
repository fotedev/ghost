#Requires -Version 5.1
# ZCode per-clone Telegram bot guardian (UI-assisted model).
# See docs/ZCODE_TELEGRAM_BOTS.md for the full contract.
param(
    [ValidateSet('Primary', 'Second', 'Third', 'Fourth', 'Fifth', 'Sixth', 'All')]
    [string]$Target = 'All',
    [switch]$VerifyOnly,
    [switch]$Fix
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\windows\identity_utils.ps1')

$UserProfile = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($UserProfile)) { $UserProfile = [Environment]::GetFolderPath('UserProfile') }
$AppData = $env:APPDATA
if ([string]::IsNullOrWhiteSpace($AppData)) { $AppData = Join-Path $UserProfile 'AppData\Roaming' }

$BotIdsByTarget = @{
    'Primary' = @{ ZCode = (Join-Path $UserProfile '.zcode'); Roaming = (Join-Path $AppData 'ZCode'); Home = $UserProfile }
    'Second'  = @{ ZCode = (Join-Path $UserProfile 'ZCodeSecondHome\.zcode'); Roaming = (Join-Path $AppData 'ZCode-Second'); Home = (Join-Path $UserProfile 'ZCodeSecondHome') }
    'Third'   = @{ ZCode = (Join-Path $UserProfile 'ZCodeThirdHome\.zcode'); Roaming = (Join-Path $AppData 'ZCode-Third'); Home = (Join-Path $UserProfile 'ZCodeThirdHome') }
    'Fourth'  = @{ ZCode = (Join-Path $UserProfile 'ZCodeFourthHome\.zcode'); Roaming = (Join-Path $AppData 'ZCode-Fourth'); Home = (Join-Path $UserProfile 'ZCodeFourthHome') }
    'Fifth'   = @{ ZCode = (Join-Path $UserProfile 'ZCodeFifthHome\.zcode');  Roaming = (Join-Path $AppData 'ZCode-Fifth');  Home = (Join-Path $UserProfile 'ZCodeFifthHome') }
    'Sixth'   = @{ ZCode = (Join-Path $UserProfile 'ZCodeSixthHome\.zcode');  Roaming = (Join-Path $AppData 'ZCode-Sixth');  Home = (Join-Path $UserProfile 'ZCodeSixthHome') }
}

function Get-BotCredentialSha8 {
    param([string]$CredentialsPath, [string]$CredentialRef)
    if (-not (Test-Path -LiteralPath $CredentialsPath)) { return '' }
    try { $creds = Get-Content -LiteralPath $CredentialsPath -Raw | ConvertFrom-Json }
    catch { return '' }
    $prop = $creds.PSObject.Properties[$CredentialRef]
    if ($null -eq $prop) { return '' }
    $val = [string]$prop.Value
    if ([string]::IsNullOrEmpty($val)) { return '' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($val)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) }
    finally { if ($sha) { $sha.Dispose() } }
    return ([BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()).Substring(0, 8)
}

function Get-HomeTelegramBots {
    param([string]$Name, [hashtable]$Paths)
    $result = @()
    $credsPath = Join-Path $Paths.ZCode 'v2\credentials.json'
    foreach ($cfgName in @('v2\bot-config.json', 'v2\bot-config.v3.json')) {
        $cfgPath = Join-Path $Paths.ZCode $cfgName
        if (-not (Test-Path -LiteralPath $cfgPath)) { continue }
        try { $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json }
        catch { continue }
        if ($null -eq $cfg.bots) { continue }
        foreach ($bot in @($cfg.bots)) {
            if ($bot.provider -ne 'telegram') { continue }
            $sha = Get-BotCredentialSha8 -CredentialsPath $credsPath -CredentialRef ([string]$bot.credentialRef)
            $result += [pscustomobject]@{
                Home          = $Name
                File          = $cfgName
                Id            = [string]$bot.id
                CredentialRef = [string]$bot.credentialRef
                Enabled       = [bool]$bot.enabled
                CredSha8      = $sha
            }
        }
    }
    return $result
}

function Get-AllTelegramBots {
    $all = @()
    foreach ($name in @('Primary', 'Second', 'Third', 'Fourth', 'Fifth', 'Sixth')) {
        $rows = Get-HomeTelegramBots -Name $name -Paths $BotIdsByTarget[$name]
        if ($rows) { $all += $rows }
    }
    return $all
}

# Dot-source guard: when this file is dot-sourced (unit tests), define the
# functions and the path map only - the live scan and the exit codes below
# must never run inside the importing session.
if ($MyInvocation.InvocationName -eq '.') { return }

$allBots = Get-AllTelegramBots
Write-Host '=== Telegram bot fingerprint (sha8 only, no secrets) ===' -ForegroundColor Cyan
foreach ($row in $allBots) {
    Write-Host ('{0} [{1}] id={2} enabled={3} sha8={4}' -f $row.Home, $row.File, $row.Id, $row.Enabled, $row.CredSha8)
}

$failures = @()
# A Primary with zero telegram rows at all is a legitimate setup (a clone may
# be the only home carrying a bot) - the -Fix final assertion below must not
# fail on it.
$hadPrimaryRows = (@($allBots | Where-Object { $_.Home -eq 'Primary' }).Count -gt 0)
$primaryRows = @($allBots | Where-Object { $_.Home -eq 'Primary' -and $_.CredSha8 -ne '' })
$primarySha8 = ''
$primaryId = ''
if ($primaryRows.Count -gt 0) {
    $primarySha8 = $primaryRows[0].CredSha8
    $primaryId = $primaryRows[0].Id
}

foreach ($name in @('Primary', 'Second', 'Third', 'Fourth', 'Fifth', 'Sixth')) {
    $homeRows = @($allBots | Where-Object { $_.Home -eq $name })
    if ($homeRows.Count -eq 0) { continue }
    $flags = @($homeRows | ForEach-Object { $_.Enabled } | Select-Object -Unique)
    if ($flags.Count -gt 1) {
        $detail = ($homeRows | ForEach-Object { ('{0}={1}' -f $_.File, $_.Enabled) }) -join ', '
        $failures += ('{0}: v2/v3 enabled mismatch ({1})' -f $name, $detail)
    }
}

foreach ($name in @('Second', 'Third', 'Fourth', 'Fifth', 'Sixth')) {
    $homeRows = @($allBots | Where-Object { $_.Home -eq $name })
    foreach ($row in $homeRows) {
        if ($row.Enabled -and $primarySha8 -ne '' -and $row.CredSha8 -eq $primarySha8) {
            $failures += ('{0} [{1}]: duplicate of Primary credential sha8={2} while enabled (HTTP 409 risk)' -f $name, $row.File, $row.CredSha8)
        }
        if ($row.Enabled -and $primaryId -ne '' -and $row.Id -eq $primaryId) {
            $failures += ('{0} [{1}]: duplicate of Primary bot id while enabled (HTTP 409 risk)' -f $name, $row.File)
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host '' ; Write-Host '[GUARD] FAILURES:' -ForegroundColor Red
    foreach ($f in ($failures | Select-Object -Unique)) { Write-Host ('  - {0}' -f $f) -ForegroundColor Red }
}
else {
    Write-Host '' ; Write-Host '[GUARD] OK: v2/v3 agree, no clone duplicates Primary.' -ForegroundColor Green
}

if ($VerifyOnly -or (-not $Fix)) {
    if ($failures.Count -gt 0) { exit 1 }
    exit 0
}

$targets = @()
if ($Target -eq 'All') { $targets = @('Primary', 'Second', 'Third', 'Fourth', 'Fifth', 'Sixth') }
else { $targets = @($Target) }

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$overallOk = $true
$noBom = New-Object System.Text.UTF8Encoding $false

foreach ($name in $targets) {
    # Audit + restore are scoped PER TARGET (AGENTS: backups and validation are
    # per-target). A single shared array used to land the whole audit inside
    # the LAST target's backup root under -Target All.
    $targetAudit = @()
    $targetActions = @()
    $paths = $BotIdsByTarget[$name]
    $roaming = $paths.Roaming
    $zcode = $paths.ZCode
    $backupRoot = Join-Path $roaming ('ID_Backups\telegram_guardian_' + $timestamp)
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    foreach ($cfgName in @('v2\bot-config.json', 'v2\bot-config.v3.json')) {
        $cfgPath = Join-Path $zcode $cfgName
        if (-not (Test-Path -LiteralPath $cfgPath)) {
            Add-AuditEntry -Audit ([ref]$targetAudit) -File $cfgPath -Key 'telegram-enabled' -Before 'missing' -After 'skipped' -Ok $true
            continue
        }
        $dest = Backup-FileToTimestampDir -Source $cfgPath -BackupRoot $backupRoot -Label ([System.IO.Path]::GetFileName($cfgPath))
        if ($dest) {
            $targetActions += [ordered]@{ action = 'copy'; originalPath = $cfgPath; backupPath = $dest; renamedPath = $null }
        }
        try { $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json }
        catch {
            Add-AuditEntry -Audit ([ref]$targetAudit) -File $cfgPath -Key 'telegram-enabled' -Before 'parse-failed' -After 'skipped' -Ok $false
            $overallOk = $false
            continue
        }
        $changed = $false
        $intended = @()   # ordered telegram (id, wanted-enabled) rows for verify-after
        foreach ($bot in @($cfg.bots)) {
            if ($bot.provider -ne 'telegram') { continue }
            $before = [bool]$bot.enabled
            $want = $before
            $sha = Get-BotCredentialSha8 -CredentialsPath (Join-Path $zcode 'v2\credentials.json') -CredentialRef ([string]$bot.credentialRef)
            if ($name -eq 'Primary') {
                if ($sha -eq '') {
                    # Unreadable credentials.json -> fingerprint-based duplicate
                    # protection is blind; force-enabling could pair two pollers
                    # on one token (HTTP 409). Warn loudly and leave the flag.
                    Write-Host ('[WARN] Primary bot {0}: credential unreadable (sha8 empty) - skipping forced enable, leaving enabled={1}.' -f ([string]$bot.id), [string]$before) -ForegroundColor Yellow
                    $want = $before
                } else {
                    $want = $true
                }
            }
            else {
                $isDup = $false
                if ($primarySha8 -ne '' -and $sha -eq $primarySha8) { $isDup = $true }
                if ($primaryId -ne '' -and ([string]$bot.id) -eq $primaryId) { $isDup = $true }
                if ($isDup) { $want = $false }
                else {
                    if ($sha -eq '') { $want = $false }
                    else { $want = $before }
                }
            }
            if ($want -ne $before) { $bot.enabled = $want; $changed = $true }
            $intended += [pscustomobject]@{ Id = [string]$bot.id; Want = [bool]$want }
            Add-AuditEntry -Audit ([ref]$targetAudit) -File $cfgPath -Key ('telegram:' + [string]$bot.id) -Before ('enabled=' + [string]$before) -After ('enabled=' + [string]$want) -Ok $true
        }
        if ($changed) {
            [System.IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 20), $noBom)
        }
        # Verify-after: re-read AND compare the landed telegram enabled flags
        # against the intended values ("file existed" is not "value changed").
        # Files with no telegram rows have nothing to compare - parse-validate only.
        try {
            $verify = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
            if ($intended.Count -gt 0) {
                if ($null -eq $verify.bots) { throw 'bots array missing after write' }
                $landed = @($verify.bots | Where-Object { $_.provider -eq 'telegram' })
                if ($landed.Count -ne $intended.Count) {
                    throw ('telegram bot count changed after write: expected ' + $intended.Count + ', found ' + $landed.Count)
                }
                for ($i = 0; $i -lt $intended.Count; $i++) {
                    $landedId = [string]$landed[$i].id
                    $landedEnabled = [bool]$landed[$i].enabled
                    if ($landedId -ne $intended[$i].Id) {
                        throw ('telegram bot id changed after write at row ' + ($i + 1) + ': expected ' + $intended[$i].Id + ', found ' + $landedId)
                    }
                    if ($landedEnabled -ne $intended[$i].Want) {
                        throw ('enabled mismatch after write: bot ' + $landedId + ' landed ' + [string]$landedEnabled + ', wanted ' + [string]$intended[$i].Want)
                    }
                }
            }
        }
        catch {
            Add-AuditEntry -Audit ([ref]$targetAudit) -File $cfgPath -Key 'telegram-verify' -Before 'written' -After ('verify-failed: ' + $_.Exception.Message) -Ok $false
            Write-Host ('[FAILED] verify-after mismatch in {0}: {1}' -f $cfgPath, $_.Exception.Message) -ForegroundColor Red
            $overallOk = $false
        }
    }
    if ($name -ne 'Primary') {
        $homeRows = @(Get-HomeTelegramBots -Name $name -Paths $paths)
        $uniqueRow = $homeRows | Where-Object { $_.CredSha8 -ne '' -and $_.CredSha8 -ne $primarySha8 -and $_.Id -ne $primaryId } | Select-Object -First 1
        if ($uniqueRow) {
            $marker = Join-Path $paths.Home '.telegram-routed'
            $markerText = 'v2 unique-bot sha8=' + $uniqueRow.CredSha8 + ' id=' + $uniqueRow.Id
            [System.IO.File]::WriteAllText($marker, $markerText, $noBom)
            Write-Host ('[marker] {0}: unique bot, wrote v2 marker (launcher preserves enabled).' -f $name) -ForegroundColor Green
        }
    }
    # Per-target audit + restore (AGENTS: per-target scoping) - written inside
    # the loop so every target under -Target All gets its own pair.
    $auditPath = Join-Path $backupRoot 'audit_telegram_guardian.json'
    Write-AuditLog -Audit $targetAudit -Path $auditPath
    $restorePath = New-RestoreScript -BackupRoot $backupRoot -App 'ZCodeTelegram' -Actions $targetActions
    Write-Host ('[audit] {0}' -f $auditPath) -ForegroundColor Cyan
    Write-Host ('[restore] {0}' -f $restorePath) -ForegroundColor Cyan
}

$finalBots = Get-AllTelegramBots
$finalFailures = @()
foreach ($name in @('Primary', 'Second', 'Third', 'Fourth', 'Fifth', 'Sixth')) {
    $homeRows = @($finalBots | Where-Object { $_.Home -eq $name })
    if ($homeRows.Count -eq 0) { continue }
    $flags = @($homeRows | ForEach-Object { $_.Enabled } | Select-Object -Unique)
    if ($flags.Count -gt 1) { $finalFailures += ('{0}: v2/v3 still mismatched' -f $name); $overallOk = $false }
}
$primaryFinal = @($finalBots | Where-Object { $_.Home -eq 'Primary' -and $_.Enabled })
if ($hadPrimaryRows -and $primaryFinal.Count -eq 0) { $finalFailures += 'Primary: no enabled telegram bot after fix'; $overallOk = $false }
foreach ($name in @('Second', 'Third', 'Fourth', 'Fifth', 'Sixth')) {
    if ($primarySha8 -eq '') { continue }
    $dups = @($finalBots | Where-Object { $_.Home -eq $name -and $_.Enabled -and ($_.CredSha8 -eq $primarySha8 -or ($primaryId -ne '' -and $_.Id -eq $primaryId)) })
    if ($dups.Count -gt 0) { $finalFailures += ('{0}: still duplicates Primary while enabled' -f $name); $overallOk = $false }
}
if ($finalFailures.Count -gt 0) {
    foreach ($f in $finalFailures) { Write-Host ('[FAILED] {0}' -f $f) -ForegroundColor Red }
    exit 1
}
if (-not $overallOk) { exit 1 }
Write-Host '[GUARD] Fix verified: Primary enabled in v2+v3, clones disabled unless unique.' -ForegroundColor Green
exit 0

