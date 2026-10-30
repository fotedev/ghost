#Requires -Version 5.1
# WMI hardware-serial spoof - MOF/DYNPROPS technique (GHOST port)
#
# Origin: the ONE technique worth porting from Hydra Spoofer (MIT, reviewed
# 2026-10-27). Hydra's Python was NOT ported (bare excepts, zero verify-after,
# f-string MOF generation, a randomized DigitalProductId that can corrupt
# Windows activation display data); this is a clean GHOST-grade rewrite of the
# underlying idea:
#
#   A generated .mof file redeclares selected root\CIMv2 classes with the
#   [DYNPROPS] qualifier and compiles via mofcomp. WMI clients that ask
#   Win32_BIOS / Win32_BaseBoard / Win32_ComputerSystemProduct /
#   Win32_SystemEnclosure / Win32_DiskDrive / Win32_PhysicalMemory then read
#   the spoofed serials instead of the SMBIOS-backed values.
#
# HONEST LIMITS (docs/WMI_SERIAL_SPOOFING.md has the full write-up):
#   - WMI layer only. Anything reading SMBIOS directly (registry
#     HARDWARE\DESCRIPTION, GetSystemFirmwareTable, kernel) still sees the
#     real values.
#   - Does NOT move the fingerprint self-test score (its weighted signals are
#     cpu.name + tz + culture, weight 0.19 total). This is defense-in-depth
#     against IDE telemetry that collects serials via WMI (e.g. the
#     systeminformation npm package), not the primary reset mechanism.
#   - #pragma autorecover re-applies the definitions after a WMI repository
#     rebuild IF the .mof still exists at its recorded path (the backup
#     folder); after a Windows feature update re-run the script (or mofcomp
#     the preserved .mof) when verify fails.
#   - The verify-after step is the arbiter: if this box's WMI stack ignores
#     the override, the script reports FAILED - it can never silently claim a
#     spoof it did not observe.
#
# SCOPE: does NOT touch CPU (change_device_id.ps1 Phase-5 owns CentralProcessor
# name), GPU, NIC MAC (reset_qoder.ps1 [26]), ComputerName / MachineGuid /
# ProductId (change_device_id.ps1 LegacyReset). Adds only the bits GHOST had
# no coverage for: WMI serials, HKLM SQMClient UserId, Bluetooth LocalAddress.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File spoof_wmi_serials.ps1            # full run
#   powershell -ExecutionPolicy Bypass -File spoof_wmi_serials.ps1 -DryRun    # plan only, no writes
#   powershell -ExecutionPolicy Bypass -File spoof_wmi_serials.ps1 -SkipBluetooth
# Prerequisite: Administrator (the script aborts without it, no self-elevation
# - same contract as change_device_id.ps1). Backups land in
# $env:TEMP\WmiSerialsBackup_<ts> (the system-level convention set by
# change_device_id.ps1) and include a full winmgmt repository backup.
#
# PS 5.1 COMPAT: no ternary, no $Input variable, RandomNumberGenerator via
# .GetBytes() only, no 2>&1 redirection of native commands under Stop
# preference (NativeCommandError trap).

param(
    # Plan only: snapshot current values, print what WOULD be written, exit 0.
    [switch]$DryRun,

    # Skip the Bluetooth LocalAddress rotation (BTHPORT registry + service
    # restart). SQMClient UserId is always attempted.
    [switch]$SkipBluetooth
)

. "$PSScriptRoot\identity_utils.ps1"

$ErrorActionPreference = "Stop"

Assert-Administrator
Write-GhostBanner -Target "WMI hardware serial spoof [MOF/DYNPROPS]"

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupRoot = Join-Path $env:TEMP ("WmiSerialsBackup_" + $timestamp)
$app = "wmiserials"

# --- Local helpers ------------------------------------------------------------

function Get-GhostRandomString {
    # Crypto-RNG rejection-sampled characters (256 % len bias removed), same
    # pattern as identity_utils Get-NewHostname.
    param(
        [Parameter(Mandatory = $true)][string]$Alphabet,
        [Parameter(Mandatory = $true)][int]$Length
    )
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $chars = New-Object char[] $Length
        $b = New-Object byte[] 1
        $limit = 256 - (256 % $Alphabet.Length)
        for ($i = 0; $i -lt $Length; $i++) {
            do { $rng.GetBytes($b) } while ($b[0] -ge $limit)
            $chars[$i] = $Alphabet[$b[0] % $Alphabet.Length]
        }
        return (-join $chars)
    }
    finally {
        if ($rng) { $rng.Dispose() }
    }
}

