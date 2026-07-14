# OpenAI Build Week development log

This repository is the canonical starting point for Lattice's OpenAI Build Week development. The initial open-source release establishes the working product foundation; subsequent entries should make each meaningful Codex and GPT-5.6 contribution easy to identify and reproduce.

Planned work in this file is not a claim that the feature exists. The README, demo, and feature log must continue to distinguish shipped behavior from proposals.

## Product thesis

Lattice should become the inspectable mission control for serious AI-assisted software work on a Mac: one place to choose an available engine and harness, see what each agent is doing, constrain writes and cloud routing, approve consequential actions, recover durable work, and review the evidence before accepting a result.

Build Week implementation should use GPT-5.6 through Codex for demanding codebase analysis, planning, implementation, review, and verification. That is development evidence, not a requirement that Lattice route its own product features through GPT-5.6. Lattice's differentiator should not be a model picker or a generic chat surface. It should be the native control, policy, continuity, and evidence layer around agent workflows.

The flagship Build Week story should remain problem-first:

> Developer agent work is fragmented across opaque terminal sessions and provider apps. Lattice turns it into a durable, reviewable mission with explicit routes, scoped permissions, structured activity, recovery, and a final evidence bundle.

## 2026-07-13 code-review snapshot

The foundation is unusually strong in several areas:

- Durable stores use atomic writes, explicit recovery gates, and visible save failures.
- Portable chat archives remove provider session IDs, live approval state, attachment contents, and hidden reasoning.
- Local-only routing fails closed at send time, and the UI describes the harness sandbox as write containment rather than confidentiality.
- Codex uses the structured app-server thread/turn protocol, while ACP/RPC integrations normalize a useful subset of provider activity.
- Self-edit changes are previewed, reviewed, persisted, and rollback-aware instead of being applied directly from model prose.
- Core behavior has substantial deterministic coverage, including persistence failure and recovery paths.

The following findings should be resolved before adding more autonomous behavior. Priorities describe product risk, not implementation size.

