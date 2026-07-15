# Code Quality Remediation Plan

**Status:** ready to implement  
**Target branch:** feature branch then merge to `main` after green verification  
**Source:** full-codebase review on `main` @ `6831ed7` (15 structural findings)  
**Constraint:** preserve behavior; no simulated completions; honesty about unavailable capabilities; secrets stay out of logs/UserDefaults

## Goals

1. Eliminate the AppState god-object as the sole owner of every concern.
2. Collapse multi-authority route identity onto `ExecutionRoute`.
3. Replace provider field sprawl with a typed runtime snapshot map.
4. Make run launch + event apply a plan → gateway → reducer pipeline.
5. Split oversized files past the 1k-line boundary where ownership is clear.
6. Keep LatticeCore free of SwiftUI/AppKit; keep presentation helpers out of orchestration.
7. Ship only after `./script/build_and_run.sh --test` and `./script/build_and_run.sh --verify` pass.

## Non-goals

- New product features.
- Provider protocol rewrites beyond extraction/composition.
- Rewriting harness dialects from scratch.
- UI redesign / design-system work.

## Key Decisions

### K1 — Composition root, not a second god-object
`AppState` remains the SwiftUI `@EnvironmentObject` entry point **only as a thin façade**. Ownership moves into focused stores/controllers. Prefer nested `ObservableObject`s (or `@Observable` where already used) so ConversationView does not re-render on CLI version probes.

### K2 — Behavior-preserving extraction
Every move is: (1) extract pure/helpers first, (2) wire AppState to call them, (3) shrink AppState methods to forwards, (4) only then change call sites. No big-bang rewrite of `apply(event:)`.

### K3 — ExecutionRoute is durable authority
Session stores `executionRoute` as sole authority. `ChatBackend` becomes a derived projection for legacy UI/compat. Session-level `harnessID` remains decode-only until migration complete, then dropped from new writes. AppState `selectedRouteEngineID` / `selectedRouteHarnessID` are deleted once composer selection uses mode+route.

### K4 — ProviderRuntimeSnapshot map
One value type:

```swift
struct ProviderRuntimeSnapshot: Equatable, Sendable {
  var installed: Bool
  var authenticated: Bool
  var catalogStatus: ProviderCatalogStatus
  var models: [ProviderModel] // or HarnessModel where appropriate
  var cliVersion: String?
  var latestCLIVersion: String?
  var protocolDetail: String? // optional freeform / typed later
  var ready: Bool
}
```

Keyed by `LatticeRuntimeID` (or stable provider id string already used). Refresh becomes one loop over probe adapters.

### K5 — Run pipeline
- `RunLaunchPlanner` (Core or app pure): session + catalogs → `RuntimeLaunch` enum or delivery issue  
- `LatticeExecutionCoordinating` already streams events  
- `SessionRunReducer` (pure where possible): `(SessionRunState, AgentEvent) -> (SessionPatch, [SideEffect])`  
- One `finalizeRun(_ terminal:)` for completed/cancelled/failed/permission-denied ladders

### K6 — Typed RuntimeLaunch
Replace kitchen-sink `LatticeExecutionLaunch` optionals with:

```swift
enum RuntimeLaunch {
  case codex(CodexLaunch)
  case acp(ACPLaunch)
  case pi(PiLaunch)
  case antigravity(AntigravityLaunch)
  case ollama(OllamaLaunch)
  case apple(AppleLaunch)
}
```

Coordinator exhaustively matches. Secrets stay in launch payloads, never logged.

### K7 — File splits are ownership splits
Do not “move code around” without a clearer owner. Target modules:

| Module | Owns |
|--------|------|
| `SessionCatalogStore` | sessions array, selection, persistence, hydration, drafts |
| `RunOrchestrator` | startRun, scheduler, outbox dispatch, apply, finalize |
| `ProviderConnectionStore` | snapshot map, refresh, install, auth CLI |
| `WorkspaceToolsController` | file browser + terminal |
| `SelfEditDraftStore` | preview draft maps + save via Core editor |
| `ComposerController` | mode/model/route, sendDraft surface API |
| `AppState` | wires stores, environment object, lifecycle |

### K8 — Dead protocols
Delete unused aspirational protocols in `Interfaces.swift` **or** make real harnesses conform to one thin `RuntimeStreaming` if two implementations already exist. Prefer delete until a second implementation needs the abstraction.

## Attack Order (must implement in this sequence)

### Phase 0 — Safety rails (do first)
1. Create branch `refactor/code-quality-remediation` from current `main`.
2. Confirm baseline green: `./script/build_and_run.sh --test` (or note failures that are pre-existing and do not expand them).
3. Add no new public APIs using legacy `Nisa` names.

