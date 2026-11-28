#Requires -Version 5.1
# JSON-only read probe for the mesh. A colored exe alone is not proof of
# its profile: launched bare, it can open Primary. Check userData markers.
param([object[]]$Processes)
$ErrorActionPreference = 'Stop'
$all = @('Primary','c1','c2','c3','c4','c5')
$roaming = $env:APPDATA
if (-not $roaming) { $roaming = [Environment]::GetFolderPath('ApplicationData') }
$homes = @{ Primary = Join-Path $roaming 'AutoClaw-oversea-official' }
foreach ($target in $all[1..5]) {
    $homes[$target] = Join-Path $env:USERPROFILE "AutoClaw2ClonesHome\$target"
}
if (-not $PSBoundParameters.ContainsKey('Processes')) {
    $Processes = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoClaw2%'" -OperationTimeoutSec 5)
    # A failed or racing CIM snapshot must never look like all apps closed.
    $live = @(Get-Process -Name 'AutoClaw2*' -ErrorAction SilentlyContinue | ForEach-Object Id)
    $seen = @($Processes | ForEach-Object ProcessId)
    if (@($live | Where-Object { $_ -notin $seen }).Count) {
        ConvertTo-Json -InputObject $all -Compress
        exit 0
    }
}
$byId = @{}
foreach ($p in $Processes) { $byId[[int]$p.ProcessId] = $p }
$groups = @{}
foreach ($p in $Processes) {
    $root = $p
    $guard = 0
    while ($byId.ContainsKey([int]$root.ParentProcessId) -and $guard -le $Processes.Count) {
        $root = $byId[[int]$root.ParentProcessId]
        $guard++
    }
    if ($guard -gt $Processes.Count) {
        ConvertTo-Json -InputObject $all -Compress
        exit 0
    }
    $id = [int]$root.ProcessId
    if (-not $groups.ContainsKey($id)) { $groups[$id] = @() }
    $groups[$id] += $p
}
$busy = @()
foreach ($family in $groups.Values) {
    $found = @()
    foreach ($member in $family) {
        $arg = [regex]::Match([string]$member.CommandLine, '(?i)(?:^|\s)--user-data-dir=(?:"([^"]+)"|([^\s"]+))')
        if (-not $arg.Success) { continue }
        $path = ($arg.Groups[1].Value + $arg.Groups[2].Value).TrimEnd('\','/')
        foreach ($name in $homes.Keys) { if ($path -ieq $homes[$name]) { $found += $name } }
    }
    if (-not $found.Count) {
        ConvertTo-Json -InputObject $all -Compress
        exit 0
    }
    $busy += $found
}
ConvertTo-Json -InputObject @($busy | Sort-Object -Unique) -Compress
