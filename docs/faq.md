# FAQ

**Is this legal / will it get me banned?**
The scripts modify identifiers on **your own machine**. They may violate the
Terms of Service of the covered vendors; using them is your decision and your
risk. There is no guarantee of any particular outcome — see the disclaimer in
the [README](../README.md#disclaimer) and [SECURITY.md](../SECURITY.md).

**Why do all these IDEs correlate with each other?**
They are all VS Code forks whose telemetry IDs (`telemetry.machineId`,
`.sqmId`, `.devDeviceId`, `.macMachineId`) derive from the same Windows
registry source at first launch. Resetting one tool but not the others leaves
a cross-tool correlation trail — that's why the toolkit covers each app
explicitly, and why machine-wide `change_device_id.ps1` exists as a separate
optional step.

**Windsurf became Devin Desktop — which one do I reset?**
Both, with one command: `reset_devin.ps1` auto-detects every existing data
root under `%APPDATA%` (`Devin`, `Windsurf`) and resets all of them in a
single pass. Even inside the rebranded root the app still writes
windsurf-named auth keys, and the script scrubs both naming schemes.

**Where did the version suffixes in filenames go?**
Versioning moved to Git tags and [CHANGELOG.md](../CHANGELOG.md) — file names
are now stable (`reset_cursor.ps1`, not `reset_cursor_windows-v0.2.ps1`), so
launchers and docs never break on a version bump. Superseded versions live in
`archive/` on disk only; they are never committed.

**Is `archive/` in the repo?**
No — it's git-ignored and local-only (it contains old-fingerprint material by
definition). History was purged of it as well; don't rely on a fresh clone
having it.

**Do the scripts need the app closed?**
Yes — the scripts also force-kill the target's processes, but close it anyway
first. A running app rewrites the identity files the script just deleted.

**What is preserved?**
Chat history, `Local Storage`, editor `Backups\`, workspaces, third-party
extension secrets, and user content directories are never deleted. Every
script documents its own preservation list in `docs/getting-started.md`.

**Why does the Windows reset need Administrator?**
Process tree-kill of elevated app instances and (for some scripts) registry
steps require elevation. The scripts self-elevate and log to `%TEMP%`.

**Does this work on Linux for every tool?**
No. Linux currently covers Cursor, Windsurf, fingerprint, and machine-id.
Trae/Qoder/ZCode/MiniMax resetters are Windows-only — the platform table in
the [README](../README.md#how-it-works) is authoritative.