function Get-NewSpoofSerial {
    # Same alphabet family as the original, same length (realistic shape),
    # bounded to sane min/max so empty originals still get a usable value.
    param(
        [string]$Original,
        [ValidateSet("AlnumUpper", "HexUpper", "Guid")][string]$Style,
        [int]$MinLength = 8,
        [int]$MaxLength = 32
    )
    if ($Style -eq "Guid") {
        return ([guid]::NewGuid().ToString()).ToUpperInvariant()
    }
    if ($Style -eq "HexUpper") {
        $alphabet = "0123456789ABCDEF"
    }
    else {
        $alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    }
    $length = ([string]$Original).Length
    if ($length -lt $MinLength) { $length = $MinLength }
    if ($length -gt $MaxLength) { $length = $MaxLength }
    return (Get-GhostRandomString -Alphabet $alphabet -Length $length)
}

function Get-NewBluetoothMac {
    # 12 hex chars, second char drawn from 26AE -> first byte is locally
    # administered + unicast (indistinguishable from a driver-generated MAC).
    $rest = Get-GhostRandomString -Alphabet "0123456789ABCDEF" -Length 11
    $second = (Get-GhostRandomString -Alphabet "26AE" -Length 1)
    return ($rest.Substring(0, 1) + $second + $rest.Substring(1))
}

function ConvertTo-MofLiteral {
    # MOF string literal with backslash + quote escaping (Hydra skipped this
    # entirely - one vendor serial with a backslash would break the compile).
    param([string]$Value)
    if ($null -eq $Value) { $Value = "" }
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return ('"' + $escaped + '"')
}

# Class plan: key property MUST match the real CIM class key (Win32_BaseBoard
# and Win32_SystemEnclosure key on Tag, NOT Manufacturer - Hydra had that
# wrong) so the redefinition merges instead of failing the compile.
$script:WmiClassPlan = @(
    @{
        Class      = "Win32_BIOS"
        KeyProp    = "Name"
        Spoof      = @{ SerialNumber = "AlnumUpper" }
    },
    @{
        Class      = "Win32_BaseBoard"
        KeyProp    = "Tag"
        Spoof      = @{ SerialNumber = "AlnumUpper" }
    },
    @{
        Class      = "Win32_ComputerSystemProduct"
        KeyProp    = "Name"
        Spoof      = @{ IdentifyingNumber = "AlnumUpper"; UUID = "Guid" }
    },
    @{
        Class      = "Win32_SystemEnclosure"
        KeyProp    = "Tag"
        Spoof      = @{ SerialNumber = "AlnumUpper" }
    },
    @{
        Class      = "Win32_DiskDrive"
        KeyProp    = "DeviceID"
        Spoof      = @{ SerialNumber = "AlnumUpper" }
    },
    @{
        Class      = "Win32_PhysicalMemory"
        KeyProp    = "Tag"
        Spoof      = @{ SerialNumber = "HexUpper" }
    }
)

function Get-WmiSnapshot {
    # class -> array of instance maps {KeyProp, props...}; missing/absent
    # classes become empty arrays, never errors.
    $snapshot = @()
    foreach ($entry in $script:WmiClassPlan) {
        $instances = @()
        try {
            $cimObjects = @(Get-CimInstance -ClassName $entry.Class -ErrorAction Stop)
        }
        catch {
            $cimObjects = @()
        }
        foreach ($obj in $cimObjects) {
            $props = @{ }
            $keyValue = $null
            if (Test-ObjectProperty -Object $obj -Name $entry.KeyProp) {
                $keyValue = [string]$obj.($entry.KeyProp)
            }
            $props[$entry.KeyProp] = $keyValue
            foreach ($spoofProp in @($entry.Spoof.Keys)) {
                $current = $null
                if (Test-ObjectProperty -Object $obj -Name $spoofProp) {
                    $current = [string]$obj.($spoofProp)
                }
                $props[$spoofProp] = $current
            }
            $instances += $props
        }
        $snapshot += @{
            Class     = $entry.Class
            KeyProp   = $entry.KeyProp
            Instances = $instances
        }
    }
    return ,$snapshot
}

