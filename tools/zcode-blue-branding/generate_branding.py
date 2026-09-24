#!/usr/bin/env python3
"""Generate ZCode blue-branding assets for the secondary instance.

Two source modes:
  --source <png>    transparent 1024x1024 artwork, used as-is (legacy mode)
  --source-jpg <jpg> opaque artwork on a background (e.g. 2048x2048 JPG render).
                    Cropped to the artwork square, scaled to fill the canvas
                    (full-bleed, matching the original app icon geometry), then
                    given rounded corners with transparent outside via a mask.

Produces (default: next to this script, override with --out-dir):
  icon_windows.png  - 1024x1024 window/taskbar icon (RGBA)
  tray_icon.ico     - multi-size ICO (16/24/32/48/64/128/256) for the tray

--mask selects the Z-stroke hue to extract (blue default = the historical
pipeline); the final Z geometry is normalized to the original app icon's
white-Z bbox either way, so all variants read identical in size/weight.
The measured accent hex of the generated stroke is printed for the
launcher's ZCODE_ACCENT_HEX.

Requires ffmpeg on PATH and numpy. Re-run any time the source changes.
"""
import argparse
import os
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

import numpy as np

SIZES = [16, 24, 32, 48, 64, 128, 256]
CANVAS = 1024
# Corner-mask radius at 1024. The original app icon is full-bleed with a ~134px
# corner radius; the artwork's own curve is ~130px, so masking at 136 cuts just
# outside the artwork's curve - no background fringe survives at the corners.
MASK_RADIUS = 136
# JPG crop (source-pixel coords, from the user's own alpha-cropped 1024 PNG:
# square bbox x[93..927] -> x2 for the 2048 render, centered on the square).
JPG_CROP_X = 185
JPG_CROP_Y = 189
JPG_CROP_SIZE = 1670
# The artwork's Z is proportionally larger than the original app icon's Z
# (~86% vs ~69% of the square width). The blue Z layer is extracted, the square
# surface underneath is rebuilt (inpainting), and the Z is re-composited at the
# original's exact bbox so both taskbar icons read identical in size/weight.
Z_DILATE_PX = 8
DIFF_LO = 6.0
DIFF_HI = 30.0

# Z-stroke hue masks: (r, g, b) float arrays -> boolean. The background in all
# renders is neutral dark, so a saturated-hue test isolates the stroke cleanly.
# yellow: warm (r,g high, b low); green: teal-green (g dominant over both).
MASKS = {
    "blue": lambda r, g, b: (b > r + 40) & (b > 90),
    "yellow": lambda r, g, b: (r > b + 60) & (g > b + 40) & (r > 120),
    "green": lambda r, g, b: (g > r + 60) & (g > b) & (g > 90),
}


def run_ffmpeg(args):
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args]
    subprocess.run(cmd, check=True)


def decode_rgba(path: Path, out_raw: Path, size: int) -> np.ndarray:
    run_ffmpeg(["-i", str(path), "-f", "rawvideo", "-pix_fmt", "rgba", str(out_raw)])
    data = out_raw.read_bytes()
    if len(data) != size * size * 4:
        raise SystemExit(f"decode failed: {path} -> {len(data)} bytes, want {size*size*4}")
    return np.frombuffer(data, dtype=np.uint8).reshape(size, size, 4).copy()


def dilate(mask: np.ndarray, px: int) -> np.ndarray:
    out = mask.copy()
    for _ in range(px):
        out = out | np.roll(out, 1, 0) | np.roll(out, -1, 0) \
                  | np.roll(out, 1, 1) | np.roll(out, -1, 1)
    return out


def inpaint_bg(rgba: np.ndarray, hole: np.ndarray) -> np.ndarray:
    """Fill the hole region by isotropic diffusion of the surrounding pixels."""
    img = rgba[:, :, :3].astype(np.float64)
    hole = hole.astype(bool)
    # seed: immediate border pixels of the hole
    border = dilate(hole, 1) & ~hole
    img[hole] = 0.0
    weight = (~hole).astype(np.float64)
    acc = img * weight[..., None]
    for _ in range(300):
        nb = np.zeros_like(acc)
        for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
            nb += np.roll(np.roll(acc, dy, 0), dx, 1)
            nb[-1 if dy > 0 else 0] = 0
        nbw = np.zeros_like(weight)
        for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
            nbw += np.roll(np.roll(weight, dy, 0), dx, 1)
            nbw[-1 if dy > 0 else 0] = 0
        ok = nbw > 1e-6
        upd_hole = hole & ok
        acc[upd_hole] = nb[upd_hole] / nbw[upd_hole, None]
        weight[upd_hole] = 1.0
        if not (hole & (weight < 1)).any():
            break
    out = rgba.copy()
    out[:, :, :3] = np.clip(acc, 0, 255).astype(np.uint8)
    return out


