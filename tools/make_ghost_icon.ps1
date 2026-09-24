# make_ghost_icon.ps1 - generate assets\ghost.ico (multi-size) from the GHOST poster art.
#
# Pipeline: source image -> auto-detect the app-tile bounds (checkerboard background
# classified per row/column profile) -> inset crop + anti-aliased rounded-corner alpha
# mask -> 1024px master -> per-size PNG-compressed ICO entries (16..256).
#
# The committed assets\ghost-source.png is the masked master. Re-runs prefer it and
# skip detection/masking entirely, so regeneration never depends on Downloads.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\make_ghost_icon.ps1 `
#       -Source "C:\path\to\ghost-poster.jpg"     # first run (bootstrap from poster jpg)
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\make_ghost_icon.ps1
#       (re-runs: uses committed assets\ghost-source.png as-is)
#
# Outputs: assets\ghost.ico, assets\ghost-source.png, TEMP preview PNGs (paths printed).

param(
    [string]$Source = "",
    [string]$OutDir = "",
    [int]$MasterSize = 1024,
    [double]$EdgeInsetPercent = 1.2,   # crops into the tile to drop the drop-shadow ring
    [double]$CornerRadiusPercent = 22.0,
    [int[]]$Sizes = @(16, 24, 32, 48, 64, 128, 256)
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'assets' }

