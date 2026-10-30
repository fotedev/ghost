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
| **OpenCode** (desktop clone suite accounts) | Native, zero code | T3 ships an OpenCode provider (`docs/user/providers-opencode.md`); one manual `opencode auth login` per account. Per-account isolation rides the same env-lever pattern as the clone suite (XDG homes) if T3's single-auth model is too narrow |
| **Claude Code / Codex / Grok / Cursor / Pi / Antigravity** | Native | First-class T3 providers (if you hold subscriptions) |
| **AutoClaw** | Not applicable | Desktop app with its own gateway/MCP ports — not a headless agent CLI; T3 controls agents, not Electron IDEs |
| **Cline** | Not applicable | Tauri desktop app, no headless CLI surface |
| **QoderWork / MiniMax Agent / Windsurf / Trae / Qoder** | Not applicable | Same class — desktop IDEs, no orchestratable agent CLI |

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
