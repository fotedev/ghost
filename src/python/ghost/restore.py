"""Restore-script generator — port of New-RestoreScript in
identity_utils.ps1.

Generates a SELF-CONTAINED PowerShell rollback script at
<BackupRoot>/restore_<App>_<timestamp>.ps1 embedding the actions manifest
(action=copy|rename|delete, originalPath, backupPath, renamedPath). The
generated script is byte-compatible in behavior with the PowerShell
generator: rename-back takes precedence, copy fallback second, missing
backups are SKIPped with a warning -- never a silent failure.
"""

import datetime
import json
import os

_RESTORE_HEAD = '''$ErrorActionPreference = "Stop"

function Ensure-ParentDirectory {
    param([string]$Path)
    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
}

function Restore-Entry {
    param([pscustomobject]$Entry)

    if ($Entry.renamedPath -and (Test-Path -LiteralPath $Entry.renamedPath)) {
        if (Test-Path -LiteralPath $Entry.originalPath) {
            Remove-Item -LiteralPath $Entry.originalPath -Recurse -Force
        }

        Ensure-ParentDirectory -Path $Entry.originalPath
        Rename-Item -LiteralPath $Entry.renamedPath -NewName ([System.IO.Path]::GetFileName($Entry.originalPath))
        Write-Host ("[RESTORED] " + $Entry.originalPath) -ForegroundColor Green
        return
    }

    if ($Entry.backupPath -and (Test-Path -LiteralPath $Entry.backupPath)) {
        if (Test-Path -LiteralPath $Entry.originalPath) {
            Remove-Item -LiteralPath $Entry.originalPath -Recurse -Force
        }

        Ensure-ParentDirectory -Path $Entry.originalPath
        Copy-Item -LiteralPath $Entry.backupPath -Destination $Entry.originalPath -Recurse -Force
        Write-Host ("[RESTORED] " + $Entry.originalPath) -ForegroundColor Green
        return
    }

    Write-Host ("[SKIP] backup missing for " + $Entry.originalPath) -ForegroundColor Yellow
}

$manifestJson = @'
'''

_RESTORE_TAIL = '''
'@

$manifest = $manifestJson | ConvertFrom-Json
foreach ($entry in $manifest) {
    Restore-Entry -Entry $entry
}
'''


def new_restore_script(backup_root, app, actions):
    """Write the rollback script and return its path.

    `actions` is a list of dicts with keys action/originalPath/backupPath/
    renamedPath (missing keys are written as JSON nulls, matching the
    PowerShell ordered-hashtable output)."""
    timestamp = os.path.basename(os.path.normpath(backup_root))
    if not timestamp.strip():
        timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")

    restore_path = os.path.join(
        backup_root, "restore_{0}_{1}.ps1".format(app, timestamp))

    manifest_json = json.dumps(list(actions), indent=2, ensure_ascii=False,
                               default=str)
    script = _RESTORE_HEAD + manifest_json + _RESTORE_TAIL

    # A manifest line could theoretically terminate the single-quoted
    # here-string ('@ at column 0); JSON-indent guarantees no line starts
    # with a quote, so this is structurally safe, but assert anyway.
    assert "\n'@" not in manifest_json

    with open(restore_path, "w", encoding="utf-8", newline="\r\n") as f:
        f.write(script)
    return restore_path
