function Add-AuditEntry {
    param(
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][string]$File,
        [Parameter(Mandatory = $true)][string]$Key,
        $Before,
        $After,
        [Parameter(Mandatory = $true)][bool]$Ok
    )

    if ($null -eq $Audit.Value) {
        $Audit.Value = @()
    }

    $Audit.Value += [ordered]@{
        file   = $File
        key    = $Key
        before = $Before
        after  = $After
        ok     = $Ok
    }
}

function Test-ObjectProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-PathBackupLabel {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $root = [System.IO.Path]::GetPathRoot($Path)
    if ([string]::IsNullOrWhiteSpace($root)) {
        return Join-Path "paths" ([System.IO.Path]::GetFileName($Path))
    }

    $driveName = $root.TrimEnd('\').Replace(':', '')
    $relativePath = $Path.Substring($root.Length).TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
        return Join-Path "paths" $driveName
    }

    return Join-Path (Join-Path "paths" $driveName) $relativePath
}

function Get-PythonCommandInfo {
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCommand) {
        return $pythonCommand
    }

    $python3Command = Get-Command python3 -ErrorAction SilentlyContinue
    if ($python3Command) {
        return $python3Command
    }

    return $null
}

function New-IdentitySet {
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $machineBytes = New-Object byte[] 32
        $macMachineBytes = New-Object byte[] 64

        $rng.GetBytes($machineBytes)
        $rng.GetBytes($macMachineBytes)

        return @{
            devDeviceId = ([guid]::NewGuid().ToString()).ToLowerInvariant()
            machineId   = (($machineBytes | ForEach-Object { $_.ToString("x2") }) -join "")
            macMachineId = (($macMachineBytes | ForEach-Object { $_.ToString("x2") }) -join "")
            sqmId       = "{" + [guid]::NewGuid().ToString().ToUpperInvariant() + "}"
        }
    }
    finally {
        if ($rng) {
            $rng.Dispose()
        }
    }
}

function Assert-Administrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdministrator) {
        Write-Host "Administrator privileges are required." -ForegroundColor Red
        exit 1
    }
}

function Stop-AppProcesses {
    param(
        [Parameter(Mandatory = $true)][string[]]$Names,
        [int]$WaitSeconds = 3
    )

    $helperMap = @{
        Cursor   = @("Cursor")
        Windsurf = @("Windsurf", "codeium")
        Trae     = @("Trae", "Trae Broker")
    }

    $expandedNames = @()
    foreach ($name in $Names) {
        if ($helperMap.ContainsKey($name)) {
            $expandedNames += $helperMap[$name]
        }
        else {
            $expandedNames += $name
        }
    }
    $expandedNames = $expandedNames | Select-Object -Unique

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        foreach ($processName in $expandedNames) {
            $running = Get-Process -Name $processName -ErrorAction SilentlyContinue
            if ($running) {
                $running | Stop-Process -Force -ErrorAction SilentlyContinue
            }
        }

        Start-Sleep -Seconds $WaitSeconds

        $remaining = @()
        foreach ($processName in $expandedNames) {
            if (Get-Process -Name $processName -ErrorAction SilentlyContinue) {
                $remaining += $processName
            }
        }

        if ($remaining.Count -eq 0) {
            $appLabel = ($Names | Select-Object -First 1)
            Write-Host "[OK] all $appLabel processes terminated" -ForegroundColor Green
            return $true
        }
    }

    $failedNames = @()
    foreach ($processName in $expandedNames) {
        if (Get-Process -Name $processName -ErrorAction SilentlyContinue) {
            $failedNames += $processName
        }
    }

    if ($failedNames.Count -gt 0) {
        Write-Host "[FAILED] could not terminate: $($failedNames -join ', ')" -ForegroundColor Red
        exit 1
    }

    return $true
}

function Backup-FileToTimestampDir {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Host "[SKIP] $Source skipped (not present)" -ForegroundColor Yellow
        return $null
    }

    $destination = Join-Path $BackupRoot $Label
    $destinationParent = Split-Path -Path $destination -Parent
    if (-not [string]::IsNullOrWhiteSpace($destinationParent)) {
        New-Item -Path $destinationParent -ItemType Directory -Force | Out-Null
    }

    # Retry-with-backoff for transient file-in-use errors. Extension host
    # processes (Cline, Blackbox, etc.) release their log file handles a few
    # seconds after the parent Qoder process exits -- on Windows that gap is
    # long enough that a single Copy-Item can fail mid-tree. 6 attempts *
    # 500/1000/.../3000ms backoff = ~10.5s total. If still locked, return $null
    # so the caller can proceed with deletion (the file may now be deletable
    # even though Copy-Item couldn't read it).
    $lastError = $null
    for ($i = 0; $i -lt 6; $i++) {
        try {
            Copy-Item -LiteralPath $Source -Destination $destination -Recurse -Force -ErrorAction Stop | Out-Null
            return $destination
        }
        catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds (500 * ($i + 1))
        }
    }

    Write-Host "[WARN] backup skipped after retries (file locked?): $Source -- $lastError" -ForegroundColor Yellow
    return $null
}