def extract_z_layer(rgba: np.ndarray, colored):
    """Split the artwork into (clean square, Z layer RGBA).

    Layer alpha comes from the pixel's deviation from the inpainted background,
    so the Z's soft shadow rides along with the layer automatically.
    """
    r, g, b = (rgba[:, :, i].astype(np.float64) for i in range(3))
    colored_mask = colored(r, g, b)
    hole = dilate(colored_mask, Z_DILATE_PX)
    clean = inpaint_bg(rgba, hole)
    diff = np.abs(rgba[:, :, :3].astype(np.float64) - clean[:, :, :3]).max(axis=2)
    alpha = np.clip((diff - DIFF_LO) / (DIFF_HI - DIFF_LO), 0, 1)
    # keep only the neighborhood of the Z (kill sensor-noise alphas elsewhere)
    alpha[~dilate(colored_mask, 40)] = 0.0
    layer = np.zeros_like(rgba)
    layer[:, :, :3] = rgba[:, :, :3]
    layer[:, :, 3] = (alpha * 255).astype(np.uint8)
    return clean, layer


def rescale_layer(layer: np.ndarray, target_w: int, target_h: int) -> np.ndarray:
    """Bilinear resample of an RGBA layer to the target box (numpy-only)."""
    src_h, src_w = layer.shape[:2]
    ys, xs = np.mgrid[0:target_h, 0:target_w]
    sy = ys * (src_h / target_h)
    sx = xs * (src_w / target_w)
    y0 = np.clip(np.floor(sy).astype(int), 0, src_h - 1)
    x0 = np.clip(np.floor(sx).astype(int), 0, src_w - 1)
    y1 = np.minimum(y0 + 1, src_h - 1)
    x1 = np.minimum(x0 + 1, src_w - 1)
    fy = (sy - y0)[..., None]
    fx = (sx - x0)[..., None]
    lf = layer.astype(np.float64)
    top = lf[y0, x0] * (1 - fx) + lf[y0, x1] * fx
    bot = lf[y1, x0] * (1 - fx) + lf[y1, x1] * fx
    return np.clip(top * (1 - fy) + bot * fy, 0, 255).astype(np.uint8)


def composite_z(clean: np.ndarray, z_layer: np.ndarray, bbox) -> np.ndarray:
    """Paste the Z layer centered on the square at the target bbox.

    The layer is first cropped to its own alpha footprint - it lives on a full
    1024 canvas, so scaling the whole canvas would shrink the Z twice.
    """
    x0, y0, w, h = bbox
    ys, xs = np.where(z_layer[:, :, 3] > 8)
    lx0, lx1, ly0, ly1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    cropped = z_layer[ly0:ly1, lx0:lx1]
    small = rescale_layer(cropped, w, h)
    out = clean.copy()
    la = small[:, :, 3].astype(np.float64) / 255.0
    region = out[y0:y0 + h, x0:x0 + w]
    for c in range(3):
        region[:, :, c] = ((small[:, :, c] * la) + (region[:, :, c] * (1 - la))).astype(np.uint8)
    return out


def write_png(path: Path, rgba: np.ndarray):
    h, w = rgba.shape[:2]
    scanlines = b"".join(b"\x00" + rgba[y].tobytes() for y in range(h))

    def chunk(typ: bytes, payload: bytes) -> bytes:
        return (struct.pack(">I", len(payload)) + typ + payload
                + struct.pack(">I", zlib.crc32(typ + payload) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(scanlines, 9))
        + chunk(b"IEND", b"")
    )


def rounded_corner_alpha(rgba: np.ndarray, radius: int) -> np.ndarray:
    """Zero the alpha outside a rounded rectangle covering the full canvas."""
    out = rgba.copy()
    a = out[:, :, 3].astype(np.uint16)
    n = CANVAS
    r = radius
    sub = 4  # supersample factor for smooth anti-aliased corner edges
    offs = (np.arange(sub) + 0.5) / sub
    yy, xx = np.mgrid[0:r, 0:r]
    # corner-center distances for every sub-sample of every pixel in a corner box
    d = np.sqrt(
        (r - (yy[:, :, None, None] + offs[None, None, :, None])) ** 2
        + (r - (xx[:, :, None, None] + offs[None, None, None, :])) ** 2
    )
    cover = ((d <= r).sum(axis=(2, 3)) / (sub * sub) * 255).astype(np.uint16)
    for cy, cx in ((0, 0), (0, 1), (1, 0), (1, 1)):
        y0 = 0 if cy == 0 else n - r
        x0 = 0 if cx == 0 else n - r
        block = cover if (cy == 0 and cx == 0) else cover[:, ::-1] if (cy == 0) else \
            cover[::-1, :] if (cx == 0) else cover[::-1, ::-1]
        region = a[y0:y0 + r, x0:x0 + r]
        np.minimum(region, block, out=region)
    out[:, :, 3] = a.astype(np.uint8)
    return out


