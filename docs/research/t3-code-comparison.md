# T3 Code comparison: chat navigation and workflow

Research date: 2026-07-15. This note uses only the public upstream repository, its tagged releases, code, issues, and official repository documentation.

## Reproducible source context

The comparison was made against T3 Code commit [`3513fa04fbf12c1d4fa2b8d07cfc7f0905714d31`](https://github.com/pingdotgg/t3code/tree/3513fa04fbf12c1d4fa2b8d07cfc7f0905714d31), authored 2026-07-14 with subject “Prepare Android beta branding and review diff UI (#3967).” That commit is tagged [`v0.0.29-nightly.20260714.809`](https://github.com/pingdotgg/t3code/releases/tag/v0.0.29-nightly.20260714.809). The most recent stable tag present in that checkout was [`v0.0.28`](https://github.com/pingdotgg/t3code/releases/tag/v0.0.28), commit `fda6486233e0b2f07ecfea166e1a94533cb923c4`, authored 2026-06-29.

Primary sources inspected at the pinned commit:

- [Repository README](https://github.com/pingdotgg/t3code/blob/3513fa04fbf12c1d4fa2b8d07cfc7f0905714d31/README.md) and [AGENTS.md architecture map](https://github.com/pingdotgg/t3code/blob/3513fa04fbf12c1d4fa2b8d07cfc7f0905714d31/AGENTS.md).
- [Command palette catalog/filter policy](https://github.com/pingdotgg/t3code/blob/3513fa04fbf12c1d4fa2b8d07cfc7f0905714d31/apps/web/src/components/CommandPalette.logic.ts), [its focused tests](https://github.com/pingdotgg/t3code/blob/3513fa04fbf12c1d4fa2b8d07cfc7f0905714d31/apps/web/src/components/CommandPalette.logic.test.ts), and [the React palette integration](https://github.com/pingdotgg/t3code/blob/3513fa04fbf12c1d4fa2b8d07cfc7f0905714d31/apps/web/src/components/CommandPalette.tsx). The policy exposes up to 12 recent non-archived threads, searches the full thread set, includes project/branch context, and renders thread status indicators.
- [Official keybindings guide](https://github.com/pingdotgg/t3code/blob/3513fa04fbf12c1d4fa2b8d07cfc7f0905714d31/docs/user/keybindings.md), including the global `commandPalette.toggle` command and context-sensitive bindings.
- [Official architecture encyclopedia](https://github.com/pingdotgg/t3code/blob/3513fa04fbf12c1d4fa2b8d07cfc7f0905714d31/docs/reference/encyclopedia.md), which describes typed commands, persisted domain events, projections, activities, provider sessions, and checkpoints.
- [Thread sorting policy](https://github.com/pingdotgg/t3code/blob/3513fa04fbf12c1d4fa2b8d07cfc7f0905714d31/packages/client-runtime/src/state/threadSort.ts) and [serialized thread command scheduling](https://github.com/pingdotgg/t3code/blob/3513fa04fbf12c1d4fa2b8d07cfc7f0905714d31/packages/client-runtime/src/state/threadCommands.ts).
- [Issue #372](https://github.com/pingdotgg/t3code/issues/372), an upstream report showing why readiness banners and the execution path must share one source of truth and expose recovery/dismissal behavior.
- [T3 Code MIT license](https://github.com/pingdotgg/t3code/blob/3513fa04fbf12c1d4fa2b8d07cfc7f0905714d31/LICENSE). No T3 Code source or branding was copied; the implementation below is an independent native Swift design based on the product pattern.

## Architecture and workflow comparison

| Concern | T3 Code at the pinned commit | Lattice before this change | Lattice direction |
| --- | --- | --- | --- |
| Product shell | React/Vite clients over a Node WebSocket server, with Electron/mobile surfaces | Native SwiftUI app with reusable policy and domain logic in `LatticeCore` | Keep the native, local control-plane boundary; do not add a web/server layer for parity |
| Runtime events | Provider activity becomes orchestration domain events and projected read models | Structured harness events feed durable transcripts/action trails plus per-chat UI state | Continue toward a durable replayable run ledger without weakening provider boundaries |
| Thread workflow | Project-scoped threads, optional worktrees, archive state, checkpoints, diffs | Workspace-bound durable chats, explicit modes/routes, queues, approvals, import/export | Adopt isolated worktree missions only with explicit scope, review, and integration gates |
| Navigation | One global palette combines actions, projects, recent threads, full thread search, and status | Command-K searched actions only; chat search lived in a separate column | Add safe chat quick switching to the existing palette using metadata and existing activity lanes |
| Command discovery | Configurable, context-aware keybinding command IDs and palette actions | Fixed native shortcuts, slash skills, and a searchable action palette | A typed customizable shortcut registry is promising later work, but requires conflict/accessibility design |
| Observability | Server traces/metrics plus user-visible activities and checkpoints | Inspector disclosures, action trails, run UI state, and truthful readiness | Prefer user-visible durable evidence first; local diagnostic export can follow with redaction controls |

## Selected improvement

The bounded implementation is a chat quick switcher inside Lattice’s existing Command-K palette:

- Empty search shows the six highest-priority recent/pinned chats before commands.
- Search covers every chat title and workspace path plus the existing commands.
- Chat rows expose current, running, queued, approval, failure, unread, and attention state from Lattice’s existing per-thread activity lanes.
- Selecting a chat uses the existing workspace navigation path. It does not execute a provider, change a route, read a transcript, touch credentials, or bypass approval/privacy policy.
- Metadata-only sessions remain searchable without transcript hydration, keeping the interaction responsive and avoiding an unrelated persistence side effect.

This fits Lattice’s mission because it shortens a frequent multi-thread workflow while making background state more visible. It is intentionally separate from setup badges, window-layout restoration, transcript hydration, scheduling, model selection, and visual-cleanup work.

## Ideas retained for later evaluation

1. A typed, user-editable keybinding registry with conflict reporting and complete VoiceOver discovery.
2. A replayable append-only run ledger and redacted diagnostic export, built from normalized events rather than terminal text.
3. Explicit worktree-backed mission steps with non-overlapping write scopes and a human integration gate.
4. User-visible workspace checkpoints and turn diffs after durability, rollback, storage, and failure semantics are specified.

These are architectural directions, not claims of current Lattice capability.
