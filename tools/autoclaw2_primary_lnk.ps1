#Requires -Version 5.1
# Shared stock-shortcut scope and drift checks for the AutoClaw2 installer
# and taskbar watcher. Color-named clone launchers are not stock shortcuts.
function Get-Ac2PrimaryShortcutPaths {
    param([string[]]$Roots = @(
        [Environment]::GetFolderPath('DesktopDirectory'),
        [Environment]::GetFolderPath('Programs')
    ))
    foreach ($root in ($Roots | Select-Object -Unique)) {
        if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($name in @('AutoClaw.lnk', 'AutoClaw2.lnk')) {
            $path = Join-Path $root $name
            if (Test-Path -LiteralPath $path -PathType Leaf) { $path }
        }
    }
}

function Get-Ac2PrimaryShortcutProblem {
    param([string]$TargetPath, [string]$Aumid, [string]$StockExe)
    $base = 'com.zhipuai.autoclaw2'
    $cloneId = $Aumid -match '^com\.zhipuai\.autoclaw2\.c[1-5]$'
    if ($Aumid -and $Aumid -ine $base -and -not $cloneId) { return }

    if ($TargetPath -ieq $StockExe) {
        if ($cloneId) { 'stock shortcut carries a clone identity' }
        return
    }
    $leaf = [IO.Path]::GetFileName($TargetPath)
    if (($leaf -match '^AutoClaw2-(Blue|Yellow|Green|Red|Orange)\.exe$') -and
        ([IO.Path]::GetDirectoryName($TargetPath) -ieq [IO.Path]::GetDirectoryName($StockExe))) {
        'stock shortcut targets a per-color executable'
    }
}
