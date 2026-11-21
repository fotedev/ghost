# T3 Code — local support for the GHOST apps (2026-10-28)

[T3 Code](https://github.com/pingdotgg/t3code) (pingdotgg, MIT) is a control
surface for headless agent CLIs (desktop + web + mobile clients over a local
server). This page is the overview of how the GHOST-managed apps plug into it
**locally, on our own schedule** — no waiting for upstream merges. The
implementation study copy of the T3 monorepo lives at
`C:\programming\github\t3code` (full clone, 1016 MB on disk, HEAD
`9826dbb990`, read-only reference — no `pnpm install`, never committed to
GHOST).

Strategy: **local first, upstream second.** Everything we need works through
T3's own extension surfaces (Local ACP command / ACP Registry), so a stock T3
Code install runs our providers with zero T3 source changes. Anything that
proves itself and fits upstream policy (`CONTRIBUTING.md` — limited review
capacity, coherent scope, replay-fixture evidence) goes back as a PR from a
GitHub fork.

## Support matrix

| GHOST app | In T3 Code? | Path |
| --- | --- | --- |
| **ZCode** (Z.ai Start Plan accounts) | Via our bridge — **IMPLEMENTED + WIRED (phases A-D, 2026-10-29)** | [T3_ZCODE_BRIDGE_SPEC.md](T3_ZCODE_BRIDGE_SPEC.md) — ACP ⇄ ZCode Protocol adapter; `tools/t3_zcode_bridge.mjs` + probe + fake-client harness; T3 Code v0.1.4 installed and the five accounts pre-seeded in `~/.t3/userdata/settings.json`; live-acceptance runbook in spec §9.2 (gated on the per-home [28] login) |
| **OpenCode** (desktop clone suite accounts) | Native — **SEEDED (2026-11-07)** | `tools/install_t3_opencode_instances.ps1` seeds five `acpRegistry` instances (backup + verify-after + merge-never-overwrite; [OPENCODE_CLONES_SPEC.md](OPENCODE_CLONES_SPEC.md) §3.10): each launches `launch_opencode_cli_light.ps1 -Instance cN -Acp`, which sets the four XDG clone-home levers and execs `opencode acp` on stdio (handshake live-verified: protocolVersion 1). T3-UI acceptance user-supervised; one manual `opencode auth login` per clone home attaches its account (anonymous = FREE model) |
| **Claude Code / Codex / Grok / Cursor / Pi / Antigravity** | Native | First-class T3 providers (if you hold subscriptions) |
| **AutoClaw** | Not applicable | Desktop app with its own gateway/MCP ports — not a headless agent CLI; T3 controls agents, not Electron IDEs |
| **Cline** | Not yet (no ACP surface probed) | STALE-FIX 2026-11-21: this row predated the Cline CLI — the desktop install DOES ship `cline-cli.exe` and GHOST runs it headless per clone home (`launch_cline_cli_light.ps1`, CLINE_DIR lever, Cline [22]/[23], CL-1 acceptance open). What is still missing for T3 is a probed ACP/stdout mode, not a CLI |
| **QoderWork / MiniMax Agent / Windsurf / Trae / Qoder** | Not applicable | Same class — desktop IDEs, no orchestratable agent CLI |
| **Claude Code (GHOST Terminal Agents pilot, 2026-11-21)** | Outside T3 for now — GHOST clones ride per-instance `CLAUDE_CONFIG_DIR` homes (`launch_claude_code_light.ps1`, Terminal Agents [1]-[4]; spec = [TERMINAL_AGENTS_SPEC.md](TERMINAL_AGENTS_SPEC.md)). As a T3 provider claude-code is already native (row above) |

## Why this is cheap

Both sides of the ZCode bridge speak **newline-delimited JSON over stdio**:

- T3 ⇄ agent: ACP (JSON-RPC 2.0, NDJSON framing; v1 methods negotiated by
  response shape — verified in `packages/effect-acp/src/client.ts`).
- Bridge ⇄ ZCode: "ZCode Protocol" NDJSON from `zcode app-server` (verified by
  bundle probes; envelope `{id, method, params}`).

So the ZCode bridge is one Node process translating between two NDJSON
dialects — no Electron, no patching, no T3 fork. Account isolation per T3
provider instance rides the four verified env levers
(`HOME`+`USERPROFILE`+`ZCODE_DATA_BASE_DIR`+`ZCODE_STORAGE_DIR` → clone home),
which is exactly what T3's own docs prescribe ("use the agent's own
configuration to isolate accounts").

## Local-vs-upstream split

- **Stays local:** the bridge itself, per-clone wiring, GHOST menu entries.
- **PR-able later** (only after a live-proven bridge, per the upstream bar):
  an ACP Registry entry pointing at a published bridge package; a first-class
  `packages/provider-zcode` driver only if the generic ACP surface provably
  loses features (see `docs/internals/adding-a-provider.md` in the clone for
  the replay-fixture bar a driver PR must clear).

## References

- Bridge design + phased plan: [T3_ZCODE_BRIDGE_SPEC.md](T3_ZCODE_BRIDGE_SPEC.md)
- T3 user docs for ACP: `docs/user/providers-acp.md` (in the clone)
- T3 internals: `docs/internals/overview.md`, `docs/internals/providers.md`,
  `docs/internals/adding-a-provider.md` (in the clone)
- Light-mode context (headless workers, env levers, model caveats):
  [ZCODE_LIGHT_MODE.md](ZCODE_LIGHT_MODE.md)