function Set-JsonIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Updates,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [string]$BackupRoot,
        [string]$BackupLabel,
        [ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        foreach ($key in $Updates.Keys) {
            Add-AuditEntry -Audit $Audit -File $Path -Key $key -Before $null -After $Updates[$key] -Ok $false
        }
        Write-Host "[FAILED] JSON file not found: $Path" -ForegroundColor Red
        return $false
    }

    if ($PSBoundParameters.ContainsKey("BackupRoot") -and $PSBoundParameters.ContainsKey("Actions")) {
        $effectiveBackupLabel = if ([string]::IsNullOrWhiteSpace($BackupLabel)) { Get-PathBackupLabel -Path $Path } else { $BackupLabel }
        $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $effectiveBackupLabel
        if ($backupPath) {
            if ($null -eq $Actions.Value) {
                $Actions.Value = @()
            }

            $Actions.Value += [ordered]@{
                action       = "copy"
                originalPath = $Path
                backupPath   = $backupPath
                renamedPath  = $null
            }
        }
    }

    try {
        $content = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        foreach ($key in $Updates.Keys) {
            Add-AuditEntry -Audit $Audit -File $Path -Key $key -Before $null -After $Updates[$key] -Ok $false
        }
        Write-Host "[FAILED] could not parse JSON: $Path" -ForegroundColor Red
        return $false
    }

    $beforeValues = @{}
    foreach ($key in $Updates.Keys) {
        $beforeValues[$key] = if (Test-ObjectProperty -Object $content -Name $key) { $content.$key } else { $null }

        if (Test-ObjectProperty -Object $content -Name $key) {
            $content.$key = $Updates[$key]
        }
        else {
            Add-Member -InputObject $content -NotePropertyName $key -NotePropertyValue $Updates[$key]
        }
    }

    [System.IO.File]::WriteAllText($Path, ($content | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding $false))

    try {
        $verifiedContent = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        foreach ($key in $Updates.Keys) {
            Add-AuditEntry -Audit $Audit -File $Path -Key $key -Before $beforeValues[$key] -After $Updates[$key] -Ok $false
        }
        Write-Host "[FAILED] could not re-read JSON after write: $Path" -ForegroundColor Red
        return $false
    }

    $allMatched = $true
    foreach ($key in $Updates.Keys) {
        $actualValue = if (Test-ObjectProperty -Object $verifiedContent -Name $key) { $verifiedContent.$key } else { $null }
        $ok = $actualValue -eq $Updates[$key]
        Add-AuditEntry -Audit $Audit -File $Path -Key $key -Before $beforeValues[$key] -After $actualValue -Ok $ok
        if (-not $ok) {
            $allMatched = $false
        }
    }

    return $allMatched
}

function Set-SqliteKeys {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Updates,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [string]$Table = "ItemTable",
        [string]$BackupRoot,
        [string]$BackupLabel,
        [ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        foreach ($key in $Updates.Keys) {
            Add-AuditEntry -Audit $Audit -File $Path -Key $key -Before $null -After $Updates[$key] -Ok $false
        }
        Write-Host "[FAILED] SQLite database not found: $Path" -ForegroundColor Red
        return $false
    }

    if ($PSBoundParameters.ContainsKey("BackupRoot") -and $PSBoundParameters.ContainsKey("Actions")) {
        $effectiveBackupLabel = if ([string]::IsNullOrWhiteSpace($BackupLabel)) { Get-PathBackupLabel -Path $Path } else { $BackupLabel }
        $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $effectiveBackupLabel
        if ($backupPath) {
            if ($null -eq $Actions.Value) {
                $Actions.Value = @()
            }

            $Actions.Value += [ordered]@{
                action       = "copy"
                originalPath = $Path
                backupPath   = $backupPath
                renamedPath  = $null
            }
        }
    }

    if ($Table -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        foreach ($key in $Updates.Keys) {
            Add-AuditEntry -Audit $Audit -File $Path -Key $key -Before $null -After $Updates[$key] -Ok $false
        }
        throw "Unsafe SQLite table name: $Table"
    }

    $pythonCommand = Get-PythonCommandInfo
    if (-not $pythonCommand) {
        foreach ($key in $Updates.Keys) {
            Add-AuditEntry -Audit $Audit -File $Path -Key $key -Before $null -After $Updates[$key] -Ok $false
        }
        Write-Host "Python not found - SQLite update SKIPPED (manual edit required)" -ForegroundColor Yellow
        return $false
    }

    $updatesBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(($Updates | ConvertTo-Json -Compress)))
    $tempScriptPath = Join-Path $env:TEMP ("sqlite_update_{0}.py" -f ([guid]::NewGuid().ToString("N")))
    $pythonScript = @"
