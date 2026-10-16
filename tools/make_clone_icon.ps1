#Requires -Version 5.1
<#
.SYNOPSIS
  Generate a multi-size Windows icon (tray_icon.ico) + 1024 master (icon_windows.png)
  for a CLONE-APP branding dir, from a rendered source image (jpg/png).

.DESCRIPTION
  Generic, app-agnostic companion to tools\make_ghost_icon.ps1 (GHOST's own launcher
  icon). Intended for the app-cloning playbook section 5 convention: one branding dir
  per clone color, tools\<appslug>-<color>-branding\, holding tray_icon.ico +
  icon_windows.png (+ source.<ext> provenance copy of the original render).

  Pipeline: corner-sampled background color -> per-pixel background classification
  (Euclidean RGB distance vs -BgTolerance) -> row/column background-fraction profiles
  locate the tile (same LongestLowRun technique as make_ghost_icon.ps1) -> inset crop
  (-EdgeInsetPercent, drops the soft drop-shadow halo) -> high-quality resample to a
  1024 canvas -> optional -HueRotate (degrees; for derived clone colors such as a 4th
  color) -> anti-aliased rounded-corner alpha mask (-CornerRadiusPercent) ->
  PNG-compressed ICO entries for every size in -Sizes (16..256).

  Re-runs without -Source reuse the saved icon_windows.png when its corners are
  transparent (already-masked master) - regeneration never depends on Downloads.
  Feeding one app's saved master with -HueRotate is how a derived color dir is born;
  the source dir's files are never touched.

  Every write is verified by re-reading (never silent-success). Previews over light
  and dark backgrounds land in TEMP and their paths are printed - eyeball them
  before wiring the dir into a shortcuts installer.

  Works on solid-background renders (white, black, gray, colored). -ManualCrop
  "x,y,size" overrides detection for busy backgrounds.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\make_clone_icon.ps1 `
      -Source "C:\Users\me\Downloads\zcode\autoclaw\blue.jpg" `
      -OutDir tools\autoclaw-blue-branding
.EXAMPLE
  # derived 4th color: hue-rotate the blue master ~+150 deg -> red family
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\make_clone_icon.ps1 `
      -Source tools\autoclaw-blue-branding\icon_windows.png `
      -OutDir tools\autoclaw-red-branding -HueRotate 150
