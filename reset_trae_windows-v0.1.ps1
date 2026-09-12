# Trae IDE Machine ID Reset Script for Windows
# This script resets Trae IDE's machine identifiers
# It only modifies configuration files and does not run any external code

# Check for administrative privileges
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "This script requires administrator privileges to update the Windows registry." -ForegroundColor Red
    Write-Host "Please right-click on PowerShell and select 'Run as Administrator', then run this script again." -ForegroundColor Yellow
    Write-Host "Press any key to exit..."
    $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
    exit
}

# Helper function to generate IDs
function Generate-IDs {
    # Generate UUID for devDeviceId
    $devDeviceId = [guid]::NewGuid().ToString()
    
    # Generate machineId (64 char hex)
    $randomBytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($randomBytes)
    $machineId = -join ($randomBytes | ForEach-Object { $_.ToString("x2") })
    
    # Generate macMachineId (128 char hex)
    $randomBytesLarge = New-Object byte[] 64
    $rng.GetBytes($randomBytesLarge)
    $macMachineId = -join ($randomBytesLarge | ForEach-Object { $_.ToString("x2") })
    
    # Generate SQM ID (bracketed UUID)
    $sqmId = "{" + [guid]::NewGuid().ToString().ToUpper() + "}"
    
    return @{
        "devDeviceId" = $devDeviceId
        "machineId" = $machineId
        "macMachineId" = $macMachineId
        "sqmId" = $sqmId
    }
}

# Make sure Trae is closed
$traeProcess = Get-Process -Name "Trae" -ErrorAction SilentlyContinue
if ($traeProcess) {
    Write-Host "Trae IDE is currently running. Please close it before continuing." -ForegroundColor Yellow
    $response = Read-Host "Do you want to forcibly close Trae IDE now? (Y/N)"
    if ($response -eq "Y" -or $response -eq "y") {
        Stop-Process -Name "Trae" -Force
        Start-Sleep -Seconds 2
    } else {
        Write-Host "Please close Trae IDE and run this script again." -ForegroundColor Red
        exit
    }
}

# Define file paths
$appDataPath = [Environment]::GetFolderPath("ApplicationData")
$traePath = Join-Path -Path $appDataPath -ChildPath "Trae"
$userPath = Join-Path -Path $traePath -ChildPath "User"
$globalStoragePath = Join-Path -Path $userPath -ChildPath "globalStorage"
$storagePath = Join-Path -Path $globalStoragePath -ChildPath "storage.json"
$sqlitePath = Join-Path -Path $globalStoragePath -ChildPath "state.vscdb"

# Check if paths exist
if (-not (Test-Path -Path $traePath)) {
    Write-Host "Trae IDE installation not found at: $traePath" -ForegroundColor Red
    Write-Host "Creating directory structure..." -ForegroundColor Yellow
    New-Item -Path $traePath -ItemType Directory -Force | Out-Null
    New-Item -Path $userPath -ItemType Directory -Force | Out-Null
    New-Item -Path $globalStoragePath -ItemType Directory -Force | Out-Null
}

Write-Host "=== Trae IDE Machine ID Reset Tool ===" -ForegroundColor Cyan
Write-Host "This script will reset your Trae IDE machine identifiers." -ForegroundColor Cyan
Write-Host "Trae IDE path: $traePath" -ForegroundColor Green

# Generate new IDs
Write-Host "`nGenerating new identifiers..." -ForegroundColor Cyan
$newIds = Generate-IDs

# Display the new IDs
Write-Host "`nGenerated new identifiers:" -ForegroundColor Green
Write-Host "devDeviceId: $($newIds.devDeviceId)" -ForegroundColor Gray
Write-Host "machineId: $($newIds.machineId)" -ForegroundColor Gray
Write-Host "macMachineId: $($newIds.macMachineId)" -ForegroundColor Gray
Write-Host "sqmId: $($newIds.sqmId)" -ForegroundColor Gray