$IcoPath = Join-Path $OutDir 'ghost.ico'
$MasterPngPath = Join-Path $OutDir 'ghost-source.png'

Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------- C# pixel core
$cs = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace GhostIcon
{
    public static class Core
    {
        // Checkerboard background = flat low-saturation gray in the two poster tones
        // (light cells ~203, white cells 255). Tile pixels are dark or colorful.
        static bool IsBackground(byte r, byte g, byte b)
        {
            int mx = Math.Max(r, Math.Max(g, b));
            int mn = Math.Min(r, Math.Min(g, b));
            if (mx - mn > 14) return false;
            int lum = (r * 299 + g * 587 + b * 114) / 1000;
            return (lum >= 188 && lum <= 220) || lum >= 238;
        }

        // Row/column background-fraction profiles; the tile is the single long run of
        // rows (then columns) whose background fraction is low.
        public static Rectangle DetectTileBounds(Bitmap bmp)
        {
            int w = bmp.Width, h = bmp.Height;
            BitmapData d = bmp.LockBits(new Rectangle(0, 0, w, h),
                ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
            int stride = d.Stride;
            byte[] px = new byte[stride * h];
            Marshal.Copy(d.Scan0, px, 0, px.Length);
            bmp.UnlockBits(d);

            int[] rowBg = new int[h];
            int[] colBg = new int[w];
            for (int y = 0; y < h; y++)
            {
                int memRow = y * stride;                 // memory row 0 = bottom image row
                int imgY = h - 1 - y;
                for (int x = 0; x < w; x++)
                {
                    int i = memRow + x * 3;
                    if (IsBackground(px[i + 2], px[i + 1], px[i]))
                    {
                        rowBg[imgY]++;
                        colBg[x]++;
                    }
                }
            }

            Rectangle rows = LongestLowRun(rowBg, w, 0.5);
            Rectangle cols = LongestLowRun(colBg, h, 0.5);
            return new Rectangle(cols.X, rows.X, cols.Width, rows.Width);
        }

        // Longest contiguous run of entries with fraction < threshold; entry spans
        // [X, X+Width) in index space.
        static Rectangle LongestLowRun(int[] counts, int denominator, double threshold)
        {
            int bestStart = -1, bestLen = 0, curStart = -1, curLen = 0;
            for (int i = 0; i < counts.Length; i++)
            {
                bool low = counts[i] < threshold * denominator;
                if (low)
                {
                    if (curStart < 0) { curStart = i; curLen = 1; } else curLen++;
                    if (curLen > bestLen) { bestLen = curLen; bestStart = curStart; }
                }
                else { curStart = -1; curLen = 0; }
            }
            if (bestStart < 0) throw new InvalidOperationException(
                "tile detection failed: no low-background run found");
            return new Rectangle(bestStart, 0, bestLen, 1);
        }

        static GraphicsPath RoundedRect(RectangleF r, float radius)
        {
            GraphicsPath p = new GraphicsPath();
            float d = radius * 2f;
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        static void CombineAlpha(Bitmap dst, Bitmap mask)
        {
            Rectangle rect = new Rectangle(0, 0, dst.Width, dst.Height);
            BitmapData dd = dst.LockBits(rect, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
            BitmapData md = mask.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            int stride = dd.Stride;
            byte[] db = new byte[stride * dst.Height];
            byte[] mb = new byte[md.Stride * mask.Height];
            Marshal.Copy(dd.Scan0, db, 0, db.Length);
            Marshal.Copy(md.Scan0, mb, 0, mb.Length);
            for (int y = 0; y < dst.Height; y++)
            {
                int row = y * stride;
                for (int x = 0; x < dst.Width; x++)
                    db[row + x * 4 + 3] = mb[y * md.Stride + x * 4 + 3]; // alpha := mask alpha
            }
            Marshal.Copy(db, 0, dd.Scan0, db.Length);
            dst.UnlockBits(dd);
            mask.UnlockBits(md);
        }

        // Inset square crop around the tile center + anti-aliased rounded-corner mask,
        // resampled to masterSize.
        public static Bitmap MakeMaster(Bitmap src, Rectangle b, double insetPct,
            double radiusPct, int masterSize)
        {
            int inset = (int)Math.Max(1.0, Math.Min(b.Width, b.Height) * insetPct / 100.0);
            int side = Math.Min(b.Width, b.Height) - 2 * inset;
            if (side < 64) throw new InvalidOperationException(
                "tile crop too small after inset: " + side + "px");
            int cx = b.X + b.Width / 2, cy = b.Y + b.Height / 2;
            Rectangle crop = new Rectangle(cx - side / 2, cy - side / 2, side, side);
            crop.Intersect(new Rectangle(0, 0, src.Width, src.Height));

            Bitmap master = new Bitmap(masterSize, masterSize, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(master))
            {
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.CompositingQuality = CompositingQuality.HighQuality;
                g.DrawImage(src, new Rectangle(0, 0, masterSize, masterSize), crop, GraphicsUnit.Pixel);
            }

            float rad = (float)(masterSize * radiusPct / 100.0);
            using (GraphicsPath p = RoundedRect(new RectangleF(0, 0, masterSize, masterSize), rad))
            using (Bitmap mask = new Bitmap(masterSize, masterSize, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Graphics.FromImage(mask))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.Clear(Color.Transparent);
                    g.FillPath(Brushes.White, p);
                }
                CombineAlpha(master, mask);
            }
            return master;
        }

        public static bool HasTransparentCorners(Bitmap bmp)
        {
            return bmp.GetPixel(2, 2).A == 0
                && bmp.GetPixel(bmp.Width - 3, 2).A == 0
                && bmp.GetPixel(2, bmp.Height - 3).A == 0;
        }
    }
}
'@
Add-Type -TypeDefinition $cs -ReferencedAssemblies 'System.Drawing' | Out-Null

# ------------------------------------------------------------------- load source
if (-not $Source) {
    if (Test-Path -LiteralPath $MasterPngPath) { $Source = $MasterPngPath }
    else { throw "No -Source given and no committed master at $MasterPngPath - pass -Source on first run." }
}
if (-not (Test-Path -LiteralPath $Source)) { throw "Source image not found: $Source" }

$srcBytes = [System.IO.File]::ReadAllBytes($Source)
$srcStream = New-Object System.IO.MemoryStream (, $srcBytes)
$src = [System.Drawing.Bitmap]::FromStream($srcStream)
Write-Host ("[1/5] Loaded source: {0} ({1}x{2})" -f $Source, $src.Width, $src.Height)

$master = $null
$savedMaster = $false
if ($src.Width -eq $src.Height -and [GhostIcon.Core]::HasTransparentCorners($src)) {
    Write-Host '[2/5] Source is already a masked master (transparent corners) - using as-is.'
    $master = $src
}
else {
    Write-Host '[2/5] Detecting tile bounds (checkerboard background profiles)...'
    $bounds = [GhostIcon.Core]::DetectTileBounds($src)
    Write-Host ("      tile bounds: x={0} y={1} w={2} h={3}" -f $bounds.X, $bounds.Y, $bounds.Width, $bounds.Height)
    $master = [GhostIcon.Core]::MakeMaster($src, $bounds, $EdgeInsetPercent, $CornerRadiusPercent, $MasterSize)

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $master.Save($MasterPngPath, [System.Drawing.Imaging.ImageFormat]::Png)
    if (-not (Test-Path -LiteralPath $MasterPngPath)) { throw 'FAILED: master PNG was not written' }
    $savedMaster = $true
    Write-Host ("      [ok] master saved: {0} ({1} KB)" -f $MasterPngPath, ([int]((Get-Item $MasterPngPath).Length / 1KB)))
}

# ------------------------------------------------------------- per-size renders
Write-Host '[3/5] Rendering ICO size entries...'
function Convert-MasterToPngBytes {
    param([System.Drawing.Bitmap]$M, [int]$S)
    $out = New-Object System.Drawing.Bitmap ($S), ($S)
    try {
        $g = [System.Drawing.Graphics]::FromImage($out)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.DrawImage($M, 0, 0, $S, $S)
        $g.Dispose()
        $ms = New-Object System.IO.MemoryStream
        $out.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        return ,$ms.ToArray()
    }
    finally { $out.Dispose() }
}

# --------------------------------------------------------------- write the .ico
Write-Host '[4/5] Writing ICO container...'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$sorted = @($Sizes | Sort-Object)
$pngs = @()
foreach ($s in $sorted) { $pngs += ,(Convert-MasterToPngBytes -M $master -S $s) }

$icoMs = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($icoMs)
$bw.Write([uint16]0)                      # reserved
$bw.Write([uint16]1)                      # type: icon
$bw.Write([uint16]$sorted.Count)          # image count
$offset = 6 + 16 * $sorted.Count
for ($i = 0; $i -lt $sorted.Count; $i++) {
    $s = $sorted[$i]
    $dim = $(if ($s -ge 256) { 0 } else { $s })   # 0 encodes 256 in ICO directory
    $bw.Write([byte]$dim); $bw.Write([byte]$dim)
    $bw.Write([byte]0); $bw.Write([byte]0)        # palette, reserved
    $bw.Write([uint16]1); $bw.Write([uint16]32)   # planes, bpp
    $bw.Write([uint32]$pngs[$i].Length)
    $bw.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $bw.Write($p) }
$bw.Flush()
[System.IO.File]::WriteAllBytes($IcoPath, $icoMs.ToArray())
$bw.Dispose(); $icoMs.Dispose()

# ------------------------------------------------------------------- verify-after
Write-Host '[5/5] Verifying outputs...'
if (-not (Test-Path -LiteralPath $IcoPath)) { throw 'FAILED: ghost.ico was not written' }
$check = [System.IO.File]::ReadAllBytes($IcoPath)
if ($check.Length -lt 6) { throw 'FAILED: ghost.ico is truncated' }
$vType = [BitConverter]::ToUInt16($check, 2)
$vCount = [BitConverter]::ToUInt16($check, 4)
if ($vType -ne 1 -or $vCount -ne $sorted.Count) {
    throw ("FAILED: ico header mismatch (type={0}, count={1}, expected count={2})" -f $vType, $vCount, $sorted.Count)
}
$total = 0
for ($i = 0; $i -lt $vCount; $i++) {
    $len = [BitConverter]::ToUInt32($check, 6 + 16 * $i + 8)
    $off = [BitConverter]::ToUInt32($check, 6 + 16 * $i + 12)
    if ($off + $len -gt $check.Length) { throw ("FAILED: ico entry {0} overruns file" -f $i) }
    $total += $len
}
Write-Host ("      [ok] {0} ({1} KB, {2} images: {3}, {4} KB image data)" -f `
    $IcoPath, [int]($check.Length / 1KB), $vCount, ($sorted -join '/'), [int]($total / 1KB))

# previews over light + dark backgrounds so corner masking is checkable at a glance
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
foreach ($bgName in @('light', 'dark')) {
    $bgColor = $(if ($bgName -eq 'light') { [System.Drawing.Color]::White } else { [System.Drawing.Color]::FromArgb(32, 32, 32) })
    $prev = New-Object System.Drawing.Bitmap (256), (256)
    $g = [System.Drawing.Graphics]::FromImage($prev)
    $g.Clear($bgColor)
    $g.DrawImage($master, 0, 0, 256, 256)
    $g.Dispose()
    $prevPath = Join-Path $env:TEMP ("ghost_icon_preview_{0}_{1}.png" -f $bgName, $stamp)
    $prev.Save($prevPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $prev.Dispose()
    Write-Host ("      preview ({0}): {1}" -f $bgName, $prevPath)
}

if ($master -ne $src) { $master.Dispose() }
$src.Dispose(); $srcStream.Dispose()
Write-Host 'DONE'