import base64
import json
import sqlite3
import sys

db_path = sys.argv[1]
updates = json.loads(base64.b64decode(sys.argv[2]).decode("utf-8"))
table_name = "$Table"

conn = sqlite3.connect(db_path)
try:
    cursor = conn.cursor()
    before = {}
    for key in updates.keys():
        cursor.execute("SELECT value FROM " + table_name + " WHERE key = ?", (key,))
        row = cursor.fetchone()
        before[key] = None if row is None else row[0]

    cursor.execute("CREATE TABLE IF NOT EXISTS " + table_name + " (key TEXT PRIMARY KEY, value TEXT)")
    for key, value in updates.items():
        cursor.execute("INSERT OR REPLACE INTO " + table_name + " (key, value) VALUES (?, ?)", (key, value))
    conn.commit()
finally:
    conn.close()

verify_conn = sqlite3.connect("file:" + db_path + "?mode=ro", uri=True)
try:
    verify_cursor = verify_conn.cursor()
    after = {}
    for key in updates.keys():
        verify_cursor.execute("SELECT value FROM " + table_name + " WHERE key = ?", (key,))
        row = verify_cursor.fetchone()
        after[key] = None if row is None else row[0]
finally:
    verify_conn.close()

print(json.dumps({"before": before, "after": after}))
"@

    try {
        Set-Content -LiteralPath $tempScriptPath -Value $pythonScript -Encoding UTF8
        $commandOutput = & $pythonCommand.Source $tempScriptPath $Path $updatesBase64
        if ($LASTEXITCODE -ne 0) {
            foreach ($key in $Updates.Keys) {
                Add-AuditEntry -Audit $Audit -File $Path -Key $key -Before $null -After $Updates[$key] -Ok $false
            }
            Write-Host "[FAILED] SQLite update command failed: $Path" -ForegroundColor Red
            return $false
        }

        $result = ($commandOutput -join "`n") | ConvertFrom-Json
        $allMatched = $true
        foreach ($key in $Updates.Keys) {
            $actualValue = $result.after.$key
            $ok = $actualValue -eq $Updates[$key]
            Add-AuditEntry -Audit $Audit -File $Path -Key $key -Before $result.before.$key -After $actualValue -Ok $ok
            if (-not $ok) {
                $allMatched = $false
            }
        }

        return $allMatched
    }
    catch {
        foreach ($key in $Updates.Keys) {
            Add-AuditEntry -Audit $Audit -File $Path -Key $key -Before $null -After $Updates[$key] -Ok $false
        }
        Write-Host "[FAILED] SQLite update threw an error: $Path" -ForegroundColor Red
        return $false
    }
    finally {
        if (Test-Path -LiteralPath $tempScriptPath) {
            Remove-Item -LiteralPath $tempScriptPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Clear-BinaryIdentityStore {
    param(
        [Parameter(Mandatory = $true)][string[]]$Paths,
        [ValidateSet("rename", "delete")][string]$Action = "rename",
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [string]$RootPath
    )

    $actions = @()
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            Add-AuditEntry -Audit $Audit -File $path -Key "binary-store" -Before "missing" -After "skipped" -Ok $true
            continue
        }

        $backupLabel = if ($RootPath -and $path.StartsWith($RootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $path.Substring($RootPath.Length).TrimStart('\')
        } else {
            Get-PathBackupLabel -Path $path
        }
        $backupPath = Backup-FileToTimestampDir -Source $path -BackupRoot $BackupRoot -Label $backupLabel

        if ($Action -eq "rename") {
            $renamedPath = "$path.backup"
            if (Test-Path -LiteralPath $renamedPath) {
                # Best-effort cleanup of stale .backup; doesn't matter if it fails.
                $null = Remove-Item -LiteralPath $renamedPath -Recurse -Force -ErrorAction SilentlyContinue
            }

            # Retry-with-backoff for transient file locks. Same rationale as the
            # backup helper -- exthost processes release file handles a few seconds
            # after parent exit. Record failure rather than throw so the calling
            # step can continue with other paths.
            $renameOk = $false
            $renameLastError = $null
            for ($i = 0; $i -lt 6; $i++) {
                try {
                    Rename-Item -LiteralPath $path -NewName ([System.IO.Path]::GetFileName($renamedPath)) -ErrorAction Stop
                    $renameOk = $true
                    break
                }
                catch {
                    $renameLastError = $_.Exception.Message
                    Start-Sleep -Milliseconds (500 * ($i + 1))
                }
            }

            if ($renameOk) {
                Add-AuditEntry -Audit $Audit -File $path -Key "binary-store" -Before "present" -After ("renamed to " + $renamedPath) -Ok $true
                $actions += [ordered]@{
                    action      = "rename"
                    originalPath = $path
                    backupPath  = $backupPath
                    renamedPath = $renamedPath
                }
            }
            else {
                Add-AuditEntry -Audit $Audit -File $path -Key "binary-store" -Before "present" -After ("rename-failed: " + $renameLastError) -Ok $false
            }
        }
        else {
            # Retry-with-backoff delete. See backup helper for rationale. If the
            # tree still can't be removed after ~10.5s of retries, record the
            # failure and let the calling step continue.
            $deleteOk = $false
            $deleteLastError = $null
            for ($i = 0; $i -lt 6; $i++) {
                try {
                    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                    $deleteOk = $true
                    break
                }
                catch {
                    $deleteLastError = $_.Exception.Message
                    Start-Sleep -Milliseconds (500 * ($i + 1))
                }
            }

            if ($deleteOk) {
                Add-AuditEntry -Audit $Audit -File $path -Key "binary-store" -Before "present" -After "deleted" -Ok $true
                $actions += [ordered]@{
                    action       = "delete"
                    originalPath = $path
                    backupPath   = $backupPath
                    renamedPath  = $null
                }
            }
            else {
                Add-AuditEntry -Audit $Audit -File $path -Key "binary-store" -Before "present" -After ("delete-failed: " + $deleteLastError) -Ok $false
            }
        }
    }

    return $actions
}

function Write-AuditLog {
    param(
        [Parameter(Mandatory = $true)][array]$Audit,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    $Audit | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-RestoreScript {
    param(
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$App,
        [Parameter(Mandatory = $true)][array]$Actions
    )

    $timestamp = Split-Path -Path $BackupRoot -Leaf
    if ([string]::IsNullOrWhiteSpace($timestamp)) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    }

    $restorePath = Join-Path $BackupRoot ("restore_{0}_{1}.ps1" -f $App, $timestamp)
    $manifestJson = $Actions | ConvertTo-Json -Depth 15
    $scriptContent = @"
`$ErrorActionPreference = "Stop"

function Ensure-ParentDirectory {
    param([string]`$Path)
    `$parent = Split-Path -Path `$Path -Parent
    if (-not [string]::IsNullOrWhiteSpace(`$parent)) {
        New-Item -Path `$parent -ItemType Directory -Force | Out-Null
    }
}

function Restore-Entry {
    param([pscustomobject]`$Entry)

    if (`$Entry.renamedPath -and (Test-Path -LiteralPath `$Entry.renamedPath)) {
        if (Test-Path -LiteralPath `$Entry.originalPath) {
            Remove-Item -LiteralPath `$Entry.originalPath -Recurse -Force
        }

        Ensure-ParentDirectory -Path `$Entry.originalPath
        Rename-Item -LiteralPath `$Entry.renamedPath -NewName ([System.IO.Path]::GetFileName(`$Entry.originalPath))
        Write-Host ("[RESTORED] " + `$Entry.originalPath) -ForegroundColor Green
        return
    }

    if (`$Entry.backupPath -and (Test-Path -LiteralPath `$Entry.backupPath)) {
        if (Test-Path -LiteralPath `$Entry.originalPath) {
            Remove-Item -LiteralPath `$Entry.originalPath -Recurse -Force
        }

        Ensure-ParentDirectory -Path `$Entry.originalPath
        Copy-Item -LiteralPath `$Entry.backupPath -Destination `$Entry.originalPath -Recurse -Force
        Write-Host ("[RESTORED] " + `$Entry.originalPath) -ForegroundColor Green
        return
    }

    Write-Host ("[SKIP] backup missing for " + `$Entry.originalPath) -ForegroundColor Yellow
}

`$manifestJson = @'
$manifestJson
'@

`$manifest = `$manifestJson | ConvertFrom-Json
foreach (`$entry in `$manifest) {
    Restore-Entry -Entry `$entry
}
"@

    Set-Content -LiteralPath $restorePath -Value $scriptContent -Encoding UTF8
    return $restorePath
}

function Get-NewCrashReporterId {
    return ([guid]::NewGuid().ToString()).ToLowerInvariant()
}