function New-SpoofPlan {
    # For each snapshot instance generate the spoofed values (before-values
    # preserved for the audit) -> class -> array of {KeyValue, Values}.
    param([AllowEmptyCollection()][Parameter(Mandatory = $true)]$Snapshot)
    $styleTable = @{ }
    foreach ($entry in $script:WmiClassPlan) {
        $styleTable[$entry.Class] = $entry.Spoof
    }
    $plan = @()
    foreach ($classEntry in $Snapshot) {
        $styles = $styleTable[$classEntry.Class]
        if ($null -eq $styles) {
            # A missing style entry must never degrade into an empty Values
            # hashtable (a spoof MOF with no spoofed property = silent no-op).
            throw ("No spoof-style table entry for class " + $classEntry.Class)
        }
        $classPlan = @{
            Class     = $classEntry.Class
            KeyProp   = $classEntry.KeyProp
            Instances = @()
        }
        foreach ($inst in $classEntry.Instances) {
            $values = @{ }
            foreach ($spoofProp in @($styles.Keys)) {
                $values[$spoofProp] = Get-NewSpoofSerial -Original ([string]$inst[$spoofProp]) -Style $styles[$spoofProp]
            }
            $classPlan.Instances += @{
                KeyValue = $inst[$classEntry.KeyProp]
                Before   = $inst
                Values   = $values
            }
        }
        $plan += $classPlan
    }
    return ,$plan
}

function New-SpoofMofContent {
    # [DYNPROPS] redeclaration + instances. Unlisted properties survive the
    # class update (MOF class updates merge); the key property keeps its real
    # value so the instance aligns with the class.
    param([AllowEmptyCollection()][Parameter(Mandatory = $true)]$Plan)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('#pragma autorecover')
    [void]$sb.AppendLine('#pragma namespace("\\\\.\\root\\CIMv2")')
    [void]$sb.AppendLine('')

    foreach ($classPlan in $Plan) {
        if (@($classPlan.Instances).Count -eq 0) { continue }
        $spoofProps = @($classPlan.Instances[0].Values.Keys)
        if ($spoofProps.Count -eq 0) {
            throw ("No spoofed properties resolved for class " + $classPlan.Class)
        }

        [void]$sb.AppendLine('[DYNPROPS]')
        [void]$sb.AppendLine(("class {0}" -f $classPlan.Class))
        [void]$sb.AppendLine('{')
        [void]$sb.AppendLine(('    [key] string {0};' -f $classPlan.KeyProp))
        foreach ($spoofProp in $spoofProps) {
            [void]$sb.AppendLine(('    string {0};' -f $spoofProp))
        }
        [void]$sb.AppendLine('};')
        [void]$sb.AppendLine('')

        foreach ($inst in @($classPlan.Instances)) {
            [void]$sb.AppendLine(('instance of {0}' -f $classPlan.Class))
            [void]$sb.AppendLine('{')
            [void]$sb.AppendLine(('    {0} = {1};' -f $classPlan.KeyProp, (ConvertTo-MofLiteral -Value ([string]$inst.KeyValue))))
            foreach ($spoofProp in $spoofProps) {
                [void]$sb.AppendLine(('    {0} = {1};' -f $spoofProp, (ConvertTo-MofLiteral -Value ([string]$inst.Values[$spoofProp]))))
            }
            [void]$sb.AppendLine('};')
            [void]$sb.AppendLine('')
        }
    }
    return $sb.ToString()
}

