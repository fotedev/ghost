# SPDX-License-Identifier: Apache-2.0
#Requires -Version 5.1
<#
.SYNOPSIS
  Pure merge core for ZCode memory-store syncing - no audit, no exit codes,
  no process state. Shared by tools\sync_zcode_memories.ps1 (which owns the
  robocopy merge / move-aside / junction / verify / audit orchestration) and
  unit-tested by tests\zcode_memory_merge.Tests.ps1.

.DESCRIPTION
  The memory store (cli\memories\projects\<slug>\memory\*.md) is plain UTF-8
  (no BOM) markdown written by the app harness. Two invariants:

  1. Index union (Merge-MemoryIndexLines): the Primary's MEMORY.md lines keep
     their order and are never removed; clone-only lines are appended in
     clone order; comparison is on trimmed lines; every line is de-mojibaked
     BEFORE the compare, so a pre-existing mojibake variant collapses onto
     its clean original instead of accumulating as a new entry.

  2. Mojibake peel (ConvertFrom-MojibakeLayers): the historical failure mode
     (2026-11-21 live incident: PS 5.1 Get-Content defaults to ANSI, so UTF-8
     index lines were re-appended re-mangled one layer deeper per merge pass -
     one real index reached 7749 lines holding 845 unique). Each layer is
     reversible by re-encoding the string to CP1252 and STRICT-decoding the
     bytes as UTF-8 (invalid sequences stop the peel). A line containing
     characters outside CP1252 (e.g. Arabic) can never be mis-peeled: the
     encode throws first and the line is returned unchanged.

  All file helpers are explicit no-BOM UTF-8 - NEVER Get-Content/Add-Content
  defaults (PS 5.1 ANSI), the exact bug that produced the incident.
#>

$script:StrictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
# CP1252 with EXCEPTION fallback on both sides - NOT the bare GetEncoding(1252):
# .NET's default encoder BEST-FITS unmappable characters (Arabic alef -> '?',
# byte 0x3F) instead of throwing, which would silently corrupt every non-CP1252
# line the peel is meant to leave untouched.
$script:Cp1252     = [System.Text.Encoding]::GetEncoding(1252, [System.Text.EncoderFallback]::ExceptionFallback, [System.Text.DecoderFallback]::ExceptionFallback)
$script:Utf8NoBom  = New-Object System.Text.UTF8Encoding($false)

function ConvertFrom-MojibakeLayers {
    <#
    .SYNOPSIS
      Peel all reversible UTF-8-as-CP1252 mojibake layers off a line.
    .OUTPUTS
      string - the de-mangled line, or the input unchanged when it is clean
      (pure ASCII, or contains characters CP1252 cannot encode, or re-encoding
      does not decode as valid UTF-8).
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $current = $Text
    for ($i = 0; $i -lt 8; $i++) {
        try { $bytes = $script:Cp1252.GetBytes($current) } catch { return $current }
        try { $decoded = $script:StrictUtf8.GetString($bytes) } catch { return $current }
        if ($decoded -eq $current) { return $current }
        $current = $decoded
    }
    return $current
}

function Get-MemoryIndexLines {
    # Read a MEMORY.md as trimmed, non-empty lines (order preserved). The .NET
    # reader defaults to UTF-8 with BOM detection - unlike PS 5.1 Get-Content
    # (ANSI), which is the bug this module exists to prevent.
    param([Parameter(Mandatory = $true)][ValidateScript({ Test-Path -LiteralPath $_ })][string]$Path)
    $text = [System.IO.File]::ReadAllText($Path)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $lines = @($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return ,$lines   # comma preserves the array: a ONE-line index must not unwrap to a bare string
}

function Merge-MemoryIndexLines {
    <#
    .SYNOPSIS
      Ordered union of two MEMORY.md line sets (Primary first, clone-only
      appended in clone order, de-mojibaked + trimmed compare).
    .OUTPUTS
      string[] - the merged lines. Never removes a Primary line; a Primary
      line whose mojibake variant also appears on the clone collapses to one
      entry.
    #>
    param(
        [AllowEmptyCollection()][string[]]$PrimaryLines,
        [AllowEmptyCollection()][string[]]$CloneLines
    )
    # Ordinal case-SENSITIVE seen-set: a bare PS @{} has case-insensitive
    # keys, which would collapse two pointer lines differing only in case -
    # both belong in the index (the retention invariant).
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $out = @()
    foreach ($line in (@($PrimaryLines) + @($CloneLines))) {
        $clean = ConvertFrom-MojibakeLayers $line
        if ([string]::IsNullOrWhiteSpace($clean)) { continue }
        if ($seen.Add($clean)) { $out += $clean }
    }
    return ,$out
}

function Write-MemoryIndexLines {
    # Write lines as no-BOM UTF-8 with CRLF newlines (the store is
    # Windows-authored). PS 5.1's '-Encoding UTF8' would emit a BOM the way
    # Write-JsonNoBom avoids for JSON - same contract here, for markdown.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyCollection()][string[]]$Lines
    )
    [System.IO.File]::WriteAllLines($Path, @($Lines), $script:Utf8NoBom)
}