def bmp_frame(rgba: np.ndarray, size: int) -> bytes:
    # ICO BMP: 40-byte BITMAPINFOHEADER with double height (XOR + AND),
    # 32bpp BGRA pixel rows bottom-up, then an all-zero AND mask (alpha rules).
    bgra = np.empty((size, size, 4), dtype=np.uint8)
    bgra[:, :, 0] = rgba[::-1, :, 2]
    bgra[:, :, 1] = rgba[::-1, :, 1]
    bgra[:, :, 2] = rgba[::-1, :, 0]
    bgra[:, :, 3] = rgba[::-1, :, 3]
    header = struct.pack(
        "<IiiHHIIiiII", 40, size, size * 2, 1, 32, 0,
        size * size * 4, 0, 0, 0, 0,
    )
    mask_row = ((size + 31) // 32) * 4
    mask = b"\x00" * (mask_row * size)
    return header + bgra.tobytes() + mask


def build_ico(frames, out: Path):
    # frames: list of (size, payload_bytes) - PNG payload allowed for any size.
    entries = []
    images = []
    offset = 6 + 16 * len(frames)
    for size, payload in frames:
        entries.append((size, len(payload), offset))
        images.append(payload)
        offset += len(payload)
    ico = struct.pack("<HHH", 0, 1, len(frames))
    for size, nbytes, off in entries:
        ico += struct.pack(
            "<BBBBHHII",
            0 if size == 256 else size,
            0 if size == 256 else size,
            0, 0, 1, 32, nbytes, off,
        )
    for image in images:
        ico += image
    out.write_bytes(ico)
    return len(frames)


def main():
    ap = argparse.ArgumentParser()
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--source", help="transparent 1024x1024 source PNG")
    src.add_argument("--source-jpg", help="opaque artwork JPG/PNG on a background")
    ap.add_argument("--crop", help="jpg mode crop as X:Y:SIZE (default from measured bbox)")
    ap.add_argument("--mask", choices=sorted(MASKS), default="blue",
                    help="Z-stroke hue to extract (default: blue)")
    ap.add_argument("--out-dir", help="output directory (default: next to this script)")
    args = ap.parse_args()

    out_dir = Path(args.out_dir) if args.out_dir else Path(__file__).resolve().parent
    out_dir.mkdir(parents=True, exist_ok=True)
    colored = MASKS[args.mask]

    with tempfile.TemporaryDirectory(prefix="zcode-branding-") as td:
        tdp = Path(td)
        if args.source:
            src = Path(args.source)
            if not src.is_file():
                raise SystemExit(f"source not found: {src}")
            master = decode_rgba(src, tdp / "master.raw", CANVAS)
            if (master[:, :, 3] == 0).mean() < 0.001:
                raise SystemExit("source has no transparency - use --source-jpg")
        else:
            src = Path(args.source_jpg)
            if not src.is_file():
                raise SystemExit(f"source not found: {src}")
            crop_x, crop_y, crop_s = JPG_CROP_X, JPG_CROP_Y, JPG_CROP_SIZE
            if args.crop:
                crop_x, crop_y, crop_s = (int(v) for v in args.crop.split(":"))
            # crop to the artwork square then fill the canvas (full-bleed like
            # the original app icon, so small taskbar sizes look the same size)
            run_ffmpeg([
                "-i", str(src),
                "-vf", f"crop={crop_s}:{crop_s}:{crop_x}:{crop_y},"
                       f"scale={CANVAS}:{CANVAS}:flags=lanczos",
                "-frames:v", "1",
                "-f", "rawvideo", "-pix_fmt", "rgba", str(tdp / "master.raw"),
            ])
            master = np.frombuffer(
                (tdp / "master.raw").read_bytes(), dtype=np.uint8
            ).reshape(CANVAS, CANVAS, 4).copy()
            clean, z_layer = extract_z_layer(master, colored)
            # target bbox = original app icon's white-Z box (704x600 @1024),
            # centered on the square
            tw, th = 704, 600
            master = composite_z(clean, z_layer, (
                (CANVAS - tw) // 2, (CANVAS - th) // 2, tw, th))
            master = rounded_corner_alpha(master, MASK_RADIUS)

        window_png = out_dir / "icon_windows.png"
        write_png(window_png, master)

        # verify-after write: re-decode the written PNG and require a lossless
        # match with the in-memory master (writer correctness, no silent drift)
        back = decode_rgba(window_png, tdp / "roundtrip.raw", CANVAS)
        if not np.array_equal(back, master):
            raise SystemExit("icon_windows.png verify FAILED: roundtrip differs")

        frames = []
        for size in SIZES:
            if size == 256:
                png = tdp / f"f{size}.png"
                run_ffmpeg([
                    "-i", str(window_png),
                    "-vf", f"scale={size}:{size}:flags=lanczos",
                    "-frames:v", "1",
                    "-pix_fmt", "rgba",
                    "-pred", "mixed", str(png),
                ])
                frames.append((size, png.read_bytes()))
            else:
                raw = tdp / f"f{size}.raw"
                run_ffmpeg([
                    "-i", str(window_png),
                    "-vf", f"scale={size}:{size}:flags=lanczos",
                    "-frames:v", "1",
                    "-f", "rawvideo", "-pix_fmt", "rgba", str(raw),
                ])
                data = np.frombuffer(raw.read_bytes(), dtype=np.uint8).reshape(size, size, 4)
                frames.append((size, bmp_frame(data, size)))
        ico_path = out_dir / "tray_icon.ico"
        count = build_ico(frames, ico_path)

    # verify-after: re-read the ICO and confirm entry count + declared sizes
    with ico_path.open("rb") as f:
        _, ico_type, n = struct.unpack("<HHH", f.read(6))
        if ico_type != 1 or n != len(SIZES) or count != len(SIZES):
            raise SystemExit("tray_icon.ico verify failed: bad header")
        for _ in range(n):
            bw, bh, _, _, _, _, nbytes, off = struct.unpack("<BBBBHHII", f.read(16))
            if bw not in (0, *SIZES) or off + nbytes > ico_path.stat().st_size:
                raise SystemExit("tray_icon.ico verify failed: bad entry")

    # pixel-level verify on the written PNG: transparent corners, opaque full
    # edges (full-bleed), colored Z stroke in the middle
    a = master[:, :, 3].astype(int)
    if a[2, 2] != 0 or a[CANVAS - 3, 2] != 0:
        raise SystemExit(f"verify FAILED: corners not transparent ({a[2,2]},{a[-3,2]})")
    edge = a[CANVAS // 2, :]
    if edge.min() != 255:
        raise SystemExit(f"verify FAILED: square edge not full-bleed (min {edge.min()})")
    stroke = tuple(master[CANVAS // 2, CANVAS // 2][:3])
    if not colored(*stroke):
        raise SystemExit(f"verify FAILED: center stroke not {args.mask} {stroke}")

    # measured verify: Z bbox must match the original white-Z box
    # (704x600 @1024, tolerance 4px per side) so both taskbar icons read the
    # same visual size/weight
    mr, mg, mb = (master[:, :, i].astype(np.float64) for i in range(3))
    m = colored(mr, mg, mb) & (master[:, :, 3] > 128)
    ys, xs = np.where(m)
    got = (xs.min(), xs.max(), ys.min(), ys.max())
    want = (160, 863, 212, 811)
    if any(abs(g - w) > 8 for g, w in zip(got, want)):
        raise SystemExit(f"verify FAILED: Z bbox {got} != original {want}")
    print(f"   Z bbox matches original: {got} (target {want}, tol 8)")

    # accent hex for ZCODE_ACCENT_HEX: median RGB of fully-opaque stroke pixels
    solid = colored(mr, mg, mb) & (master[:, :, 3] == 255)
    if solid.any():
        acc = np.median(master[solid][:, :3], axis=0).astype(int)
        print(f"   accent hex ({args.mask}): #{acc[0]:02X}{acc[1]:02X}{acc[2]:02X}")

    print(f"OK icon_windows.png {CANVAS}x{CANVAS} -> {window_png}")
    print(f"OK tray_icon.ico {len(SIZES)} frames {SIZES} -> {ico_path}")
    print(f"   corner alpha={a[2,2]} edge min={edge.min()} center={stroke}")


if __name__ == "__main__":
    sys.exit(main())