| Priority | Finding | Why it matters | Relevant code | Required direction |
| --- | --- | --- | --- | --- |
| P0 | Codex models are still invented when discovery is missing. | A hard-coded fallback can present or run an unavailable model, conflicts with runtime discovery, and will age immediately as the catalog changes. | `AppState.swift` initialization, `BackendAvailabilityPolicy.swift`, and model-less portable archive imports in `SessionPortableArchive.swift` | Represent catalog state explicitly as loading, available, unavailable, or failed. Do not create a runnable Codex backend until the provider reports a model. Preserve an imported unknown model only as unavailable provenance. |
| P0 | Workspace scope can fail open when Codex omits path metadata. | Missing `grantRoot` currently becomes workspace-scoped, and an empty file-change path list also evaluates as scoped. Smart mode can then approve from incomplete evidence. | `CodexExecHarness.appServerPermissionRequest`, `CodexExecHarness.appServerEvent`, and automatic approval in `AppState.apply` | Treat missing, empty, malformed, or unresolved paths as outside/unknown scope and require approval. Put scope classification in a tested `LatticeCore` type shared by every harness. |
| P0 | Lattice policy is advisory for some provider-owned execution. | `LocalToolBroker` is tested but not on the live provider path. Codex YOLO maps directly to `never` plus `danger-full-access`, so Lattice cannot honestly claim a universal credential or irreversible-action boundary for provider-executed tools. | `ToolBrokerRuntime.swift`, `CodexExecHarness.executionRoute`, and the direct harness dispatch in `AppState.startRun` | Add a capability matrix that states which controls each harness can enforce. Only promise broker-enforced policy for actions that actually cross the broker; show provider-owned gaps before a run. |
| P1 | Foreground run presentation is shared across concurrent sessions. | A background session finishing can clear activity, composer progress, errors, and overlay state belonging to the selected session. This blocks trustworthy multi-agent work. | Global run presentation fields and terminal-event handling in `AppState.apply` | Introduce per-session `RunState` owned by a run coordinator. Derive the selected UI from that state and test interleaved completion, cancellation, approval, and failure. |
| P1 | Provider subprocesses are inconsistently bounded. | Several auth, catalog, version, and update paths can wait forever or capture unbounded output even though `BoundedSubprocess` exists. | Raw `Process` helpers across `CodexExecHarness`, `StructuredCLIHarness`, `AntigravityCLIHarness`, `PiRPCHarness`, and `AppState` | Route all finite commands through one bounded supervisor with deadlines, output caps, cancellation, typed outcomes, and safe error summaries. Add provider-event fixtures for long-running interactive streams. |
| P1 | Harness event semantics are too lossy for a control plane. | Tool completion is inferred from display strings, reversibility is often guessed, and provider-specific fields are discarded. This weakens auditability and future replay. | `AgentEvent`, `HarnessToolEventDecoder`, `CodexExecHarness.appServerEvent`, and `AppState.apply` | Define a versioned event envelope with provider event ID, run ID, timestamps, typed lifecycle/status, scope evidence, approval provenance, and redacted payload summary. Preserve unknown events as inspectable records. |
| P1 | The 5,000-line `AppState` is the orchestration, persistence, provider, extension, and presentation layer at once. | It is difficult to inject failures, test concurrent workflows, or evolve multi-agent orchestration without UI regressions. | `Sources/Lattice/AppState.swift` | Extract `RunCoordinator`, `ConnectionCatalog`, `SessionRepository`, `ExtensionManager`, and small MainActor presentation stores behind protocols in `LatticeCore`. Migrate behavior with characterization tests. |
| P2 | Context compaction is character-count truncation rather than a durable semantic artifact. | It is deterministic and honest, but loses decisions and evidence in long-running work and cannot be inspected or corrected independently. | `ContextBudget.swift` | Add versioned, user-visible context checkpoints containing decisions, constraints, unresolved questions, file references, and source message IDs. Keep deterministic truncation as the failure fallback. |
| P2 | The most ambitious extension operations are review-only. | Model recommendations, harness routes, and automations can be proposed but do not have typed, enforceable runtimes. | `LatticeExtensionOperationRuntimePolicy` | Implement one typed operation at a time with manifest validation, permission review, dry-run preview, atomic apply, rollback, and tests. Never execute arbitrary extension entrypoints merely because a model generated them. |
| P2 | Tests do not yet exercise the product's highest-risk orchestration boundary. | Core policy is well covered, but there is no deterministic end-to-end replay of interleaved app-server events through session state and UI-derived state. | `Tests/LatticeCoreTests` and the untested `AppState` event loop | Add protocol record/replay fixtures, run-state reducer tests, malformed-event tests, and a small UI smoke suite for approval, recovery, and concurrent-run flows. |

P0 implementation update (reviewed and committed 2026-07-14):

- Codex no longer receives an invented runnable model when discovery is missing; unknown imports preserve model provenance without bypassing the runtime catalog gate.
- Workspace scope classification is shared across harnesses and fails closed for missing, malformed, unresolved, symlink-escaped, and empty path evidence.
- A deterministic per-route capability matrix now drives Inspector and connection disclosures, including broker mediation, write containment, approvals, read/network limits, credential claims, and lifecycle support.

These immediate P0 repairs are now represented by dated commits in the feature log. Later Build Week work should extend them rather than weakening their runtime-discovery, scope-evidence, or capability-disclosure guarantees.

## Build Week implementation sequence

The sequence is intentionally safety-first. Later milestones depend on the earlier control-plane work and should not be pulled forward just to make a more dramatic demo.

### 1. Truthful route and capability inventory

Make every engine/harness tuple report discovered model availability and enforceable capabilities: structured events, resumable sessions, cancellation, workspace-write containment, approval forwarding, broker mediation, network control, and authentication state.

Acceptance criteria:

- No code path creates a runnable model ID that the active provider did not report.
- Unknown and failed catalogs have distinct, actionable UI states.
- A route cannot be described as broker-controlled when execution bypasses the broker.
- Local-only and unavailable-route tests cover first run, continuation, import, catalog failure, and recovery.

#### Code, Work, and Local runtime boundary

New chats now use an explicit mode and discovered execution route. Direct Codex and OpenCode harnesses remain available only to persisted legacy chats; Lattice does not silently remap them.