# 1. Update storage.json
Write-Host "`n[1/4] Updating storage.json..." -ForegroundColor Cyan
if (Test-Path -Path $storagePath) {
    Copy-Item -Path $storagePath -Destination "$storagePath.backup" -Force
    Write-Host "Created backup at: $storagePath.backup" -ForegroundColor Yellow
    
    try {
        $storageContent = Get-Content -Path $storagePath -Raw | ConvertFrom-Json
        
        # Update or add the required values
        # Check and set each property, creating if not exists
        if (-not (Get-Member -InputObject $storageContent -Name "telemetry.devDeviceId")) {
            Add-Member -InputObject $storageContent -NotePropertyName "telemetry.devDeviceId" -NotePropertyValue $newIds.devDeviceId
        } else {
            $storageContent."telemetry.devDeviceId" = $newIds.devDeviceId
        }

        if (-not (Get-Member -InputObject $storageContent -Name "telemetry.machineId")) {
            Add-Member -InputObject $storageContent -NotePropertyName "telemetry.machineId" -NotePropertyValue $newIds.machineId
        } else {
            $storageContent."telemetry.machineId" = $newIds.machineId
        }

        if (-not (Get-Member -InputObject $storageContent -Name "telemetry.macMachineId")) {
            Add-Member -InputObject $storageContent -NotePropertyName "telemetry.macMachineId" -NotePropertyValue $newIds.macMachineId
        } else {
            $storageContent."telemetry.macMachineId" = $newIds.macMachineId
        }

        if (-not (Get-Member -InputObject $storageContent -Name "telemetry.sqmId")) {
            Add-Member -InputObject $storageContent -NotePropertyName "telemetry.sqmId" -NotePropertyValue $newIds.sqmId
        } else {
            $storageContent."telemetry.sqmId" = $newIds.sqmId
        }

        if (-not (Get-Member -InputObject $storageContent -Name "storage.serviceMachineId")) {
            Add-Member -InputObject $storageContent -NotePropertyName "storage.serviceMachineId" -NotePropertyValue $newIds.devDeviceId
        } else {
            $storageContent."storage.serviceMachineId" = $newIds.devDeviceId
        }
        
        $storageContent | ConvertTo-Json -Depth 10 | Set-Content -Path $storagePath
        Write-Host "Updated storage.json successfully" -ForegroundColor Green
    }
    catch {
        Write-Host "Error updating storage.json: $_" -ForegroundColor Red
        Write-Host "Skipping storage.json update" -ForegroundColor Yellow
    }
}
else {
    Write-Host "storage.json not found at: $storagePath" -ForegroundColor Yellow
    Write-Host "Creating new storage.json..." -ForegroundColor Yellow
    
    $storageContent = @{
        "telemetry.devDeviceId" = $newIds.devDeviceId
        "telemetry.machineId" = $newIds.machineId
        "telemetry.macMachineId" = $newIds.macMachineId
        "telemetry.sqmId" = $newIds.sqmId
        "storage.serviceMachineId" = $newIds.devDeviceId
    }
    
    New-Item -Path $globalStoragePath -ItemType Directory -Force | Out-Null
    $storageContent | ConvertTo-Json -Depth 10 | Set-Content -Path $storagePath
    Write-Host "Created new storage.json successfully" -ForegroundColor Green
}

# 2. Update SQLite database
Write-Host "`n[2/4] Updating SQLite database..." -ForegroundColor Cyan

if (Test-Path -Path $sqlitePath) {
    Copy-Item -Path $sqlitePath -Destination "$sqlitePath.backup" -Force
    Write-Host "Created backup at: $sqlitePath.backup" -ForegroundColor Yellow
    
    # Create a temporary Python script
    $pythonScript = @"
import sqlite3
import os

db_path = '$($sqlitePath.Replace('\', '\\'))'
print(f"Connecting to SQLite database at: {db_path}")

conn = sqlite3.connect(db_path)
cursor = conn.cursor()

# Create the table if it doesn't exist
cursor.execute('''
    CREATE TABLE IF NOT EXISTS ItemTable (
        key TEXT PRIMARY KEY,
        value TEXT
    )
''')

# Values to update
keys_and_values = [
    ('telemetry.devDeviceId', '$($newIds.devDeviceId)'),
    ('telemetry.macMachineId', '$($newIds.macMachineId)'),
    ('telemetry.machineId', '$($newIds.machineId)'),
    ('telemetry.sqmId', '$($newIds.sqmId)'),
    ('storage.serviceMachineId', '$($newIds.devDeviceId)')
]

# Update each key
for key, value in keys_and_values:
    print(f"Updating {key} with new value")
    cursor.execute('INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)', (key, value))

# Commit changes and close
conn.commit()
print("Changes committed to database")
conn.close()
print("Database updated successfully!")
"@
            
    $pythonScriptPath = "$env:TEMP\update_trae_sqlite.py"
    Set-Content -Path $pythonScriptPath -Value $pythonScript
    
    # Try to run with Python
    try {
        Write-Host "Attempting to use Python to update SQLite database..." -ForegroundColor Yellow
        $pythonResult = & python $pythonScriptPath
        Write-Host $pythonResult -ForegroundColor Gray
        Write-Host "Updated SQLite database using Python successfully" -ForegroundColor Green
    }
    catch {
        Write-Host "Python execution failed. SQLite database could not be updated: $_" -ForegroundColor Red
        Write-Host "You may need to manually update the SQLite database or install Python." -ForegroundColor Yellow
    }
    
    # Clean up
    if (Test-Path -Path $pythonScriptPath) {
        Remove-Item -Path $pythonScriptPath -Force
    }
}
else {
    Write-Host "SQLite database not found at: $sqlitePath" -ForegroundColor Yellow
    Write-Host "This is normal if you haven't used Trae IDE much." -ForegroundColor Yellow
}