function Set-GhostRegistryValue {
    # HKLM write + verify-after re-read, audited. Returns $true only when the
    # re-read matches (the "file existed" is not "value changed" rule).
    param(
        [Parameter(Mandatory = $true)][string]$KeyPath,
        [Parameter(Mandatory = $true)][string]$ValueName,
        [Parameter(Mandatory = $true)][Microsoft.Win32.RegistryValueKind]$Kind,
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][ref]$Audit
    )
    $before = $null
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($KeyPath, $true)
        if ($null -eq $key) {
            $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($KeyPath)
        }
        $before = $key.GetValue($ValueName)
        $key.SetValue($ValueName, $Value, $Kind)
        $key.Close()
    }
    catch {
        Add-AuditEntry -Audit $Audit -File ("HKLM:\" + $KeyPath) -Key $ValueName -Before $before -After ("<write-failed: " + $_.Exception.Message + ">") -Ok $false
        Write-Host "[FAILED] registry write $KeyPath\$ValueName -- $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }

    $after = $null
    try {
        $check = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($KeyPath)
        if ($null -ne $check) {
            $after = $check.GetValue($ValueName)
            $check.Close()
        }
    }
    catch {
        $after = $null
    }
    $ok = ([string]$after -eq [string]$Value)
    Add-AuditEntry -Audit $Audit -File ("HKLM:\" + $KeyPath) -Key $ValueName -Before $before -After $after -Ok $ok
    if ($ok) {
        Write-Host "[OK] $KeyPath\$ValueName" -ForegroundColor Green
    }
    else {
        Write-Host "[FAILED] verify-after mismatch $KeyPath\$ValueName (got: $after)" -ForegroundColor Red
    }
    return $ok
}

# --- Step [1/5] Backups -------------------------------------------------------
$passCount = 0
$failCount = 0
$audit = @()

if ($DryRun) {
    Write-Host "`n[DRY RUN] snapshot + plan only - nothing will be written." -ForegroundColor Yellow
}
else {
    Write-Host "`n[1/5] Backups -> $backupRoot" -ForegroundColor Cyan
    New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null

    $winmgmtExe = Join-Path $env:SystemRoot "System32\wbem\winmgmt.exe"
    if (-not (Test-Path -LiteralPath $winmgmtExe)) { $winmgmtExe = "winmgmt" }
    $repoBackupPath = Join-Path $backupRoot "wmi-repo.bak"
    & $winmgmtExe /backup $repoBackupPath
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $repoBackupPath)) {
        Write-Host "[OK] WMI repository backup: $repoBackupPath" -ForegroundColor Green
        Add-AuditEntry -Audit ([ref]$audit) -File "winmgmt-repository" -Key "backup" -Before $null -After $repoBackupPath -Ok $true
        $passCount++
    }
    else {
        # No repository backup = no mutation (mutation-refused contract: the
        # restore script claims to cover this tree, so it must be coverable).
        Write-Host "[FAILED] winmgmt /backup failed (exit $LASTEXITCODE) - ABORTING, nothing was changed." -ForegroundColor Red
        Write-Host "WMI may be busy; retry in a minute. No mutations were performed." -ForegroundColor Yellow
        exit 1
    }

    $snapshot = Get-WmiSnapshot
    $snapshotPath = Join-Path $backupRoot "wmi_serials_before.json"
    $snapshotJson = ConvertTo-Json -InputObject @($snapshot) -Depth 10
    [System.IO.File]::WriteAllText($snapshotPath, $snapshotJson, (New-Object System.Text.UTF8Encoding $false))
    Write-Host "[OK] serial snapshot: $snapshotPath" -ForegroundColor Green

    # Registry exports for the restore script (SQMClient always; BTHPORT when
    # the Bluetooth stack is present and not skipped).
    $sqmExportOk = $false
    $sqmRegPath = Join-Path $backupRoot "SQMClient.reg"
    $null = reg export "HKLM\SOFTWARE\Microsoft\SQMClient" $sqmRegPath /y
    if ($LASTEXITCODE -eq 0) {
        $sqmExportOk = $true
        Write-Host "[OK] SQMClient registry export" -ForegroundColor Green
    }
    else {
        Write-Host "[WARN] SQMClient registry export failed - UserId step will still run, restore falls back to value delete." -ForegroundColor Yellow
    }

    $bthExportOk = $false
    $bthRegPath = $null
    if (-not $SkipBluetooth) {
        $bthRegPath = Join-Path $backupRoot "BTHPORT_Devices.reg"
        $null = reg export "HKLM\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices" $bthRegPath /y
        if ($LASTEXITCODE -eq 0) {
            $bthExportOk = $true
            Write-Host "[OK] BTHPORT registry export" -ForegroundColor Green
        }
        else {
            Write-Host "[INFO] BTHPORT Devices key not present - Bluetooth step will be skipped (no Bluetooth stack)." -ForegroundColor DarkGray
        }
    }
}