| Mode and provider | Runtime | Lattice instructions | Tools and important boundary |
| --- | --- | --- | --- |
| Code · Codex | Pi RPC in an isolated Lattice profile | Versioned envelope applied at Pi's system-instruction extension boundary | Pi tools remain provider-owned; Lattice adds permission events and macOS write containment, not read/network confidentiality. |
| Code · OpenCode Go/Zen | Pi RPC with a mode-consented Keychain key in child environment | Same system-level Lattice envelope | Credential never enters argv, events, or session persistence; Code and Work consent and validation are independent. |
| Code · Grok | Grok Build ACP | Clearly labeled visible “Lattice task context,” not described as a system prompt | Grok owns its tools, login, plugins, and hooks. |
| Code · Antigravity | Antigravity CLI | Clearly labeled visible “Lattice task context,” not described as a system prompt | Current transcript transport cannot promise structured tool events, resume, or injected tools. |
| Work · Codex / Grok / OpenCode | Unmodified Hermes ACP in an isolated Lattice profile | Versioned envelope rendered into Lattice-owned `SOUL.md` and configuration | Curated browser, computer-use, web, file, and terminal toolsets; messaging, scheduling, credential, financial, and externally consequential categories remain disabled. Hermes tools are not broker-mediated. |
| Local · Apple Intelligence | Foundation Models | Native Lattice instructions | On-device model; no external tool harness. |
| Local · Ollama | Local HTTP/NDJSON | Visible transcript only | No tool loop or claimed system-role control. |

The user always chooses Code, Work, or Local and then a discovered model. Lattice never automatically crosses modes, providers, runtimes, or models. Runtime components are shown only under collapsed diagnostics/setup; Pi and Hermes are not presented as model providers.

### 2. Durable run ledger and protocol replay

Turn normalized harness traffic into an append-only per-run ledger. The visible timeline should be derived from structured events rather than transient global UI flags. Add sanitized protocol fixtures so a run can be replayed without provider credentials.

Acceptance criteria:

- Two sessions can stream, request approval, finish, fail, and cancel in any interleaving without changing each other's visible state.
- Every approval records the requested action, scope evidence, applicable policy, available options, user or automatic decision, and provider acknowledgement.
- Unknown provider events remain visible and do not crash or silently complete a run.
- Replay produces the same terminal session state deterministically.

### 3. Flagship: Inspectable Agent Mission

Add a project-scoped mission above individual chats. A developer provides an outcome and constraints; Lattice creates a reviewable plan, lets the user choose which independent steps may run in parallel, and tracks each agent thread as a child run. Write-capable workers receive separate worktrees or otherwise non-overlapping write scopes. A lead run integrates results only after tests and an independent review gate.

The first version should be deliberately small:

1. One repository and one explicit goal.
2. A provider-generated plan represented as editable typed steps, not opaque prose, using the model and route explicitly selected by the user.
3. At most three user-approved child runs with declared read/write scope and budget.
4. Structured live status, approvals, diffs, tests, and failures for each child.
5. An independent reviewer run that cannot silently edit the implementation.
6. A final evidence bundle containing plan revisions, changed files, commands/tests, unresolved risks, model/harness provenance, and the human acceptance decision.

During Build Week, GPT-5.6 and Codex can help design, implement, and review this feature. Inside Lattice, runtime model choice remains user-controlled and based only on models actually exposed by the selected provider. Lattice must not silently change models or reasoning effort to optimize cost.

### 4. Reviewable context checkpoints

Let the user-selected capable model propose structured checkpoints for long missions: goals, constraints, accepted decisions, rejected alternatives, current file state, pending approvals, unresolved questions, and cited source message/action IDs. The user can inspect, edit, or reject a checkpoint before it replaces older visible context in a provider handoff.

Acceptance criteria:

- The original transcript remains durable and exportable; a checkpoint never rewrites history.
- Every summarized claim points to visible source IDs.
- If summarization fails, exceeds budget, or is unavailable in local-only mode, deterministic truncation remains the truthful fallback.
- Hidden chain-of-thought is neither requested nor persisted; only provider-supported user-visible reasoning summaries may enter the ledger.

### 5. Verified self-edit operations

Use the existing self-map, preview, and rollback foundation to ship one real typed extension operation. The best first candidate is a model recommendation rule because it can remain deterministic: the selected model proposes constraints and explanatory copy, while `LatticeCore` validates and executes a bounded rule over the runtime-discovered catalog.

Do not begin with arbitrary code execution or a general automation entrypoint. Harness routes should require a signed/locally trusted adapter contract, and automations should require a separate scheduler, permission, and observability design.

### 6. Evaluation and release evidence

