// patch_zcode_business_exchange.mjs - GHOST business-exchange hardening patch
// for the ZCode desktop bundle (out/host/index.js), built on the shared
// tools/asar_surgery.mjs surgery layer.
//
// WHY (2026-11-11, live-verified): ZaiBusinessTokenResolver.exchangeBusinessToken
// posts the OAuth token to https://api.z.ai/api/auth/z/login with a HARD 10s
// timeout (minified `zLe=1e4`) and NO retry. Live incidents:
//   - Orange 15:58:15 - the delivered callback reached the clone, the
//     zcode.z.ai code exchange SUCCEEDED, and the business call died at
//     10.14s with "fetch failed" (= the 10s timeout) -> zai_oauth_required.
//   - Yellow 13:14/14:29 - the same call failed in ~800ms (server error
//     envelope); a later attempt at 15:24 succeeded -> the failure is
//     transient/flaky, so a retry is the correct client-side mitigation.
//
// PATCH (entry out/host/index.js only, everything else untouched):
//   1. `zLe=1e4`               -> `zLe=6e4`   (10s -> 60s, byte-length neutral)
//   2. resolve() tail spliced with a one-shot retry after a 3s backoff:
//      (this.cachedToken=null,this.exchangeBusinessToken(n))
//      -> (...exchangeBusinessToken(n).catch(async o=>{await new
//         Promise(s=>setTimeout(s,3e3));return this.exchangeBusinessToken(n)}))
//      Covers BOTH failure modes (timeout and transient server envelope).
//
// Markers/backup: resources\zcode-business-exchange.marker.json +
// ID_Backups\<ts>\ (full app.asar + pristine out/host/index.js entry).
// After an APP UPDATE the asar is replaced wholesale -> re-run this tool
// (patch_zcode_business_exchange.ps1 -Status reports "pristine (needs patch)").
// Coexists with the icon-override patch: that engine touches
// out/main/index.js / out/preload/index.cjs / renderer assets only.
import { rebuildAsar, verifyRebuild, parseAsarHeader, readEntryBytes } from "./asar_surgery.mjs";
import { writeFileSync, readFileSync, existsSync, unlinkSync, openSync, closeSync } from "node:fs";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";

const ENTRY_REL = "out/host/index.js";
const TIMEOUT_OLD = "zLe=1e4";
const TIMEOUT_NEW = "zLe=6e4";
const RETRY_OLD = "(this.cachedToken=null,this.exchangeBusinessToken(n))";
const RETRY_NEW =
  "(this.cachedToken=null,this.exchangeBusinessToken(n).catch(async o=>{await new Promise(s=>setTimeout(s,3e3));return this.exchangeBusinessToken(n)}))";
const RETRY_PROBE = "return this.exchangeBusinessToken(n)}))";

function sha256(buf) { return createHash("sha256").update(buf).digest("hex"); }

function countOf(text, needle) {
  let n = 0, i = -1;
  while ((i = text.indexOf(needle, i + 1)) !== -1) n++;
  return n;
}

function readEntry(asarPath) {
  const src = parseAsarHeader(asarPath);
  const fdOpen = openSync(asarPath, "r");
  try {
    const entry = src.header.files["out"].files["host"].files["index.js"];
    const buf = readEntryBytes(fdOpen, src.payloadBase, entry);
    return { entry, buf };
  } finally {
    closeSync(fdOpen);
  }
}

function transform(rel, content) {
  if (rel !== ENTRY_REL) return null;
  let out = content;
  const tCount = countOf(out, TIMEOUT_OLD);
  const rCount = countOf(out, RETRY_OLD);
  if (tCount !== 1 || rCount !== 1) {
    throw new Error(`anchor count mismatch: ${TIMEOUT_OLD} x${tCount}, ${RETRY_OLD} x${rCount} - refusing to patch`);
  }
  out = out.replace(TIMEOUT_OLD, TIMEOUT_NEW);
  out = out.replace(RETRY_OLD, RETRY_NEW);
  if (countOf(out, TIMEOUT_NEW) !== 1 || countOf(out, RETRY_PROBE) !== 1) {
    throw new Error("post-splice signature check failed - refusing to emit candidate");
  }
  return out;
}

function syntaxCheck(candidatePath, patchedBuf) {
  const tmp = candidatePath + ".syntaxcheck.mjs";
  writeFileSync(tmp, patchedBuf);
  try {
    const r = spawnSync(process.execPath, ["--check", tmp], { encoding: "utf8" });
    if (r.status !== 0) {
      throw new Error("node --check FAILED on patched entry:\n" + (r.stderr || r.stdout || "(no output)"));
    }
  } finally {
    try { unlinkSync(tmp); } catch {}
  }
}