# --- Step [2/5] Build + compile the spoof MOF ----------------------------------
Write-Host "`n[2/5] Building the spoof plan (six CIM classes)" -ForegroundColor Cyan
$snapshotPlan = Get-WmiSnapshot
$spoofPlan = New-SpoofPlan -Snapshot $snapshotPlan

foreach ($classPlan in $spoofPlan) {
    $count = @($classPlan.Instances).Count
    if ($count -eq 0) {
        Write-Host "[SKIP] $($classPlan.Class): no instances" -ForegroundColor DarkGray
    }
    else {
        Write-Host "[PLAN] $($classPlan.Class): $count instance(s)"
        foreach ($inst in @($classPlan.Instances)) {
            foreach ($spoofProp in @($inst.Values.Keys)) {
                Write-Host ("       {0}[{1}={2}].{3} -> {4}" -f $classPlan.Class, $classPlan.KeyProp, $inst.KeyValue, $spoofProp, $inst.Values[$spoofProp]) -ForegroundColor DarkGray
            }
        }
    }
}

if ($DryRun) {
    Write-Host "`n[DRY RUN] done - no MOF compiled, no registry touched, no backups taken." -ForegroundColor Yellow
    exit 0
}

$mofPath = Join-Path $backupRoot "spoof_serials.mof"
$mofContent = New-SpoofMofContent -Plan $spoofPlan
[System.IO.File]::WriteAllText($mofPath, $mofContent, (New-Object System.Text.UTF8Encoding $false))

$mofcompExe = Join-Path $env:SystemRoot "System32\wbem\mofcomp.exe"
if (-not (Test-Path -LiteralPath $mofcompExe)) { $mofcompExe = "mofcomp" }
Write-Host "Compiling $mofPath ..."
& $mofcompExe $mofPath
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] mofcomp succeeded" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] mofcomp exit $LASTEXITCODE - ABORTING before registry steps. Repository backup is at $repoBackupPath" -ForegroundColor Red
    Add-AuditEntry -Audit ([ref]$audit) -File "mofcomp" -Key $mofPath -Before "not-compiled" -After ("exit " + $LASTEXITCODE) -Ok $false
    $auditPath = Join-Path $backupRoot ("audit_{0}.json" -f $timestamp)
    Write-AuditLog -Audit $audit -Path $auditPath
    $failCount++
    Write-Host "`n=== Summary ===" -ForegroundColor Cyan
    Write-Host "Pass: $passCount" -ForegroundColor Green
    Write-Host "Fail: $failCount" -ForegroundColor Red
    exit 1
}

# --- Step [3/5] Registry: SQMClient UserId + Bluetooth LocalAddress ------------
Write-Host "`n[3/5] Registry identity values" -ForegroundColor Cyan

$newSqmUserId = "{" + ([guid]::NewGuid().ToString().ToUpperInvariant()) + "}"
$null = Set-GhostRegistryValue -KeyPath "SOFTWARE\Microsoft\SQMClient" -ValueName "UserId" -Kind ([Microsoft.Win32.RegistryValueKind]::String) -Value $newSqmUserId -Audit ([ref]$audit)

