#Requires -Version 5.1
# ZCode per-clone Telegram bot guardian (UI-assisted model).
# See docs/ZCODE_TELEGRAM_BOTS.md for the full contract.
param(
    [ValidateSet('Primary', 'Second', 'Third', 'Fourth', 'All')]
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
    foreach ($name in @('Primary', 'Second', 'Third', 'Fourth')) {
        $rows = Get-HomeTelegramBots -Name $name -Paths $BotIdsByTarget[$name]
        if ($rows) { $all += $rows }
    }
    return $all
}

$allBots = Get-AllTelegramBots
Write-Host '=== Telegram bot fingerprint (sha8 only, no secrets) ===' -ForegroundColor Cyan
foreach ($row in $allBots) {
    Write-Host ('{0} [{1}] id={2} enabled={3} sha8={4}' -f $row.Home, $row.File, $row.Id, $row.Enabled, $row.CredSha8)
}

$failures = @()
$primaryRows = @($allBots | Where-Object { $_.Home -eq 'Primary' -and $_.CredSha8 -ne '' })
$primarySha8 = ''
$primaryId = ''
if ($primaryRows.Count -gt 0) {
    $primarySha8 = $primaryRows[0].CredSha8
    $primaryId = $primaryRows[0].Id
}

foreach ($name in @('Primary', 'Second', 'Third', 'Fourth')) {
    $homeRows = @($allBots | Where-Object { $_.Home -eq $name })
    if ($homeRows.Count -eq 0) { continue }
    $flags = @($homeRows | ForEach-Object { $_.Enabled } | Select-Object -Unique)
    if ($flags.Count -gt 1) {
        $detail = ($homeRows | ForEach-Object { ('{0}={1}' -f $_.File, $_.Enabled) }) -join ', '
        $failures += ('{0}: v2/v3 enabled mismatch ({1})' -f $name, $detail)
    }
}

foreach ($name in @('Second', 'Third', 'Fourth')) {
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
if ($Target -eq 'All') { $targets = @('Primary', 'Second', 'Third', 'Fourth') }
else { $targets = @($Target) }

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$audit = @()
$actions = @()
$overallOk = $true
$noBom = New-Object System.Text.UTF8Encoding $false

foreach ($name in $targets) {
    $paths = $BotIdsByTarget[$name]
    $roaming = $paths.Roaming
    $zcode = $paths.ZCode
    $backupRoot = Join-Path $roaming ('ID_Backups\telegram_guardian_' + $timestamp)
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    foreach ($cfgName in @('v2\bot-config.json', 'v2\bot-config.v3.json')) {
        $cfgPath = Join-Path $zcode $cfgName
        if (-not (Test-Path -LiteralPath $cfgPath)) {
            Add-AuditEntry -Audit ([ref]$audit) -File $cfgPath -Key 'telegram-enabled' -Before 'missing' -After 'skipped' -Ok $true
            continue
        }
        $dest = Backup-FileToTimestampDir -Source $cfgPath -BackupRoot $backupRoot -Label ([System.IO.Path]::GetFileName($cfgPath))
        if ($dest) {
            $actions += [ordered]@{ action = 'copy'; originalPath = $cfgPath; backupPath = $dest; renamedPath = $null }
        }
        try { $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json }
        catch {
            Add-AuditEntry -Audit ([ref]$audit) -File $cfgPath -Key 'telegram-enabled' -Before 'parse-failed' -After 'skipped' -Ok $false
            $overallOk = $false
            continue
        }
        $changed = $false
        foreach ($bot in @($cfg.bots)) {
            if ($bot.provider -ne 'telegram') { continue }
            $before = [bool]$bot.enabled
            $want = $before
            if ($name -eq 'Primary') { $want = $true }
            else {
                $sha = Get-BotCredentialSha8 -CredentialsPath (Join-Path $zcode 'v2\credentials.json') -CredentialRef ([string]$bot.credentialRef)
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
            Add-AuditEntry -Audit ([ref]$audit) -File $cfgPath -Key ('telegram:' + [string]$bot.id) -Before ('enabled=' + [string]$before) -After ('enabled=' + [string]$want) -Ok $true
        }
        if ($changed) {
            [System.IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 20), $noBom)
        }
        try { Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json | Out-Null }
        catch { $overallOk = $false }
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
}

$auditPath = Join-Path $backupRoot 'audit_telegram_guardian.json'
Write-AuditLog -Audit $audit -Path $auditPath
$restorePath = New-RestoreScript -BackupRoot $backupRoot -App 'ZCodeTelegram' -Actions $actions
Write-Host ('[audit] {0}' -f $auditPath) -ForegroundColor Cyan
Write-Host ('[restore] {0}' -f $restorePath) -ForegroundColor Cyan

$finalBots = Get-AllTelegramBots
$finalFailures = @()
foreach ($name in @('Primary', 'Second', 'Third', 'Fourth')) {
    $homeRows = @($finalBots | Where-Object { $_.Home -eq $name })
    if ($homeRows.Count -eq 0) { continue }
    $flags = @($homeRows | ForEach-Object { $_.Enabled } | Select-Object -Unique)
    if ($flags.Count -gt 1) { $finalFailures += ('{0}: v2/v3 still mismatched' -f $name); $overallOk = $false }
}
$primaryFinal = @($finalBots | Where-Object { $_.Home -eq 'Primary' -and $_.Enabled })
if ($primaryFinal.Count -eq 0) { $finalFailures += 'Primary: no enabled telegram bot after fix'; $overallOk = $false }
foreach ($name in @('Second', 'Third', 'Fourth')) {
    if ($primarySha8 -eq '') { continue }
    $dups = @($finalBots | Where-Object { $_.Home -eq $name -and $_.Enabled -and ($_.CredSha8 -eq $primarySha8 -or $_.Id -eq $primaryId) })
    if ($dups.Count -gt 0) { $finalFailures += ('{0}: still duplicates Primary while enabled' -f $name); $overallOk = $false }
}
if ($finalFailures.Count -gt 0) {
    foreach ($f in $finalFailures) { Write-Host ('[FAILED] {0}' -f $f) -ForegroundColor Red }
    exit 1
}
if (-not $overallOk) { exit 1 }
Write-Host '[GUARD] Fix verified: Primary enabled in v2+v3, clones disabled unless unique.' -ForegroundColor Green
exit 0