#>
param(
    [string]$Source = "",
    [Parameter(Mandatory = $true)]
    [string]$OutDir,
    [int]$MasterSize = 1024,
    [double]$EdgeInsetPercent = 1.5,   # crops into the tile to drop the drop-shadow halo
    [double]$CornerRadiusPercent = 22.0,
    [double]$BgTolerance = 30.0,       # Euclidean RGB distance still counted as background
    [double]$HueRotate = 0,            # degrees added to every colored pixel's hue
    [string]$ManualCrop = "",          # "x,y,size" square tile override, skips detection
    [int[]]$Sizes = @(16, 24, 32, 48, 64, 128, 256)
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------- C# pixel core
$cs = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace CloneIcon
{
    public static class Core
    {
        // Median color of four corner patches (2% of the smaller side). Solid-render
        // backgrounds (white, black, gray, colored) all sample cleanly.
        public static Color SampleBgColor(Bitmap bmp)
        {
            int patch = Math.Max(4, Math.Min(bmp.Width, bmp.Height) * 2 / 100);
            List<int> rs = new List<int>(), gs = new List<int>(), bs = new List<int>();
            int[][] corners = new int[][] {
                new int[] { 0, 0 },
                new int[] { bmp.Width - patch, 0 },
                new int[] { 0, bmp.Height - patch },
                new int[] { bmp.Width - patch, bmp.Height - patch }
            };
            BitmapData d = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height),
                ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
            try
            {
                int stride = d.Stride;
                byte[] px = new byte[stride * bmp.Height];
                Marshal.Copy(d.Scan0, px, 0, px.Length);
                foreach (int[] c in corners)
                {
                    for (int y = 0; y < patch; y++)
                    {
                        int imgY = bmp.Height - 1 - c[1] - y;   // memory rows run bottom-up
                        for (int x = 0; x < patch; x++)
                        {
                            int i = imgY * stride + (c[0] + x) * 3;
                            bs.Add(px[i]); gs.Add(px[i + 1]); rs.Add(px[i + 2]);
                        }
                    }
                }
            }
            finally { bmp.UnlockBits(d); }
            rs.Sort(); gs.Sort(); bs.Sort();
            int m = rs.Count / 2;
            return Color.FromArgb(rs[m], gs[m], bs[m]);
        }

        // Background = Euclidean RGB distance to the sampled color below tolerance.
        // Row/column background-fraction profiles; the tile is the single long run of
        // rows (then columns) whose background fraction is low.
        public static Rectangle DetectTileBounds(Bitmap bmp, Color bg, double tolerance)
        {
            int w = bmp.Width, h = bmp.Height;
            BitmapData d = bmp.LockBits(new Rectangle(0, 0, w, h),
                ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
            int stride = d.Stride;
            byte[] px = new byte[stride * h];
            Marshal.Copy(d.Scan0, px, 0, px.Length);
            bmp.UnlockBits(d);

            double tol2 = tolerance * tolerance;
            int[] rowBg = new int[h];
            int[] colBg = new int[w];
            for (int y = 0; y < h; y++)
            {
                int memRow = y * stride;                 // memory row 0 = bottom image row
                int imgY = h - 1 - y;
                for (int x = 0; x < w; x++)
                {
                    int i = memRow + x * 3;
                    int dr = px[i + 2] - bg.R;
                    int dg = px[i + 1] - bg.G;
                    int db = px[i] - bg.B;
                    if (dr * dr + dg * dg + db * db < tol2)
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
                "no low-background run found (background not solid, or -BgTolerance too tight)");
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

        // Square crop (bounds; inset percent crops further into the tile to drop the
        // drop-shadow halo) + resample to masterSize + anti-aliased rounded-corner
        // alpha mask.
        public static Bitmap MakeMaster(Bitmap src, Rectangle b, double insetPct,
            double radiusPct, int masterSize)
        {
            int inset = (int)(Math.Min(b.Width, b.Height) * insetPct / 100.0);
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

        // Rotate every pixel's hue by degrees (value + saturation preserved, so the
        // tile shading survives). Grays (delta < 2) are skipped - black tiles and
        // white margins are hue-neutral anyway.
        public static void HueRotate(Bitmap bmp, double degrees)
        {
            Rectangle rect = new Rectangle(0, 0, bmp.Width, bmp.Height);
            BitmapData d = bmp.LockBits(rect, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
            int stride = d.Stride;
            byte[] buf = new byte[stride * bmp.Height];
            Marshal.Copy(d.Scan0, buf, 0, buf.Length);
            for (int y = 0; y < bmp.Height; y++)
            {
                int row = y * stride;
                for (int x = 0; x < bmp.Width; x++)
                {
                    int i = row + x * 4;                     // BGRA
                    int r = buf[i + 2], g = buf[i + 1], b = buf[i];
                    int mx = Math.Max(r, Math.Max(g, b)), mn = Math.Min(r, Math.Min(g, b));
                    if (mx - mn < 2) continue;
                    double rf = r / 255.0, gf = g / 255.0, bf = b / 255.0;
                    double max = Math.Max(rf, Math.Max(gf, bf));
                    double min = Math.Min(rf, Math.Min(gf, bf));
                    double delta = max - min;
                    double v = max, s = max <= 0 ? 0 : delta / max;
                    double h;
                    if (max == rf) h = 60.0 * (((gf - bf) / delta) % 6);
                    else if (max == gf) h = 60.0 * (((bf - rf) / delta) + 2);
                    else h = 60.0 * (((rf - gf) / delta) + 4);
                    h += degrees; h %= 360; if (h < 0) h += 360;
                    double c = v * s;
                    double xx = c * (1 - Math.Abs((h / 60.0) % 2 - 1));
                    double m = v - c, rr = 0, gg = 0, bb = 0;
                    if (h < 60) { rr = c; gg = xx; }
                    else if (h < 120) { rr = xx; gg = c; }
                    else if (h < 180) { gg = c; bb = xx; }
                    else if (h < 240) { gg = xx; bb = c; }
                    else if (h < 300) { rr = xx; bb = c; }
                    else { rr = c; bb = xx; }
                    buf[i + 2] = (byte)Math.Round((rr + m) * 255.0);
                    buf[i + 1] = (byte)Math.Round((gg + m) * 255.0);
                    buf[i] = (byte)Math.Round((bb + m) * 255.0);
                }
            }
            Marshal.Copy(buf, 0, d.Scan0, buf.Length);
            bmp.UnlockBits(d);
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

# ------------------------------------------------------------- resolve outputs
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$IcoPath = Join-Path $OutDir 'tray_icon.ico'
$MasterPngPath = Join-Path $OutDir 'icon_windows.png'

if (-not $Source) {
    if (Test-Path -LiteralPath $MasterPngPath) { $Source = $MasterPngPath }
    else { throw "No -Source given and no existing master at $MasterPngPath - pass -Source on first run." }
}
if (-not (Test-Path -LiteralPath $Source)) { throw "Source image not found: $Source" }

$srcBytes = [System.IO.File]::ReadAllBytes($Source)
$srcStream = New-Object System.IO.MemoryStream (, $srcBytes)
$src = [System.Drawing.Bitmap]::FromStream($srcStream)
Write-Host ("[1/5] Loaded source: {0} ({1}x{2})" -f $Source, $src.Width, $src.Height)

# ---------------------------------------------------- master (detect/crop/mask)
$freshMaster = $false
$master = $null
if ($src.Width -eq $src.Height -and [CloneIcon.Core]::HasTransparentCorners($src)) {
    Write-Host '[2/5] Source is already a masked master (transparent corners) - using as-is.'
    $master = $src
}
else {
    if ($ManualCrop) {
        $parts = $ManualCrop.Split(',')
        if ($parts.Length -ne 3) { throw "-ManualCrop must be 'x,y,size' (square tile)" }
        $mx = [int]$parts[0]; $my = [int]$parts[1]; $msz = [int]$parts[2]
        Write-Host ("[2/5] Manual crop: x={0} y={1} size={2}" -f $mx, $my, $msz)
        $bounds = New-Object System.Drawing.Rectangle ($mx), ($my), ($msz), ($msz)
        $master = [CloneIcon.Core]::MakeMaster($src, $bounds, 0.0, $CornerRadiusPercent, $MasterSize)
    }
    else {
        $bg = [CloneIcon.Core]::SampleBgColor($src)
        Write-Host ("[2/5] Background sampled: R={0} G={1} B={2} (tolerance {3})" -f $bg.R, $bg.G, $bg.B, $BgTolerance)
        try {
            $bounds = [CloneIcon.Core]::DetectTileBounds($src, $bg, $BgTolerance)
        } catch {
            throw ("Tile detection failed: {0} - pass -ManualCrop 'x,y,size' or adjust -BgTolerance." -f $_.Exception.Message)
        }
        Write-Host ("      tile bounds: x={0} y={1} w={2} h={3} ({4}% of width)" -f `
            $bounds.X, $bounds.Y, $bounds.Width, $bounds.Height, [int]($bounds.Width * 100.0 / $src.Width))
        $master = [CloneIcon.Core]::MakeMaster($src, $bounds, $EdgeInsetPercent, $CornerRadiusPercent, $MasterSize)
    }
    $freshMaster = $true
}

if ($HueRotate -ne 0) {
    Write-Host ("      hue rotate: +{0} degrees" -f $HueRotate)
    [CloneIcon.Core]::HueRotate($master, $HueRotate)
}

if ($freshMaster -or $HueRotate -ne 0) {
    # save whenever the in-memory master is new OR was recolored, so a derived-color
    # dir becomes self-contained (its own re-runs reuse the derived master)
    $master.Save($MasterPngPath, [System.Drawing.Imaging.ImageFormat]::Png)
    if (-not (Test-Path -LiteralPath $MasterPngPath)) { throw 'FAILED: master PNG was not written' }
    Write-Host ("      [ok] master saved: {0} ({1} KB)" -f $MasterPngPath, ([int]((Get-Item $MasterPngPath).Length / 1KB)))
    if ($freshMaster) {
        # provenance copy of the original render (derived-color runs reuse a master and skip this)
        $provDst = Join-Path $OutDir ("source" + [System.IO.Path]::GetExtension($Source).ToLowerInvariant())
        Copy-Item -LiteralPath $Source -Destination $provDst -Force
        if (-not (Test-Path -LiteralPath $provDst)) { throw "FAILED: provenance copy was not written: $provDst" }
    }
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
if (-not (Test-Path -LiteralPath $IcoPath)) { throw 'FAILED: tray_icon.ico was not written' }
$check = [System.IO.File]::ReadAllBytes($IcoPath)
if ($check.Length -lt 6) { throw 'FAILED: tray_icon.ico is truncated' }
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
$tag = Split-Path -Leaf $OutDir
foreach ($bgName in @('light', 'dark')) {
    $bgColor = $(if ($bgName -eq 'light') { [System.Drawing.Color]::White } else { [System.Drawing.Color]::FromArgb(32, 32, 32) })
    $prev = New-Object System.Drawing.Bitmap (256), (256)
    $g = [System.Drawing.Graphics]::FromImage($prev)
    $g.Clear($bgColor)
    $g.DrawImage($master, 0, 0, 256, 256)
    $g.Dispose()
    $prevPath = Join-Path $env:TEMP ("clone_icon_preview_{0}_{1}_{2}.png" -f $tag, $bgName, $stamp)
    $prev.Save($prevPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $prev.Dispose()
    Write-Host ("      preview ({0}): {1}" -f $bgName, $prevPath)
}

if ($master -ne $src) { $master.Dispose() }
$src.Dispose(); $srcStream.Dispose()
Write-Host 'DONE'