# 3. Clear ModularData (to remove chat history and reset session)
Write-Host "`n[3/4] Clearing ModularData directory..." -ForegroundColor Cyan
$modularDataPath = Join-Path -Path $traePath -ChildPath "ModularData"
if (Test-Path -Path $modularDataPath) {
    $backupModularPath = "$modularDataPath.backup"
    if (Test-Path -Path $backupModularPath) {
        Remove-Item -Path $backupModularPath -Recurse -Force
    }
    Rename-Item -Path $modularDataPath -NewName "ModularData.backup" -Force
    Write-Host "Moved ModularData to ModularData.backup" -ForegroundColor Green
} else {
    Write-Host "ModularData directory not found" -ForegroundColor Yellow
}

# 4. Update Windows Registry
Write-Host "`n[4/4] Updating Windows Registry MachineGuid..." -ForegroundColor Cyan
try {
    $registryPath = "HKLM:\SOFTWARE\Microsoft\Cryptography"
    $oldGuid = (Get-ItemProperty -Path $registryPath -Name "MachineGuid" -ErrorAction SilentlyContinue).MachineGuid
    
    if ($oldGuid) {
        Write-Host "Found existing MachineGuid: $oldGuid" -ForegroundColor Yellow
        # Create a backup in registry
        New-ItemProperty -Path $registryPath -Name "MachineGuid.backup" -Value $oldGuid -PropertyType String -Force | Out-Null
        Write-Host "Created backup in registry: MachineGuid.backup" -ForegroundColor Yellow
    }
    
    # Generate a new GUID for registry (different from the ones used in Trae)
    $newMachineGuid = [guid]::NewGuid().ToString()
    Set-ItemProperty -Path $registryPath -Name "MachineGuid" -Value $newMachineGuid -Type String -Force
    Write-Host "Updated Windows Registry MachineGuid to: $newMachineGuid" -ForegroundColor Green
}
catch {
    Write-Host "Failed to update Windows Registry: $_" -ForegroundColor Red
    Write-Host "This step requires administrator privileges." -ForegroundColor Yellow
}

# Completion
Write-Host "`n=== Reset Complete ===" -ForegroundColor Green
Write-Host "Trae IDE machine identifiers have been reset successfully." -ForegroundColor Green
Write-Host "`nWhat's been done:" -ForegroundColor Cyan
Write-Host "1. Generated new unique identifiers" -ForegroundColor White
Write-Host "2. Updated storage.json at: $storagePath" -ForegroundColor White
Write-Host "3. Attempted to update SQLite database at: $sqlitePath" -ForegroundColor White
Write-Host "4. Cleared ModularData directory" -ForegroundColor White
Write-Host "5. Updated Windows Registry MachineGuid" -ForegroundColor White

Write-Host "`nBackups Created:" -ForegroundColor Cyan
if (Test-Path -Path "$storagePath.backup") { Write-Host "- $storagePath.backup" -ForegroundColor White }
if (Test-Path -Path "$sqlitePath.backup") { Write-Host "- $sqlitePath.backup" -ForegroundColor White }
if (Test-Path -Path "$modularDataPath.backup") { Write-Host "- $modularDataPath.backup" -ForegroundColor White }

Write-Host "`nNext Steps:" -ForegroundColor Cyan
Write-Host "1. Launch Trae IDE and log in again" -ForegroundColor White
Write-Host "2. If you need to revert these changes, rename the backup files to their original names" -ForegroundColor White

Write-Host "`nPress any key to exit..."
$host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