### Phase 1 — Domain & file hygiene (Issues 7, 8, 12 partial)
**Deliverables:**
- Split `Domain.swift` into cohesive files without changing type names/API:
  - `SessionModels.swift` — `LatticeSession`, `ChatMessage`, `QueuedFollowUp`, session storage types
  - `AgentEvents.swift` — `AgentEvent`, plan steps, activity events
  - `Attachments.swift` — `ContextAttachment*` types
  - `CommandPaletteModels.swift` — palette types/matcher
  - `ComposerPresentation.swift` — `MorphingControlState`, reasoning UI types as needed
  - Keep a thin `Domain.swift` only if needed as documentation re-export comment (SwiftPM compiles all files in target; no re-export required)
- Rename `HermesACPHarness.swift` → `ACPHarness.swift` (type is already `ACPHarness`).
- Split `ExtensionRuntime.swift` along natural seams: permissions/manifest, stores, preview editor, style/layout patches — preserve public types.

**Verification:** build + existing Core tests.

### Phase 2 — Route identity collapse (Issue 3)
**Deliverables:**
- Single source of truth helpers in Core: `ExecutionRouteResolver` / `RouteRuntimeMap` answers readiness runtime, default runtime, cancel target.
- New writes: set `session.executionRoute`; derive backend projection; stop writing divergent harness defaults (Codex→`"codex"` vs catalog `"pi"` inconsistency fixed via one table).
- AppState composer selection uses mode + route only; remove or fully deprecate `selectedRouteEngineID` / `selectedRouteHarnessID` once no call sites remain.
- Update cancel paths in `LatticeExecutionCoordinator` to prefer declared route runtime.

**Verification:** route readiness tests, existing execution tests, manual reason-through of Codex default path.

### Phase 3 — Provider snapshot map (Issue 4)
**Deliverables:**
- Introduce `ProviderRuntimeSnapshot` + store map on `ProviderConnectionStore` (can live as nested type on AppState temporarily, then extract).
- Replace parallel `@Published` provider fields with the map **or** computed accessors that read the map during migration, then delete fields.
- Collapse `refreshCodexConnection` … `refreshLocalConnection` into probe adapters + one refresh loop.
- UI (`InspectorView` Connections) reads snapshots; keep accessibility labels.

**Verification:** connection refresh still fail-closed; catalog statuses truthful.

### Phase 4 — Typed launch + run pipeline (Issues 2, 13)
**Deliverables:**
- Introduce `RuntimeLaunch` enum; migrate `DefaultLatticeExecutionCoordinator.stream` to switch on it.
- Extract pure planning from `launchScheduledProviderRun` into `RunLaunchPlanner`.
- Extract event switch body toward `SessionRunReducer` + side-effect application; **one** `finalizeRun`.
- Checkpoint before/after hooks remain sequenced but call into thin lifecycle hooks, not duplicated ladders.

**Verification:** Core tests; no silent cloud route under local-only; outbox claim/complete still uses pure `SessionInputOutboxPolicy`.

### Phase 5 — AppState decomposition (Issues 1, 5, 10, 11)
**Deliverables (order matters):**
1. `WorkspaceToolsController` — move file browser + terminal state/methods (~8650+) off AppState; WorkspaceView observes it.
2. `SelfEditDraftStore` — collapse draft map CRUD; call `LatticeExtensionPreviewEditor` only.
3. `ProviderConnectionStore` — complete extraction from Phase 3 temporary home.
4. `RunOrchestrator` — startRun/scheduler/outbox/apply/finalize.
5. `ComposerController` — mode/model/send surfaces.
6. `SessionCatalogStore` — sessions, selection, persist/hydrate.
7. AppState becomes wiring + `@Published` projections only where SwiftUI binding still requires.
8. Move `Color`/`NSImage` helpers out of AppState into view/theme types (`GlassStyle` / local helpers).

**Success metric:** `AppState.swift` well under 2k lines (stretch: under 1k façade). No feature logic left as multi-hundred-line private methods on AppState except thin forwards.

### Phase 6 — View modularity (Issues 9, 14)
**Deliverables:**
- Split `ConversationView.swift` into files: Transcript, Composer, WorkDock, SelfEdit preview rows, Message rows — narrow inputs (session snapshot / bindings) instead of full AppState where practical.
- Inspector: pass `InspectorSessionModel` or equivalent for details; keep checkpoint review on its existing review state.

**Verification:** build app; accessibility identifiers preserved.

### Phase 7 — Interfaces / harness composition (Issues 6, 7 remaining)
**Deliverables:**
- Delete unused protocols in `Interfaces.swift` that nothing conforms to **or** document the single kept protocol with real conformances.
- Extract shared interactive session bits only if clear duplication remains after rename (permission waiter + process registry composition). Do not invent a heavy framework.

