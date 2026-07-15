# Session outbox and fast-switch source comparison

Research date: 2026-07-15. This comparison uses current upstream source, documentation, and releases rather than product copy. No upstream source or branding is copied into Lattice.

## Reproducible source context

- T3 Code primary repository `main`: [`3513fa04fbf12c1d4fa2b8d07cfc7f0905714d31`](https://github.com/pingdotgg/t3code/commit/3513fa04fbf12c1d4fa2b8d07cfc7f0905714d31), authored 2026-07-14, also tagged [`v0.0.29-nightly.20260714.809`](https://github.com/pingdotgg/t3code/releases/tag/v0.0.29-nightly.20260714.809). Latest stable observed in that checkout: [`v0.0.28`](https://github.com/pingdotgg/t3code/releases/tag/v0.0.28).
- OpenCode primary repository `dev`: [`571e7b852f82415faf65466e1536357a048bdf5a`](https://github.com/anomalyco/opencode/commit/571e7b852f82415faf65466e1536357a048bdf5a), authored 2026-07-14 UTC. Latest release observed: [`v1.18.1`](https://github.com/anomalyco/opencode/releases/tag/v1.18.1).
- Lattice comparison baseline: local `main` commit `5a8ee3d`. The baseline already had split transcript storage, asynchronous generation-guarded hydration, a three-transcript LRU, bounded render windows, per-session drafts, and persisted text-only queued follow-ups.

## T3 Code findings

T3's strongest relevant implementation is the mobile outbox, not its desktop/web composer:

- Each queued message is written to its own durable JSON file before it is published in memory, then removed only after delivery: [`thread-outbox-storage.ts`](https://github.com/pingdotgg/t3code/blob/3513fa04fbf12c1d4fa2b8d07cfc7f0905714d31/apps/mobile/src/state/thread-outbox-storage.ts).
- Mutations are serialized, messages are deduplicated by ID, delivery is FIFO per environment and thread, and a failed remove does not silently erase the in-memory item: [`thread-outbox-manager.ts`](https://github.com/pingdotgg/t3code/blob/3513fa04fbf12c1d4fa2b8d07cfc7f0905714d31/apps/mobile/src/state/thread-outbox-manager.ts) and [`thread-outbox.test.ts`](https://github.com/pingdotgg/t3code/blob/3513fa04fbf12c1d4fa2b8d07cfc7f0905714d31/apps/mobile/src/state/thread-outbox.test.ts).
- The payload snapshots stable command/message IDs, environment/thread, text and attachments, model/runtime/interaction, and creation workspace settings: [`thread-outbox-model.ts`](https://github.com/pingdotgg/t3code/blob/3513fa04fbf12c1d4fa2b8d07cfc7f0905714d31/apps/mobile/src/state/thread-outbox-model.ts).
- Drain waits for connectivity and an idle thread, reuses stable command IDs, and applies bounded exponential retry: [`use-thread-outbox-drain.ts`](https://github.com/pingdotgg/t3code/blob/3513fa04fbf12c1d4fa2b8d07cfc7f0905714d31/apps/mobile/src/state/use-thread-outbox-drain.ts).
- T3 can deduplicate end to end because its server persists command receipts: [`OrchestrationEngine.ts`](https://github.com/pingdotgg/t3code/blob/3513fa04fbf12c1d4fa2b8d07cfc7f0905714d31/apps/server/src/orchestration/Services/OrchestrationEngine.ts). Lattice's provider-owned harnesses do not share that receipt layer, so Lattice must claim exactly-once **local dequeue**, never exactly-once provider execution.

T3 gaps that Lattice should improve rather than copy: retry state/backoff is not a durable user-visible lifecycle; deterministic failures can discard an item; and queued context can be auto-applied without a material route/workspace/permission recheck.

For switching, T3 persists thread-detail snapshots with sequence-aware replay, exposes granular memoized projections with idle retention, and scopes drafts by environment and thread: [`threads.ts`](https://github.com/pingdotgg/t3code/blob/3513fa04fbf12c1d4fa2b8d07cfc7f0905714d31/packages/client-runtime/src/state/threads.ts), [`threadDetail.ts`](https://github.com/pingdotgg/t3code/blob/3513fa04fbf12c1d4fa2b8d07cfc7f0905714d31/packages/client-runtime/src/state/threadDetail.ts), [`threadRetention.ts`](https://github.com/pingdotgg/t3code/blob/3513fa04fbf12c1d4fa2b8d07cfc7f0905714d31/packages/client-runtime/src/state/threadRetention.ts), and [`composerDraftStore.ts`](https://github.com/pingdotgg/t3code/blob/3513fa04fbf12c1d4fa2b8d07cfc7f0905714d31/apps/web/src/composerDraftStore.ts). Its important anti-stale rule is to take workspace/runtime shell metadata from the live authoritative shell even when cached detail survives longer.

## OpenCode findings

OpenCode provides the clearest desktop follow-up UX:

- A persisted, workspace-scoped store keeps per-session `items`, `failed`, `paused`, and edit state. It sends only the FIFO head when the current session is idle, not blocked, not a child, not paused, and the head has not failed. Success removes the item; failure keeps it and marks its ID: [`session.tsx`](https://github.com/anomalyco/opencode/blob/571e7b852f82415faf65466e1536357a048bdf5a/packages/app/src/pages/session.tsx#L603-L616), [`dispatch logic`](https://github.com/anomalyco/opencode/blob/571e7b852f82415faf65466e1536357a048bdf5a/packages/app/src/pages/session.tsx#L1724-L1833), and [`auto-drain guard`](https://github.com/anomalyco/opencode/blob/571e7b852f82415faf65466e1536357a048bdf5a/packages/app/src/pages/session.tsx#L1949-L1963).
- The dock exposes queued count, Send now, and Edit: [`session-followup-dock.tsx`](https://github.com/anomalyco/opencode/blob/571e7b852f82415faf65466e1536357a048bdf5a/packages/app/src/pages/session/composer/session-followup-dock.tsx#L8-L108).
- Queue capture freezes session, directory, prompt context, agent, model, and variant: [`submit.ts`](https://github.com/anomalyco/opencode/blob/571e7b852f82415faf65466e1536357a048bdf5a/packages/app/src/components/prompt-input/submit.ts#L409-L447).

This is durable FIFO visibility, not exactly-once delivery. An acknowledgement loss can retry with a new message ID, and restart auto-send does not compare a durable route/workspace/permission fingerprint. Lattice therefore borrows the failed/paused FIFO interaction but adds a stable local attempt, durable dispatch claim, restart review, and exact context equality guard.

OpenCode's switching path keeps an LRU of 40 session caches, initially fetches 20 messages, deduplicates inflight loads, uses 15-second freshness, preserves active/attention sessions, and generation-gates stale results: [`server-session.ts`](https://github.com/anomalyco/opencode/blob/571e7b852f82415faf65466e1536357a048bdf5a/packages/app/src/context/server-session.ts#L599-L715) and [`session-cache.ts`](https://github.com/anomalyco/opencode/blob/571e7b852f82415faf65466e1536357a048bdf5a/packages/app/src/context/global-sync/session-cache.ts#L11-L65). Per-session/tab drafts are isolated in [`prompt-state.ts`](https://github.com/anomalyco/opencode/blob/571e7b852f82415faf65466e1536357a048bdf5a/packages/app/src/context/prompt-state.ts#L152-L247). Its Playwright benchmark records cold/hot first-destination, first-correct, and stable-render timings, with review closed and open: [`session-tab-switch-benchmark.spec.ts`](https://github.com/anomalyco/opencode/blob/571e7b852f82415faf65466e1536357a048bdf5a/packages/app/e2e/performance/timeline/session-tab-switch-benchmark.spec.ts#L16-L123).

## Lattice decision

Keep Lattice's existing transcript hydration and draft transition work. Add:

1. A durable, context-bound per-session input outbox with explicit pending, dispatching, blocked, and failed states.
2. A durable local dispatch claim before provider launch; restart never silently replays pending or ambiguous work.
3. Exact equality checks for secret-free route, workspace, policy/privacy, reasoning, provider-credential-injection authority, workspace-instruction trust, and attachment identities. Changed context requires explicit review/retry.
4. FIFO head blocking so a failed or blocked command cannot be skipped by automatic drain.
5. Lightweight cached session projections for navigation, while retaining cancellation and late-result rejection for transcript hydration.
6. Metadata-based route/workspace locking so an unloaded nonempty transcript can never masquerade as a new empty chat.

Provider delivery remains potentially ambiguous across a process crash unless a provider adds idempotency receipts. UI and documentation must continue to describe the guarantee as exactly-once **local dequeue** only.

## Build Week implementation record — 2026-07-15

- **Problem:** text-only queued follow-ups survived normal saves but had no durable delivery lifecycle, captured authority, failure/retry state, or crash-safe local claim. Lazy transcripts also allowed route/workspace controls to briefly treat an unloaded historical chat as empty.
- **GPT-5.6/Codex contribution:** the parent session researched and compared both upstream repositories, mapped Lattice's persistence/hydration boundaries, integrated the state machine and UI, repaired transaction and background-session dispatch issues, ran deterministic/performance checks, and exercised the packaged app with rapid multi-thread switching. Direct `gpt-5.6-luna` agents independently researched T3/OpenCode and performed architecture/final-review passes.
- **Grok contribution:** `grok-4.5` implemented the bounded pure `LatticeCore` outbox model, native tests, and fallback behavioral checks. The parent reviewed every changed path and added application transactions, durable receipts, context trust/canonicalization, recovery, UI, and verified repairs.
- **Product/engineering decisions:** preserve provider-owned harness boundaries; make restart and context changes review-required; keep queued plaintext local in the existing session store; store no credentials/provider sessions/approval choices; retain the existing transcript hydration coordinator; describe only exactly-once local dequeue.
- **Verification:** `./script/build_and_run.sh --test`, `./script/build_and_run.sh --verify`, projection-cache microbenchmark, and packaged-app stress QA across eight 80-message sessions with isolated drafts and pending/blocked/failed outbox fixtures. Exact results are recorded in the feature commit and delivery report.

Latest post-repair evidence: the deterministic fallback reports 1,955 checks, 51 native test files, and 533 Swift Testing declarations; the projection benchmark completed 1,000 refreshes across 200 sessions in 200.76 ms with one ordering rebuild. Packaged-app QA loaded an older outbox context shape successfully, switched 16 forward destinations in 13.38 s and 24 reverse destinations in 19.10 s including accessibility capture, preserved the selected thread's draft, and exposed the expected restart-review and visible failed-detail states. The host does not provide full SwiftPM/Xcode, so native Swift Testing was not executed.
