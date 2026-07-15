# Lattice: real-work readiness + UI craft plan

Research date: 2026-07-15.

## Context

Lattice is already strong as a **control plane**: modes (Code / Work / Local), multi-harness routing, durable sessions, approvals, outbox, checkpoints, multimodal input, and honest readiness. That is more infrastructure than many demos ship.

It still feels short of **daily driver** quality because competitors win on the loop around the agent:

| Surface | What they optimize for |
| --- | --- |
| **T3 Code** ([pingdotgg/t3code](https://github.com/pingdotgg/t3code)) | Multi-thread missions, worktrees, integrated terminal + file browser, review/diff comments, preview, remote continuity, command palette as a workflow hub |
| **OpenCode desktop** ([anomalyco/opencode](https://github.com/anomalyco/opencode)) | Session-scoped terminal/file tree that survives chat switches, review panel, context breakdown, remote session isolation, lean Tauri shell |
| **Codex Desktop** (closed; app-server OSS) | Transcript-first quiet chrome, floating composer, progressive disclosure, subagents, editor side panel, computer use, git worker integration |
| **Open clients** ([0xcaff/codex-web](https://github.com/0xcaff/codex-web), [friuns2/codex-mobile](https://github.com/friuns2/codex-mobile) / codexapp) | Thin UI over Codex app-server: images, subagents, project picker, voice dictation, portability—not reverse-engineered secrets, but **workflow surface area** |

Lattice already studied T3/OpenCode in this folder and Codex hierarchy in [codex-visual-hierarchy-audit.md](../codex-visual-hierarchy-audit.md). This plan turns that into a **product path**: stop adding more demos; close the “live coding day” gaps and unify the visual system.

**North star:** one clean window where a developer can run parallel agent threads, see changes, run shell/tests, review/revert, approve safely, and never wonder what the UI means.

---

## What Lattice already has (do not rebuild)

Reuse and finish these instead of greenfield:

| Capability | Where |
| --- | --- |
| Glass / content surface tokens | `Sources/Lattice/GlassStyle.swift` (`LatticeMetrics`, `GlassSurface`, `LatticeContentSurface`) |
| Codex hierarchy principles | `docs/codex-visual-hierarchy-audit.md` |
| Competitive P1/P2 backlog | `docs/research/competitive-backlog.md` |
| Outbox + fast switch | `SessionInputOutbox`, `SessionProjectionCache`, Command-K chat switch |
| Checkpoints / Review / guarded revert | `WorkspaceCheckpointService`, `CheckpointReviewView` |
| Work docks | `WorkProjection` + Conversation work dock |
| Multimodal + screenshots | `ContextAttachment*`, `ScreenshotCaptureService`, computer frames |
| Activity lanes / scheduler | thread activity, concurrent task scheduler |
| Responsive layout policy | `LatticeResponsiveLayoutPolicy` (narrow/regular/wide) |

---

## Recommended approach

Two parallel tracks with **work-loop features first**, UI craft as a continuous pass on every surface we touch (not a separate “redesign everything” rewrite).

### Track A — Make Lattice good for real work

#### A0. Define the daily-driver loop (product contract)

A real session must support, end-to-end:

1. Open project → pick mode/route → run agent  
2. Parallel threads with visible status (running / approval / failed / queued)  
3. See **files the agent changed** without leaving Lattice  
4. Run **shell / tests** in a workspace-scoped terminal that survives chat switch  
5. Comment / follow-up on a path/hunk; queue send if busy  
6. Checkpoint review + guarded revert  
7. Switch threads fast with no draft/state bleed  

Anything outside this loop is P2+.

#### A1. P0 — Work-loop reliability (polish what you have)

Finish trust for daily use on infrastructure already shipped:

- **Outbox UX:** always-visible pending/failed/retry rows; restart-review must be one click, never silent  
- **Thread switch performance:** keep projection cache warm; never flash empty transcript for loaded history  
- **Approvals:** one obvious surface (composer-adjacent + inspector), plain language, no badge maze  
- **Connections / readiness:** one source of truth for “can send”; Diagnose / refresh must do real work  
- **Copy consistency:** kill leftover jargon (“Reinstall Pin”, empty/approved circles without legend)  
- **Checkpoint Review:** promote from empty-state novelty to post-run default for Code mode  

**Files:** `AppState.swift`, `ConversationView.swift`, `InspectorView.swift`, `CheckpointReviewView.swift`, Connections/Models views, readiness types in LatticeCore.

#### A2. P1 — Integrated terminal (workspace-scoped)

**Why:** T3 (`ThreadTerminalDrawer`) and OpenCode (terminal tab-switch e2e) treat terminal as first-class. Without it, Lattice forces context switch to Terminal.app and loses the agent loop.

**Design for Lattice:**

- Workspace-owned terminal sessions (not per-chat process by default)  
- Persist across chat switches (OpenCode regression pattern)  
- Spawn from failed tool / “open cwd” actions  
- Optional: attach last command output as context (user-initiated only)  
- No fake PTY scraping as primary agent channel—agent stays structured harness  

**New modules (suggested):** `Sources/LatticeCore/WorkspaceTerminal.swift` + `Sources/Lattice/TerminalPanelView.swift`, layout slot in `WorkspaceView` / conversation layout.

#### A3. P1 — File tree + lightweight preview

**Why:** T3 `FileBrowserPanel`, OpenCode file-browser sidebar. Agents write files; users need to open them without Finder.

**Design:**

- Lazy tree for selected workspace  
- Single-click preview (text + images); pin open  
- Jump from action trail / checkpoint change list / tool write path  
- Never auto-open secrets paths; respect ignore defaults  

**Suggested:** `Sources/Lattice/FileBrowserPanel.swift` + core listing policy in LatticeCore (bounded, cancellable).

#### A4. P1 — Review surface upgrade (beyond checkpoint empty state)

You have Git-native checkpoints; competitors also show **live dirty state + inline comments**.

- Per-session changed-file list (from after-run checkpoint *and* optional live `git status`)  
- Lazy diffs, path-keyed selection  
- Review notes → composer context only on explicit “Add to follow-up”  
- Align Inspector Review tab with Conversation dock so one mental model  

**Reuse:** `WorkspaceCheckpointService`, `CheckpointReviewView`, `InspectorView`.

#### A5. P2 — Context honesty + previews

- **Context breakdown** (OpenCode style): system / user / assistant / tool / other; separate provider-reported totals; label estimates  
- **Preview picker** only if product needs web/app preview (T3-style); otherwise defer—terminal + files cover more coding days  

#### A6. P2 — Continuity (later, security-first)

Remote/mobile (T3 remote.md, OpenCode remote isolation, codex-web host model): only after authenticated environment identity, scoped permissions, and outbox receipts. Do **not** bolt on a tunnel as a feature toggle.

#### A7. What *not* to copy

- Web/Electron shell for parity—stay native control plane  
- Pixel-copy Codex branding or reverse-engineered private assets  
- Claiming Computer Use = full mouse mediation unless product explicitly owns that risk  
- Another provider integration before the work loop is excellent  

---

### Track B — UI craft: stop “mismatched + default”

#### Diagnosis (current Lattice)

Evidence from code + prior Codex audit:

1. **Two visual dialects**
   - Crafted: glass chrome, morphing composer (`MorphingControl`), metrics in `GlassStyle.swift`
   - Stock SwiftUI: heavy `.borderedProminent`, `ContentUnavailableView`, `.listStyle(.sidebar)`, `.formStyle(.grouped)` especially in Inspector, Connections, Morphing context menu, archives  

2. **Glass overuse vs content**
   - Principle already written: glass = chrome only; transcript/catalog = flat/quiet opaque  
   - Some secondary panels still feel “card on card on glass”

3. **Hierarchy noise**
   - Too many equal-weight buttons/badges (readiness, mode, model, policy, workspace)  
   - Codex wins by: quiet sidebar, icon top bar, **one** strong floating composer, progressive disclosure  

4. **Empty / default states**
   - Generic SF Symbol + system empty views feel like a template app  
   - Need Lattice-specific empty states (short, confident, one primary action)

5. **Density mismatch**
   - Chat area aspirational; settings/inspector still “preferences window 2019”

#### B1. Design system completion (1 PR, high leverage)

Extend `GlassStyle.swift` / new `LatticeControls.swift`:

| Token / component | Purpose |
| --- | --- |
| `LatticePrimaryButtonStyle` | Replace most `.borderedProminent` |
| `LatticeSecondaryButtonStyle` | Quiet bordered |
| `LatticeGhostButtonStyle` | Icon toolbar |
| `LatticeEmptyState` | Title, one sentence, one primary CTA (no stock ContentUnavailable default look) |
| `LatticeSectionHeader` | Consistent inspector/settings headers |
| `LatticeRow` | Sidebar/session/file rows with single selection fill |
| Typography scale | Title / body / mono (code, paths, diffs) with fixed line heights |
| Semantic status colors | running / approval / failed / success—one map used everywhere |

Rule: **no new screen may introduce raw `.borderedProminent` or unstyled Form without tokens.**

#### B2. Information architecture (Codex-like calm)

Apply existing audit principles in layout code:

1. **One dominant plane** — transcript full-bleed, max readable width (~72–80ch), no nested glass cards around messages  
2. **Composer is the only strong float** — capture/attach menus restyled to match MorphingControl (not system menu soup)  
3. **Inspector = progressive disclosure** — summary first; advanced harness/debug collapsed  
4. **Sidebar quiet** — activity dots, not multi-line badges; secondary actions on hover/context menu  
5. **Toolbar minimal** — icon actions + one overflow menu for global secondary  
6. **Mode chrome** — Code / Work / Local should feel like one segmented control system, not three different pages  

**Primary files:** `WorkspaceView.swift`, `ConversationView.swift`, `MorphingControl.swift`, `InspectorView.swift`, `OverlayPanel.swift`, `CommandPaletteView.swift`.

#### B3. Surface-by-surface craft pass (order)

1. **Conversation + composer** (highest daily time)  
2. **Sidebar + Command-K**  
3. **Inspector Review / Checkpoints**  
4. **Connections / Models / readiness** (kill “default Form” feel)  
5. **Work dock**  
6. **Archives / recovery** (can stay utilitarian but tokenized)

#### B4. Mismatch kill-list (concrete)

- Morphing “Files… / Paste Image” using system bordered styles → custom chips  
- Inspector grouped Form vs glass chat → content surfaces + section headers  
- ContentUnavailable empty states → `LatticeEmptyState` with Lattice copy  
- Mixed radii (12/14/16/18/20) without role → enforce `LatticeMetrics` only  
- Status chips that use random color opacity → semantic map  
- Dense multi-button approval rows → primary/secondary hierarchy  

#### B5. Motion and feel

- Shared spring for expand/collapse (respect Reduce Motion)  
- Stagger only on first-open panels, never on every keystroke  
- Focus rings visible and consistent for keyboard users  

---

## Implementation roadmap (suggested PR sequence)

| PR | Track | Outcome |
| --- | --- | --- |
| **1** | B1 | Control + empty-state design system; no feature change |
| **2** | B2+B3.1 | Conversation + composer visual unification |
| **3** | A1 | Outbox / approval / readiness / copy reliability |
| **4** | A3 | File tree + preview panel |
| **5** | A2 | Workspace terminal panel |
| **6** | A4 | Review UX: live changes + notes → follow-up |
| **7** | B3.3–4 | Inspector + Connections craft pass |
| **8** | A5 | Context breakdown honesty |

Each PR: `./script/build_and_run.sh --test` + `--verify`, real-app visual QA, a11y (VoiceOver labels, Reduce Transparency).

---

## Competitive inspiration map (steal patterns, not pixels)

| Pattern | Source | Lattice move |
| --- | --- | --- |
| Terminal survives chat switch | OpenCode e2e | Workspace-scoped terminal |
| File browser + pin | T3 / OpenCode | Lazy tree + preview |
| Review comments → explicit context | T3 `review.ts` | Notes only enter composer on action |
| Context category breakdown | OpenCode | Extend local estimate honesty |
| Transcript-first quiet chrome | Codex Desktop audit | Layout + hierarchy PR |
| Command palette as hub | T3 | Already started; deepen status + actions |
| Thin app-server client | codex-web / codexapp | Keep structured harness; don’t rebuild Codex UI in web |
| Project picker + pin | codexapp | Projects list craft + sticky recent |
| Voice dictation | codexapp | Optional later; not P0 |

---

## Critical files

**UI system**

- `Sources/Lattice/GlassStyle.swift`
- New: `Sources/Lattice/LatticeControls.swift` (or expand GlassStyle)
- `Sources/Lattice/WorkspaceView.swift`
- `Sources/Lattice/ConversationView.swift`
- `Sources/Lattice/MorphingControl.swift`
- `Sources/Lattice/InspectorView.swift`
- `Sources/Lattice/OverlayPanel.swift`
- `Sources/Lattice/CommandPaletteView.swift`
- `Sources/Lattice/CheckpointReviewView.swift`

**Work-loop features**

- `Sources/Lattice/AppState.swift`
- `Sources/LatticeCore/SessionInputOutbox.swift`
- `Sources/LatticeCore/WorkspaceCheckpoint*.swift`
- `Sources/LatticeCore/WorkProjection.swift`
- New: terminal + file browser modules under Lattice / LatticeCore

**Research anchors (read, update when implementing)**

- `docs/research/competitive-backlog.md`
- `docs/research/t3-code-comparison.md`
- `docs/research/session-outbox-fast-switch.md`
- `docs/codex-visual-hierarchy-audit.md`

---

## Verification

### Work-loop (manual daily-driver script)

1. Open a real repo as workspace; create two Code threads  
2. Run a change-making agent task in A; switch to B mid-run; drafts and activity stay correct  
3. Queue a follow-up in A while running; see outbox state; complete / fail / retry  
4. Open file tree → preview a changed file; open terminal → run tests  
5. Inspector Review: after-run checkpoint, note on hunk, add to follow-up, guarded revert preview  
6. Disconnect a provider; readiness tells truth and recovery works  
7. Rapid Command-K switch across 8+ chats with no blank flash / wrong draft  

### UI craft

1. Side-by-side screenshots: Conversation, Inspector, Connections, empty chat, approval  
2. Reduce Transparency + increased contrast still legible  
3. Narrow (640) / regular (900) / wide (1600) layout checks from existing responsive policy  
4. No orphan `.borderedProminent` outside design-system exceptions list  
5. VoiceOver: sidebar, composer, primary send/stop, approval options  

### Automated

```bash
./script/build_and_run.sh --test
./script/build_and_run.sh --verify
```

Add tests for: terminal session survival across session switch (policy unit tests), file listing bounds, review-note → follow-up payload construction, design-token non-regression only where logic exists.

---

## Success criteria

Lattice is “real work” ready when a developer can spend a full coding session **without** Terminal.app + Finder + Git GUI for the common path—and the UI feels like **one product**, not a glass chat bolted onto stock Forms.

Demo-ready is: features exist.  
Work-ready is: features are **fast, consistent, discoverable, and hard to misread under stress**.