### Phase 8 — Checkpoint service optional split (Issue 15)
**Deliverables:**
- If still >1k and natural seams exist: `CheckpointCapture` / `CheckpointDiff` / `CheckpointRevert` files under Core.
- AppState/orchestrator only subscribes to run lifecycle hooks.

### Phase 9 — Verification gate (mandatory before push)
```bash
./script/build_and_run.sh --test
./script/build_and_run.sh --verify
```
If UI-touching changes: build the real app target and sanity-check launch path.

Document any known residual debt honestly in the implementation summary (do not claim complete extraction if façade still thick).

## Issue → Phase Map

| Issue | Theme | Phase |
|------:|-------|-------|
| 1 | AppState monolith | 5 |
| 2 | Run launch/apply spaghetti | 4 |
| 3 | Triple route identity | 2 |
| 4 | Provider field sprawl | 3 |
| 5 | Self-edit draft CRUD | 5 |
| 6 | Dead protocols | 7 |
| 7 | ACP harness naming/dup | 1, 7 |
| 8 | Domain.swift grab-bag | 1 |
| 9 | ConversationView size | 6 |
| 10 | Workspace tools on AppState | 5 |
| 11 | Presentation helpers in AppState | 5 |
| 12 | ExtensionRuntime size | 1 |
| 13 | LatticeExecutionLaunch bag | 4 |
| 14 | Inspector AppState threading | 6 |
| 15 | Checkpoint service size | 8 |

## Testing Strategy

- Prefer extending existing LatticeCoreTests for pure extractions (planner, reducer, snapshot, route map).
- Keep deterministic tests; no network in unit tests.
- When moving code, first extract pure functions with tests, then rewire.
- Do not weaken tests to make green; fix code.

## Risk Register

| Risk | Mitigation |
|------|------------|
| SwiftUI re-render regressions | Nested observables; minimize `@Published` fan-out |
| Route migration breaks Codex | Single RouteRuntimeMap + tests for default Code route |
| Credential path regressions | Keep OpenCode Keychain policy; never log secrets; security review |
| Partial extraction leaves worse spaghetti | Strict phase order; no half-migrated dual writes |
| File moves break Xcode/SwiftPM | All Sources under targets auto-include; avoid Package.swift file lists |

## PR Plan (if stacking; single implement may land as one branch)

### PR 1: Domain & file hygiene
- **Files:** `Domain.swift` split, `ACPHarness.swift` rename, ExtensionRuntime split
- **Dependencies:** None
- **Description:** Pure moves/renames; no behavior change

### PR 2: Route identity collapse
- **Files:** Domain session fields usage, ExecutionRoutePolicy, AppState readiness/composer, LatticeExecutionCoordinator cancel
- **Dependencies:** PR 1
- **Description:** ExecutionRoute sole authority

### PR 3: ProviderRuntimeSnapshot
- **Files:** new snapshot types, AppState/ProviderConnectionStore, Inspector Connections
- **Dependencies:** PR 2
- **Description:** Snapshot map + generic refresh

### PR 4: Run pipeline + typed launch
- **Files:** RunLaunchPlanner, SessionRunReducer, LatticeExecutionCoordinator, AppState run methods
- **Dependencies:** PR 2–3
- **Description:** plan → gateway → reduce; RuntimeLaunch enum

### PR 5: AppState store extraction
- **Files:** new stores, AppState shrink, WorkspaceView/Conversation bindings
- **Dependencies:** PR 3–4
- **Description:** Composition root

### PR 6: View splits + interfaces cleanup + checkpoint optional split
- **Files:** ConversationView splits, Inspector models, Interfaces.swift, checkpoint files
- **Dependencies:** PR 5
- **Description:** UI modularity and final hygiene

## Acceptance Criteria

- [ ] All 15 review issues addressed or explicitly residual with justification in summary
- [ ] AppState no longer owns file browser/terminal/self-edit draft CRUD/provider field sprawl/run apply body as monolithic private methods
- [ ] Route identity is not triple-bookkept for new session writes
- [ ] Provider state is map-driven
- [ ] `./script/build_and_run.sh --test` passes
- [ ] `./script/build_and_run.sh --verify` passes
- [ ] No real secrets printed/persisted outside Keychain
- [ ] Local-only still fail-closed for cloud routes

## Implementation Notes for Agent

- Follow `Agents.md` architecture rules strictly.
- Small commits per phase if possible; clear messages.
- Prefer existing patterns (`SessionInputOutboxPolicy`, `WorkProjection`, `WorkspaceCheckpointClient`).
- When conflicted between “complete extraction” and “keep green,” keep green and extract behind façades — but still leave AppState dramatically smaller.
- Do not merge/push to main until verification gate passes; leave push to orchestrator after confirmation.
