// Asar surgery — targeted, extract-free asar rebuild shared by the GHOST patch
// engines (ZCode icon-override v9+, OpenCode clone-home v4+).
//
// Why this module exists: the old pipeline ran `npx @electron/asar extract`
// (the ZCode bundle is ~340 MB / ~32k files — a full small-file storm to
// %TEMP%), repacked it up to 4 times in a sidecar-convergence loop, and
// verified with one npx spawn per patched file. Surgery replaces ALL of that
// with one streaming pass:
//
//   1. Parse the asar header (pickle + JSON index).
//   2. Ranged-read ONLY the .js/.cjs/.mjs/.html entries, run the engine's
//      text transforms in memory (~4 files change out of ~22k candidates).
//   3. Rebuild: copy the ENTIRE original payload region byte-for-byte, then
//      APPEND the patched contents at the tail; only the patched entries'
//      offset/size/integrity are rewritten in the header. Untouched bytes are
//      untouched BY CONSTRUCTION — including the archive's deduplicated
//      entries (identical files share one offset; verified live on the ZCode
//      asar: summed entry sizes 366 MB > payload region 333 MB, maxEnd ==
//      payloadBytes), gaps, and unpacked sidecars.
//   4. Verify: header walk (every untouched entry keeps size/offset/integrity),
//      chunked byte-compare of the whole copied payload region, and exact
//      compare of every appended patched content. Stronger than the old
//      extract-file spot checks and free of npx spawn overhead.
//
// Asar disk format (verified against the live ZCode app.asar 2026-11-02):
//   [u32 4][u32 headerBufLen][u32 payloadSize][u32 jsonLen][json bytes][pad]
//   [file data ...]                         ^ payloadBase = 8 + headerBufLen
//   - headerBufLen == 4 + align4(4 + jsonLen); entry offsets are DECIMAL
//     STRINGS relative to payloadBase.
//   - file entry: { size, offset, integrity?: { algorithm: "SHA256", hash,
//     blockSize: 4194304, blocks: [per-block sha256 hex] }, unpacked?: true }
//     hash = sha256 of the whole file content; blocks = sha256 of each 4 MiB
//     chunk. ZCode ships integrity on every entry; the module recomputes it
//     for patched files only and mirrors absence elsewhere.
import { closeSync, openSync, readSync, writeSync, fstatSync, mkdirSync, writeFileSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const COPY_CHUNK = 8 * 1024 * 1024; // 8 MiB streaming copy/compare chunks
const DEFAULT_BLOCK_SIZE = 4194304; // @electron/asar integrity block size

// ---------------------------------------------------------------------------
// Header parse / pickle primitives
// ---------------------------------------------------------------------------

// Parse the pickle header. Throws on any deviation so callers abort BEFORE a
// swap (a corrupt or unknown-format archive must never reach the live asar).
export function parseAsarHeader(asarPath) {
  const fd = openSync(asarPath, "r");
  try {
    const prefix = Buffer.alloc(16);
    if (readSync(fd, prefix, 0, 16, 0) !== 16) {
      throw new Error("asar too small: cannot read 16-byte prefix");
    }
    const magic = prefix.readUInt32LE(0); // pickle payload-size prefix, always 4
    const headerBufLen = prefix.readUInt32LE(4); // header pickle buffer length
    const payloadSize = prefix.readUInt32LE(8); // pickle payload size (len u32 + json + pad)
    const jsonLen = prefix.readUInt32LE(12); // JSON string length
    if (magic !== 4) {
      throw new Error("asar header magic mismatch: u32@0 = " + magic + " (expected 4)");
    }
    const expectedBufLen = 4 + ((4 + jsonLen + 3) & ~3);
    if (headerBufLen !== expectedBufLen || payloadSize !== (4 + jsonLen + 3) & ~3) {
      throw new Error(
        "asar header pickle sizes inconsistent: bufLen=" + headerBufLen +
        " payloadSize=" + payloadSize + " jsonLen=" + jsonLen,
      );
    }
    const headerBuf = Buffer.alloc(headerBufLen);
    if (readSync(fd, headerBuf, 0, headerBufLen, 8) !== headerBufLen) {
      throw new Error("asar header truncated: cannot read " + headerBufLen + " bytes");
    }
    const json = headerBuf.subarray(8, 8 + jsonLen).toString("utf8");
    const header = JSON.parse(json); // throws on malformed header JSON
    const payloadBase = 8 + headerBufLen;
    const fileSize = fstatSync(fd).size;
    return { header, payloadBase, headerBufLen, jsonLen, fileSize };
  } finally {
    closeSync(fd);
  }
}

// Build [u32 4][u32 headerBufLen] + [u32 payloadSize][u32 jsonLen][json][pad].
export function buildHeaderBlock(header) {
  const jsonBuf = Buffer.from(JSON.stringify(header), "utf8");
  const payloadSize = (4 + jsonBuf.length + 3) & ~3;
  const headerBuf = Buffer.alloc(4 + payloadSize); // zero-padded tail included
  headerBuf.writeUInt32LE(payloadSize, 0);
  headerBuf.writeUInt32LE(jsonBuf.length, 4);
  jsonBuf.copy(headerBuf, 8);
  const sizeBuf = Buffer.alloc(8);
  sizeBuf.writeUInt32LE(4, 0);
  sizeBuf.writeUInt32LE(headerBuf.length, 4);
  return { sizeBuf, headerBuf, payloadBase: 8 + headerBuf.length };
}

// ---------------------------------------------------------------------------
// Tree walking / ranged entry reads
// ---------------------------------------------------------------------------

// Walk a header tree, invoking visit(relPath, entryNode, isDir). Relpaths use
// forward slashes (the asar index convention).
export function walkHeader(header, visit) {
  (function walk(node, prefix) {
    if (!node.files) return;
    for (const [name, entry] of Object.entries(node.files)) {
      const rel = prefix ? prefix + "/" + name : name;
      if (entry.files) {
        visit(rel, entry, true);
        walk(entry, rel);
      } else {
        visit(rel, entry, false);
      }
    }
  })(header, "");
}

// Collect transform candidates: text-source entries that actually carry a
// payload in the archive (skips unpacked sidecar files and link entries).
export function listSourceEntries(header) {
  const out = [];
  walkHeader(header, (rel, entry, isDir) => {
    if (isDir || entry.files) return;
    if (entry.unpacked || entry.link || entry.offset === undefined) return;
    if (/\.(js|cjs|mjs|html)$/.test(rel)) out.push({ rel, node: entry });
  });
  return out;
}

// Ranged entry read (positional read on an open fd; no full-file read).
export function readEntryBytes(fd, payloadBase, entry) {
  const off = payloadBase + Number(entry.offset);
  const size = entry.size ?? 0;
  const buf = Buffer.alloc(size);
  let read = 0;
  while (read < size) {
    const n = readSync(fd, buf, read, size - read, off + read);
    if (n <= 0) throw new Error("short read in entry payload at offset " + entry.offset);
    read += n;
  }
  return buf;
}

// Mirror @electron/asar integrity: whole-file sha256 + per-block digests.
export function computeIntegrity(buf, blockSize = DEFAULT_BLOCK_SIZE, algorithm = "SHA256") {
  if (algorithm !== "SHA256") {
    throw new Error("unsupported integrity algorithm: " + algorithm);
  }
  const blocks = [];
  for (let i = 0; i < buf.length; i += blockSize) {
    blocks.push(createHash("sha256").update(buf.subarray(i, Math.min(i + blockSize, buf.length))).digest("hex"));
  }
  return {
    algorithm,
    hash: createHash("sha256").update(buf).digest("hex"),
    blockSize,
    blocks,
  };
}

// ---------------------------------------------------------------------------
// Rebuild (surgery) + verify
// ---------------------------------------------------------------------------

// transform(relPath, utf8Content) must return the new utf8 string, or null /
// undefined to leave the entry untouched. Returns rebuild metadata; the
// candidate asar is fully written before this returns.
export function rebuildAsar({ sourcePath, outPath, transform }) {
  const src = parseAsarHeader(sourcePath);
  const srcFd = openSync(sourcePath, "r");
  try {
    // 1. Read + transform candidate entries in memory.
    const patched = []; // { rel, node, newBuf, oldSize }
    for (const { rel, node } of listSourceEntries(src.header)) {
      const before = readEntryBytes(srcFd, src.payloadBase, node);
      const after = transform(rel, before.toString("utf8"));
      if (after == null || after === before.toString("utf8")) continue;
      const newBuf = Buffer.from(after, "utf8");
      patched.push({ rel, node, newBuf, oldSize: node.size });
    }

    // 2. Rewrite only patched entries; append payload at the tail.
    //    Tail offsets are relative to the NEW payloadBase, so they start at
    //    the ORIGINAL payload-region length (the whole region is copied
    //    contiguously and untouched entries keep their relative offsets).
    const regionLen = src.fileSize - src.payloadBase;
    let tail = 0;
    for (const p of patched) {
      p.node.offset = String(regionLen + tail);
      p.node.size = p.newBuf.length;
      const prev = p.node.integrity;
      if (prev) {
        p.node.integrity = computeIntegrity(p.newBuf, prev.blockSize, prev.algorithm);
      } // no integrity in source entry -> mirror absence
      tail += p.newBuf.length;
    }

    const { sizeBuf, headerBuf, payloadBase: newPayloadBase } = buildHeaderBlock(src.header);
    const outFd = openSync(outPath, "w");
    try {
      writeSync(outFd, sizeBuf);
      writeSync(outFd, headerBuf);
      // 3. Copy the untouched payload region byte-for-byte.
      let pos = src.payloadBase;
      const chunk = Buffer.alloc(COPY_CHUNK);
      while (pos < src.fileSize) {
        const n = readSync(srcFd, chunk, 0, Math.min(COPY_CHUNK, src.fileSize - pos), pos);
        if (n <= 0) throw new Error("short read copying payload region at " + pos);
        writeSync(outFd, chunk, 0, n);
        pos += n;
      }
      // 4. Append patched contents in tail order.
      for (const p of patched) writeSync(outFd, p.newBuf);
    } finally {
      closeSync(outFd);
    }
    return {
      patched: patched.map((p) => ({ rel: p.rel, oldSize: p.oldSize, newSize: p.newBuf.length })),
      origPayloadBase: src.payloadBase,
      newPayloadBase,
      regionLen,
      tailLen: tail,
      outSize: newPayloadBase + regionLen + tail,
      srcFileSize: src.fileSize,
    };
  } finally {
    closeSync(srcFd);
  }
}

// Full verification of a rebuilt asar against its source:
//   - header walk: identical entry sets; untouched entries keep size, offset
//     and integrity verbatim; patched entries point into the tail.
//   - the copied payload region must be byte-identical to the source region.
//   - every patched entry's candidate bytes must equal the expected content.
// expected: Map<relPath, Buffer> of patched contents (from the rebuild step).
export function verifyRebuild({ sourcePath, outPath, expected, meta }) {
  const errors = [];
  const src = parseAsarHeader(sourcePath);
  const cand = parseAsarHeader(outPath);

  // Structural: walk both trees in lockstep.
  const srcFiles = new Map();
  walkHeader(src.header, (rel, e, isDir) => { if (!isDir) srcFiles.set(rel, e); });
  const candFiles = new Map();
  walkHeader(cand.header, (rel, e, isDir) => { if (!isDir) candFiles.set(rel, e); });
  if (srcFiles.size !== candFiles.size) {
    errors.push("entry count mismatch: source " + srcFiles.size + " vs candidate " + candFiles.size);
  }
  let checked = 0;
  for (const [rel, se] of srcFiles) {
    const ce = candFiles.get(rel);
    if (!ce) { errors.push("missing entry in candidate: " + rel); continue; }
    if (expected.has(rel)) {
      const exp = expected.get(rel);
      if (ce.size !== exp.length) {
        errors.push("patched size mismatch in " + rel + ": " + ce.size + " != " + exp.length);
        continue;
      }
      if (!/^\d+$/.test(String(ce.offset)) || Number(ce.offset) < meta.regionLen) {
        errors.push("patched offset not in tail region for " + rel + ": " + ce.offset);
        continue;
      }
      checked++;
    } else {
      if (se.size !== ce.size || se.offset !== ce.offset) {
        errors.push("untouched entry drifted: " + rel);
        continue;
      }
      if (JSON.stringify(se.integrity ?? null) !== JSON.stringify(ce.integrity ?? null)) {
        errors.push("untouched integrity drifted: " + rel);
        continue;
      }
      checked++;
    }
  }

  // Region byte-compare: source payload region vs candidate copied region.
  const srcFd = openSync(sourcePath, "r");
  const candFd = openSync(outPath, "r");
  try {
    const a = Buffer.alloc(COPY_CHUNK);
    const b = Buffer.alloc(COPY_CHUNK);
    let mismatches = 0;
    for (let off = 0; off < meta.regionLen; off += COPY_CHUNK) {
      const len = Math.min(COPY_CHUNK, meta.regionLen - off);
      readSync(srcFd, a, 0, len, src.payloadBase + off);
      readSync(candFd, b, 0, len, cand.payloadBase + off);
      if (Buffer.compare(a.subarray(0, len), b.subarray(0, len)) !== 0) {
        // locate first differing byte for the error message, then stop early
        for (let i = 0; i < len; i++) {
          if (a[i] !== b[i]) {
            errors.push("payload region differs at +" + (off + i));
            mismatches++;
            break;
          }
        }
        if (mismatches >= 3) break;
      }
    }
    // Tail: every patched entry's bytes must equal expected exactly.
    for (const [rel, exp] of expected) {
      const ce = candFiles.get(rel);
      if (!ce) continue; // already reported above
      const buf = Buffer.alloc(exp.length);
      readSync(candFd, buf, 0, exp.length, cand.payloadBase + Number(ce.offset));
      if (Buffer.compare(buf, exp) !== 0) errors.push("tail content mismatch for " + rel);
    }
    if (fstatSync(candFd).size !== meta.outSize) {
      errors.push("candidate size " + fstatSync(candFd).size + " != expected " + meta.outSize);
    }
  } finally {
    closeSync(srcFd);
    closeSync(candFd);
  }
  return { ok: errors.length === 0, checked, errors };
}

// ---------------------------------------------------------------------------
// Self-test (used by tests/patch_surgery.Tests.ps1): build a synthetic asar,
// run a rebuild that patches two entries (one of which shares its offset with
// a deduplicated twin), verify, and exercise the corrupt-header abort.
//   node asar_surgery.mjs --selftest <workDir>
// Prints a JSON verdict; exit 0 = pass, 1 = fail.
// ---------------------------------------------------------------------------
function selftest(workDir) {
  const checks = {};
  const verdict = (ok, extra) => {
    console.log(JSON.stringify({ ok, checks, ...extra }));
    process.exit(ok ? 0 : 1);
  };
  try {
    if (!existsSync(workDir)) mkdirSync(workDir, { recursive: true });
    const srcAsar = join(workDir, "src.asar");
    const outAsar = join(workDir, "out.asar");

    // --- build a synthetic source asar ---
    const big = Buffer.alloc(6 * 1024 * 1024); // spans 2 integrity blocks
    for (let i = 0; i < big.length; i += 4096) big[i] = 0xAB;
    const dupContent = "const shared = 1;\n".repeat(1000);
    const files = [
      { rel: "a.js", content: Buffer.from("const hello='world';\n".repeat(500), "utf8") },
      { rel: "dir/nested/b.cjs", content: Buffer.from("module.exports=42;\n", "utf8") },
      { rel: "bin.dat", content: big },
      { rel: "empty.txt", content: Buffer.alloc(0) },
      { rel: "dup1.js", content: Buffer.from(dupContent, "utf8") },
      { rel: "dup2.js", content: Buffer.from(dupContent, "utf8"), sharedWith: "dup1.js" }, // dedup twin
      { rel: "up.native", unpacked: true, content: Buffer.from("native-bytes", "utf8") },
    ];
    const root = { files: {} };
    const nodeFor = (rel) => {
      const parts = rel.split("/");
      let node = root;
      for (let i = 0; i < parts.length - 1; i++) {
        node = node.files[parts[i]] ??= { files: {} };
      }
      return node;
    };
    let off = 0;
    const writtenDup = new Map();
    for (const f of files) {
      const parent = nodeFor(f.rel);
      if (f.unpacked) {
        parent.files[f.rel.split("/").pop()] = { size: f.content.length, unpacked: true };
        continue;
      }
      const entry = { size: f.content.length, integrity: computeIntegrity(f.content) };
      if (f.sharedWith && writtenDup.has(f.sharedWith)) {
        entry.offset = writtenDup.get(f.sharedWith); // dedup: shared offset, payload written once
      } else {
        entry.offset = String(off);
        writtenDup.set(f.rel, String(off));
        off += f.content.length;
      }
      parent.files[f.rel.split("/").pop()] = entry;
    }
    const { sizeBuf, headerBuf } = buildHeaderBlock(root);
    const fd = openSync(srcAsar, "w");
    try {
      writeSync(fd, sizeBuf);
      writeSync(fd, headerBuf);
      for (const f of files) {
        if (f.unpacked || f.sharedWith) continue;
        writeSync(fd, f.content);
      }
    } finally {
      closeSync(fd);
    }
    const unpackedDir = srcAsar + ".unpacked";
    mkdirSync(unpackedDir, { recursive: true });
    for (const f of files) {
      if (f.unpacked) writeFileSync(join(unpackedDir, f.rel.split("/").pop()), f.content);
    }
    checks.builtSource = existsSync(srcAsar);

    // --- rebuild: patch a.js and dup1.js (dup1 shares its offset with dup2) ---
    const expected = new Map();
    const meta = rebuildAsar({
      sourcePath: srcAsar,
      outPath: outAsar,
      transform: (rel, content) => {
        if (rel === "a.js") return content.replace("const hello='world';", "const hello='GHOST';");
        if (rel === "dup1.js") return content + "// patched tail\n";
        return null;
      },
    });
    for (const p of meta.patched) {
      // recompute expected content the same way the engine would
      // (String.replace only swaps the FIRST occurrence)
      if (p.rel === "a.js") {
        expected.set(p.rel, Buffer.from("const hello='GHOST';\n" + "const hello='world';\n".repeat(499), "utf8"));
      }
      if (p.rel === "dup1.js") expected.set(p.rel, Buffer.from(dupContent + "// patched tail\n", "utf8"));
    }
    checks.patchedCount = meta.patched.length;
    checks.patchedRels = meta.patched.map((p) => p.rel).sort();

    // --- verify ---
    const v = verifyRebuild({ sourcePath: srcAsar, outPath: outAsar, expected, meta });
    checks.verifyChecked = v.checked;
    checks.verifyErrors = v.errors;
    if (!v.ok) verdict(false, { error: "verifyRebuild failed: " + v.errors.join("; ") });
    if (meta.patched.length !== 2) verdict(false, { error: "expected 2 patched entries" });
    const cand = parseAsarHeader(outAsar);
    const dup2 = (function find(node, parts) {
      if (!node.files) return null;
      const [head, ...rest] = parts;
      const next = node.files[head];
      if (!next) return null;
      return rest.length ? find(next, rest) : next;
    })(cand.header, ["dup2.js"]);
    const dup1 = (function find(node, parts) {
      if (!node.files) return null;
      const [head, ...rest] = parts;
      const next = node.files[head];
      if (!next) return null;
      return rest.length ? find(next, rest) : next;
    })(cand.header, ["dup1.js"]);
    checks.dup2KeptOldOffset = dup2 && dup1 && Number(dup2.offset) < meta.regionLen;

    // --- negative: corrupt header must abort ---
    let threw = false;
    try {
      const bytes = readFileSyncBytes(srcAsar);
      bytes[40] ^= 0xFF;
      const bad = join(workDir, "bad.asar");
      writeFileSync(bad, bytes);
      parseAsarHeader(bad);
    } catch {
      threw = true;
    }
    checks.corruptHeaderAborts = threw;

    const allOk = checks.builtSource && checks.patchedCount === 2 &&
      checks.dup2KeptOldOffset && checks.corruptHeaderAborts && checks.verifyErrors.length === 0;
    verdict(allOk, allOk ? {} : { error: "selftest checks failed: " + JSON.stringify(checks) });
  } catch (e) {
    verdict(false, { error: String((e && e.stack) || e) });
  }
}

function readFileSyncBytes(path) {
  const fd = openSync(path, "r");
  try {
    const buf = Buffer.alloc(fstatSync(fd).size);
    readSync(fd, buf, 0, buf.length, 0);
    return buf;
  } finally {
    closeSync(fd);
  }
}

// --- CLI entry: --selftest <dir> (internal; engines import the functions) ---
if (process.argv[1] && process.argv[2] === "--selftest" &&
    pathToFileURL(process.argv[1]).href === import.meta.url) {
  const dir = process.argv[3];
  if (!dir) {
    console.error("usage: node asar_surgery.mjs --selftest <workDir>");
    process.exit(1);
  }
  selftest(dir);
}