Create a checked-in, secret-free scenario suite for the flagship mission:

- catalog unavailable and later recovered;
- local-only request with only cloud routes available;
- incomplete or malicious path metadata;
- approval accepted, denied, stale, and cancelled;
- one child agent fails while another succeeds;
- conflicting edits are detected before integration;
- provider process hangs or exceeds its output limit;
- app relaunch during an active or waiting run;
- reduced-motion and keyboard-only approval flow;
- final review finds an actionable issue and sends the mission back for repair.

The demo should use the same scenario vocabulary as the tests and show one recovery path, not only a happy path.

## How GPT-5.6 is used for Build Week

The 2026-07-14 review and integration task used GPT-5.6 Luna in Codex, with high or xhigh reasoning for scoped implementation and independent review agents. The work used those sessions to understand Lattice, implement isolated fixes, reconcile overlapping worktrees, and verify the real app. GPT-5.6 use is part of how Lattice is built, not a product requirement imposed on Lattice users. The primary Codex `/feedback` identifier still needs to be captured for the submission; this log does not invent one.

Implementation rules:

- Use GPT-5.6 in the actual Codex development session when available; never add a fallback slug or product configuration merely to claim usage.
- Record the actual Codex session evidence, selected model evidence, date, commit, and verification for each meaningful Build Week feature.
- Keep Lattice runtime behavior model-agnostic: discover provider models at runtime and preserve explicit user model and reasoning choices.
- Treat model plans, risk classifications, summaries, and reviews as proposals until deterministic checks or a human decision accepts them.
- Give reviewers read-only or isolated scope by default. A reviewer finding is evidence, not an automatic permission to modify code.
- Bound parallelism, token use, subprocess time, output, and workspace scope explicitly.
- Keep provider transcripts and credentials out of the repository and Build Week evidence.
- Re-check current official guidance when implementation begins. Useful starting points are the [OpenAI model catalog](https://developers.openai.com/api/docs/models), [Codex app-server documentation](https://developers.openai.com/codex/app-server), and [Codex multi-agent guidance](https://developers.openai.com/codex/multi-agent).

## Explicit non-goals for Build Week

- A provider-independent claim that Lattice can prevent reads, network access, prompt injection, or exfiltration.
- Silent cloud fallback from local-only mode.
- A hard-coded GPT-5.6 option when the active account or Codex surface does not expose it.
- Fully autonomous merges, pushes, releases, purchases, credential access, or external side effects.
- Terminal scraping when a structured provider protocol is available.
- Storing hidden reasoning or presenting a generated summary as a verbatim provider trace.
- Executing generated extension code without a typed contract, review, containment, and rollback path.

## Recording a feature

For each substantial Build Week feature, record:

- The developer problem and intended outcome.
- The dated commit or pull request.
- The Codex `/feedback` session ID when available.
- How GPT-5.6 and Codex contributed.
- The important product, engineering, and design decisions made by the human author.
- Automated and manual verification performed.

Do not include prompts, transcripts, or identifiers that contain secrets or private user data.

## Feature log

| Date | Feature | Commit / PR | Codex session | GPT-5.6 contribution | Human decisions | Verification |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-07-13 | Initial open-source foundation | Initial release | Add after `/feedback` | Repository preparation and verification | Product scope, safety boundaries, MIT licensing, and public positioning | Core tests and packaged-app verification |
| 2026-07-14 | Review-driven reliability, safety, usability, and accessibility baseline | `f828353`, `f72050d`, `e40c182`, `4fc50e4` | Current Codex desktop task; `/feedback` ID pending | GPT-5.6 Luna review tasks created isolated fixer work, then the lead task reconciled the results and audited the combined branch. | Fix every review finding, keep provider behavior truthful, preserve accessibility and reduced-motion behavior, and retain reviewable commits rather than flattening the history. | Combined source/test parsing passed; final fallback run at `7032a63` passed 810 checks. |
| 2026-07-14 | Truthful routes, catalog refreshes, and local-model discovery | `cb0ccf8`, `a474d72`, `228ef94` | Current Codex desktop task; `/feedback` ID pending | GPT-5.6 Luna compared competing review branches, retained the stricter route/scope policy, added refresh generations, and reviewed partial Ollama discovery. | Runtime-discovered models only; stale refreshes cannot publish; any incomplete Ollama capability scan is non-authoritative and visible as failed. | Focused tests and typechecks passed; fallback inventory includes the new refresh and Ollama cases; 810-check fallback passed at `7032a63`. |
| 2026-07-14 | Bounded interactive provider lifecycle and run ownership | `944b97c`, `db9aa60`, `b438964`, `7032a63` | Current Codex desktop task; `/feedback` ID pending | GPT-5.6 Luna implemented and independently re-reviewed pipe ownership, process groups, output limits, serialized writes, permission handoff, replacement-run ownership, and cancellation races. | Never let stale teardown cancel a replacement run; allow only final cancellation control frames during grace; keep time, output, workspace, and permission bounds explicit. | Core/app typechecks and live transport probes passed; fallback verifier passed 810 checks; native Swift Testing was unavailable on this Command Line Tools installation. |
| 2026-07-14 | Validated ACP stale-session recovery | `638079e` | Current Codex desktop task; `/feedback` ID pending | GPT-5.6 Luna traced recovery and persistence ordering across the ACP harness, event domain, and AppState transcript handoff. | Recover only from explicit stale-session rejection; require a bounded visible-transcript handoff; persist a replacement ID only after model validation and successful prompt response. | Focused recovery tests and full source parsing passed; packaged app verification passed; fallback verifier passed at `7032a63`. |
| 2026-07-14 | Integrated UI and verification repair | `5724576`, `2eecbd1` | Current Codex desktop task; `/feedback` ID pending | GPT-5.6 Luna reviewed the merged UI for contradictory catalog and scroll accessibility states and repaired fallback parity. | Use human-readable VoiceOver state, distinguish hidden from undiscovered models, and keep verification claims tied to observed results. | Real app built and packaged successfully; bundle structure and arm64 executable verification passed. |
| 2026-07-14 | Bounded slash commands and usable chat inspector | `9652a7d`, `d9752b3` | Current Codex desktop task; `/feedback` ID pending | GPT-5.6 traced the slash-only layout collapse and reshaped the inspector around the information hierarchy. | Keep the transcript visible, preserve every searchable command, widen the inspector, and collapse secondary safety/usage detail without hiding warnings. | Fallback verifier passed 812 checks; the manually compiled app packaged and verified successfully. |
| 2026-07-14 | Local-first Models and provider-owned Connections | `178d74b`, `a129fb3`, `58b357f` | Current Codex desktop task; `/feedback` ID pending | GPT-5.6 separated local model discovery from provider setup and implemented the bounded Ollama delete flow with failure tests. | Models launches new local chats and manages local storage; Connections owns provider authentication, harnesses, and cloud model visibility; deletion always asks first and never removes chat history. | Two Ollama deletion tests added; fallback verifier passed 814 checks; app compilation, packaging, and bundle verification passed. |
| 2026-07-14 | Explicit Code, Work, and Local modes | `33a5dac` through `110eb27` | Current Codex desktop task; `/feedback` ID pending | Eight planned GPT-5.6 Luna roles implemented and reviewed route architecture, Pi Code, Hermes Work, readiness, mode UI, compatibility, and integration boundaries in isolated worktrees. The final Luna xhigh audit found five actionable runtime/authentication issues; the parent repaired all five and an additional refresh/validation completion race. | User-selected modes only; Pi and Hermes stay hidden as implementation runtimes; no forks, cross-mode fallback, ambient credentials, provider-session copying, Grok subagents, or Sol subagents. The Keychain-to-auth-file bridge is exposed only inside a selected persisted direct OpenCode compatibility chat, never to new Pi/Hermes routes. | 843 deterministic fallback checks passed; 38 native test files / 422 declarations were inventoried but not executed; packaged arm64 app verification passed. Real-app Code/Work/Local interaction QA remains required before merge because the macOS UI session was locked during the final run. |

## Submission checklist

- [ ] Every submitted feature is represented by a dated commit.
- [ ] The primary Codex `/feedback` session ID is recorded in the Devpost submission.
- [ ] The README and demo distinguish working behavior from roadmap items.
- [ ] The demo audio explains how both Codex and GPT-5.6 were used.
- [ ] Setup, supported platforms, and judge testing instructions are current.
- [ ] A test build or other no-rebuild judging path is available.
- [ ] The public repository contains no credentials, private transcripts, or generated local state.
- [ ] Tests and release checks pass at the submitted commit.