function cmdPatch(asarPath, candidatePath, entryBackupPath) {
  if (!existsSync(asarPath)) throw new Error("app.asar not found: " + asarPath);
  const { buf } = readEntry(asarPath);
  const entryShaBefore = sha256(buf);

  if (buf.toString("utf8").includes(TIMEOUT_NEW)) {
    console.log(JSON.stringify({ state: "already-patched", entrySha256: entryShaBefore }));
    process.exitCode = 2;
    return;
  }
  if (!buf.toString("utf8").includes(TIMEOUT_OLD)) {
    throw new Error("pristine anchor " + TIMEOUT_OLD + " not found - bundle changed? aborting");
  }
  // Save the pristine entry for -Restore.
  writeFileSync(entryBackupPath, buf);
  const patched = transform(ENTRY_REL, buf.toString("utf8"));
  const patchedBuf = Buffer.from(patched, "utf8");
  syntaxCheck(candidatePath, patchedBuf);

  const expected = new Map([[ENTRY_REL, patchedBuf]]);
  const meta = rebuildAsar({ sourcePath: asarPath, outPath: candidatePath, transform });
  const vr = verifyRebuild({ sourcePath: asarPath, outPath: candidatePath, expected, meta });
  if (vr.errors && vr.errors.length) {
    throw new Error("candidate verification failed:\n" + vr.errors.join("\n"));
  }
  const { buf: checkBuf } = readEntry(candidatePath);
  console.log(JSON.stringify({
    state: "candidate-built",
    entryShaBefore,
    entryShaAfter: sha256(checkBuf),
    patchedProbe: checkBuf.toString("utf8").includes(RETRY_PROBE) && checkBuf.toString("utf8").includes(TIMEOUT_NEW),
    meta,
  }));
}

function cmdRestore(asarPath, candidatePath, entryBackupPath, expectPatchedSha) {
  if (!expectPatchedSha) throw new Error("restore requires --expect-patched-sha (from the marker)");
  const { buf } = readEntry(asarPath);
  const currentSha = sha256(buf);
  if (currentSha !== expectPatchedSha) {
    throw new Error("current out/host/index.js sha256 does not match the marker - the bundle changed since the patch; refusing blind restore. Use a fresh app repair/upgrade instead.");
  }
  const pristine = readFileSync(entryBackupPath);
  const pristineText = pristine.toString("utf8");
  if (countOf(pristineText, TIMEOUT_OLD) !== 1 || countOf(pristineText, RETRY_OLD) !== 1) {
    throw new Error("entry backup failed its pristine-anchor check - refusing");
  }
  const expected = new Map([[ENTRY_REL, pristine]]);
  const meta = rebuildAsar({
    sourcePath: asarPath,
    outPath: candidatePath,
    transform: (rel) => (rel === ENTRY_REL ? pristineText : null),
  });
  const vr = verifyRebuild({ sourcePath: asarPath, outPath: candidatePath, expected, meta });
  if (vr.errors && vr.errors.length) {
    throw new Error("restore candidate verification failed:\n" + vr.errors.join("\n"));
  }
  console.log(JSON.stringify({ state: "restore-candidate-built", meta }));
}

function cmdStatus(asarPath) {
  const { buf } = readEntry(asarPath);
  const text = buf.toString("utf8");
  const state = text.includes(TIMEOUT_NEW) && text.includes(RETRY_PROBE)
    ? "patched"
    : (text.includes(TIMEOUT_OLD) && text.includes(RETRY_OLD) ? "pristine (needs patch)" : "unknown (bundle changed)");
  console.log(JSON.stringify({ state, entrySha256: sha256(buf) }));
}

const [, , mode, ...rest] = process.argv;
const arg = (name) => {
  const i = rest.indexOf(name);
  return i !== -1 ? rest[i + 1] : undefined;
};
const asarPath = arg("--asar");
const candidatePath = arg("--out");
const entryBackupPath = arg("--entry-backup");

if (mode === "patch") {
  cmdPatch(asarPath, candidatePath, entryBackupPath);
} else if (mode === "restore") {
  cmdRestore(asarPath, candidatePath, entryBackupPath, arg("--expect-patched-sha"));
} else if (mode === "status") {
  cmdStatus(asarPath);
} else {
  console.error("usage: patch_zcode_business_exchange.mjs patch|restore|status --asar <app.asar> [--out <candidate>] [--entry-backup <file>] [--expect-patched-sha <sha>]");
  process.exitCode = 1;
}