if ($SkipBluetooth) {
    Write-Host "[SKIP] Bluetooth step (-SkipBluetooth)" -ForegroundColor DarkGray
}
elseif (-not $bthExportOk) {
    Write-Host "[SKIP] Bluetooth step: BTHPORT Devices key absent" -ForegroundColor DarkGray
    Add-AuditEntry -Audit ([ref]$audit) -File "HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices" -Key "LocalAddress" -Before $null -After "skipped: key absent" -Ok $true
}
else {
    $devicesKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices", $true)
    if ($null -eq $devicesKey) {
        Write-Host "[SKIP] Bluetooth step: key could not be opened" -ForegroundColor DarkGray
    }
    else {
        $subKeyNames = $devicesKey.GetSubKeyNames()
        $devicesKey.Close()
        $btWritten = 0
        $btFailed = 0
        foreach ($subKeyName in $subKeyNames) {
            $newMac = Get-NewBluetoothMac
            $ok = Set-GhostRegistryValue -KeyPath ("SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices\" + $subKeyName) -ValueName "LocalAddress" -Kind ([Microsoft.Win32.RegistryValueKind]::String) -Value $newMac -Audit ([ref]$audit)
            if ($ok) { $btWritten++ } else { $btFailed++ }
        }
        if ($btWritten -gt 0) {
            Write-Host "[INFO] $btWritten Bluetooth device key(s) stamped; restarting bthserv so the stack re-reads them..."
            $btService = Get-Service -Name bthserv -ErrorAction SilentlyContinue
            if ($null -ne $btService -and $btService.Status -eq "Running") {
                try {
                    Restart-Service -Name bthserv -Force -ErrorAction Stop
                    Write-Host "[OK] bthserv restarted" -ForegroundColor Green
                    Add-AuditEntry -Audit ([ref]$audit) -File "service:bthserv" -Key "restart" -Before "Running" -After "Running" -Ok $true
                }
                catch {
                    Write-Host "[WARN] bthserv restart failed: $($_.Exception.Message)" -ForegroundColor Yellow
                    Add-AuditEntry -Audit ([ref]$audit) -File "service:bthserv" -Key "restart" -Before "Running" -After "restart-failed" -Ok $false
                }
            }
            else {
                Write-Host "[INFO] bthserv not running - values apply on next service start" -ForegroundColor DarkGray
            }
        }
        if ($btFailed -gt 0) {
            Write-Host "[WARN] $btFailed Bluetooth key(s) failed (see audit)" -ForegroundColor Yellow
        }
    }
}

# --- Step [4/5] Verify-after ----------------------------------------------------
Write-Host "`n[4/5] Verify-after (re-query WMI, compare to the plan)" -ForegroundColor Cyan

$verifyEntries = @()
$verifyAllOk = $true
foreach ($classPlan in $spoofPlan) {
    if (@($classPlan.Instances).Count -eq 0) { continue }

    $attempts = 0
    $cimObjects = @()
    while ($attempts -lt 3) {
        try {
            $cimObjects = @(Get-CimInstance -ClassName $classPlan.Class -ErrorAction Stop)
            break
        }
        catch {
            $cimObjects = @()
        }
        $attempts++
        if ($attempts -lt 3) { Start-Sleep -Seconds 2 }
    }

    foreach ($inst in @($classPlan.Instances)) {
        $matched = $null
        foreach ($obj in $cimObjects) {
            if ((Test-ObjectProperty -Object $obj -Name $classPlan.KeyProp) -and
                ([string]$obj.($classPlan.KeyProp)) -eq ([string]$inst.KeyValue)) {
                $matched = $obj
                break
            }
        }
        foreach ($spoofProp in @($inst.Values.Keys)) {
            $expected = [string]$inst.Values[$spoofProp]
            $actual = $null
            if ($null -ne $matched -and (Test-ObjectProperty -Object $matched -Name $spoofProp)) {
                $actual = [string]$matched.($spoofProp)
            }
            $ok = ($actual -eq $expected)
            $verifyEntries += [ordered]@{
                class    = $classPlan.Class
                key      = ("{0}={1}" -f $classPlan.KeyProp, $inst.KeyValue)
                prop     = $spoofProp
                expected = $expected
                actual   = $actual
                ok       = $ok
            }
            Add-AuditEntry -Audit ([ref]$audit) -File ("WMI:" + $classPlan.Class) -Key ("{0}={1}.{2}" -f $classPlan.KeyProp, $inst.KeyValue, $spoofProp) -Before $inst.Before[$spoofProp] -After $actual -Ok $ok
            if (-not $ok) {
                $verifyAllOk = $false
                Write-Host ("[FAILED] {0} [{1}={2}].{3} expected {4} got {5}" -f $classPlan.Class, $classPlan.KeyProp, $inst.KeyValue, $spoofProp, $expected, $actual) -ForegroundColor Red
            }
        }
    }
}

$verifyOkCount = @($verifyEntries | Where-Object { $_.ok }).Count
Write-Host ("Verify result: {0}/{1} spoofed values confirmed via WMI re-query" -f $verifyOkCount, @($verifyEntries).Count) -ForegroundColor $(if ($verifyAllOk) { "Green" } else { "Yellow" })

# --- Step [5/5] Audit + restore script + summary --------------------------------
Write-Host "`n[5/5] Audit + restore script" -ForegroundColor Cyan
$auditPath = Join-Path $backupRoot ("audit_{0}.json" -f $timestamp)
Write-AuditLog -Audit $audit -Path $auditPath

$restoreScriptPath = Join-Path $backupRoot ("restore_{0}_{1}.ps1" -f $app, $timestamp)
$restoreContent = @"
#Requires -Version 5.1
# GHOST WMI serial spoof RESTORE - generated $timestamp
# Run as Administrator. Reverts, in order:
#   1. registry values (import of the pre-run exports)
#   2. the WMI repository (winmgmt /restore from wmi-repo.bak)
#   3. the Bluetooth support service
# NOTE: winmgmt /restore rebuilds the repository - any WMI state created after
# the spoof run (including this spoof) is replaced by the pre-run snapshot.

`$ErrorActionPreference = "Continue"
`$backupRoot = "$backupRoot"

Write-Host "[1/3] Importing registry exports..."
if (Test-Path -LiteralPath "`$backupRoot\SQMClient.reg") {
    reg import "`$backupRoot\SQMClient.reg"
    if (`$LASTEXITCODE -eq 0) { Write-Host "[OK] SQMClient restored" -ForegroundColor Green }
    else { Write-Host "[WARN] SQMClient import failed (exit `$LASTEXITCODE)" -ForegroundColor Yellow }
}
if (Test-Path -LiteralPath "`$backupRoot\BTHPORT_Devices.reg") {
    reg import "`$backupRoot\BTHPORT_Devices.reg"
    if (`$LASTEXITCODE -eq 0) { Write-Host "[OK] BTHPORT restored" -ForegroundColor Green }
    else { Write-Host "[WARN] BTHPORT import failed (exit `$LASTEXITCODE)" -ForegroundColor Yellow }
}

Write-Host "[2/3] Restoring the WMI repository..."
& "$env:SystemRoot\System32\wbem\winmgmt.exe" /restore "`$backupRoot\wmi-repo.bak"
if (`$LASTEXITCODE -eq 0) { Write-Host "[OK] WMI repository restored" -ForegroundColor Green }
else { Write-Host "[FAILED] winmgmt /restore exit `$LASTEXITCODE" -ForegroundColor Red }

Write-Host "[3/3] Restarting the Bluetooth support service..."
try { Restart-Service -Name bthserv -Force -ErrorAction Stop; Write-Host "[OK] bthserv restarted" -ForegroundColor Green }
catch { Write-Host "[INFO] bthserv restart skipped: `$(`$_.Exception.Message)" -ForegroundColor DarkGray }

Write-Host ""
Write-Host "Restore complete. Verify with: Get-CimInstance Win32_BIOS | Select-Object SerialNumber"
Write-Host "A reboot is recommended so long-lived processes drop their cached WMI connections."
"@
[System.IO.File]::WriteAllText($restoreScriptPath, $restoreContent, (New-Object System.Text.UTF8Encoding $false))
Write-Host "[OK] restore script: $restoreScriptPath" -ForegroundColor Green
$passCount++

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Backup folder: $backupRoot"
Write-Host "Pass: $passCount" -ForegroundColor Green
Write-Host "Fail: $failCount" -ForegroundColor Red
Write-Host ("WMI verify: {0}/{1} confirmed" -f $verifyOkCount, @($verifyEntries).Count) -ForegroundColor $(if ($verifyAllOk) { "Green" } else { "Yellow" })
Write-Host "Audit log: $auditPath" -ForegroundColor Gray
Write-Host "Restore script: $restoreScriptPath" -ForegroundColor Gray
if (-not $verifyAllOk) {
    Write-Host "NOTE: one or more spoofed values did not read back via WMI (see audit). The repository backup + restore script revert everything." -ForegroundColor Yellow
}
Write-Host "NOTE: this spoofs the WMI layer only - direct SMBIOS readers still see real values (docs/WMI_SERIAL_SPOOFING.md)." -ForegroundColor Yellow
Write-Host "NOTE: re-run after a Windows feature update if verify starts failing." -ForegroundColor Yellow

if ($failCount -gt 0 -or -not $verifyAllOk) {
    Write-Host "WMI serial spoof completed with failures. Review $auditPath." -ForegroundColor Red
    exit 1
}

Write-Host "WMI serial spoof completed successfully."
