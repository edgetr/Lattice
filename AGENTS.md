# AGENTS.md

## Mission

Lattice is a native macOS control plane for AI coding agents. Build a dependable daily workspace that unifies structured coding harnesses, local models, provider-owned CLIs, permissions, privacy controls, and durable project conversations without hiding execution details from the user.

## Product priorities

1. Solve real developer workflow problems before adding model-driven novelty.
2. Keep the product runnable, coherent, and honest about unavailable capabilities.
3. Preserve user control over cloud routing, workspace writes, credentials, and irreversible actions.
4. Prefer structured protocols and machine-readable events over terminal scraping.
5. Make important behavior observable through the UI, persisted action trails, and tests.

## Repository map

- `Sources/Lattice/`: SwiftUI application, views, and app state.
- `Sources/LatticeCore/`: domain types, policy, persistence, routing, harnesses, and other testable core behavior.
- `Tests/LatticeCoreTests/`: Swift Testing suites for core behavior.
- `Resources/`: application artwork bundled by the packaging script.
- `script/build_and_run.sh`: canonical build, test, package, and verification entry point.
- `script/verify_core.swift`: verification fallback for machines without full SwiftPM/Xcode support.

## Architecture rules

- Put reusable policy and domain decisions in `LatticeCore`; keep SwiftUI-specific presentation in `Lattice`.
- Keep provider integrations behind the existing harness and interface boundaries.
- Discover provider and model availability at runtime. Do not present hard-coded models as available.
- Missing executables, authentication, models, or protocol support must produce an unavailable or actionable error state, never a simulated completion.
- Treat `Nisa` names as read/migration compatibility only. Do not introduce new public APIs, data paths, defaults, or documentation using the legacy name.
- Avoid broad singletons and hidden global state. Make I/O and policy dependencies injectable when practical.

## Safety and privacy rules

- Never read, print, persist, or commit real API keys, access tokens, provider sessions, user transcripts, or Keychain contents.
- Lattice-owned secrets belong in macOS Keychain, not UserDefaults or JSON stores.
- Keep credentials denied at the tool-broker boundary unless a narrowly reviewed product flow explicitly requires access.
- Describe the harness sandbox as write containment only. Do not claim it prevents reads, network access, prompt injection, or exfiltration.
- Local-only mode must fail closed for cloud-classified routes; never silently reroute a local-only session to cloud execution.
- Preserve explicit approval for actions outside the selected workspace or actions that are irreversible, credential-related, financial, or externally consequential.

## Development workflow

1. Read the relevant implementation and nearby tests before editing.
2. Keep changes scoped; preserve unrelated user work.
3. Add or update tests for behavior changes, including failure and recovery paths.
4. Run the narrowest useful checks while iterating.
5. Before handing off a change, run:

```bash
./script/build_and_run.sh --test
./script/build_and_run.sh --verify
```

Use `./script/build_and_run.sh --release-check` for packaging, distribution, or release-related changes. When UI behavior changes, also build and inspect the real app; automated core tests are not a substitute for visual and interaction QA.

## Build Week and GPT-5.6

- Use GPT-5.6 in Codex for OpenAI Build Week feature work when it is available to the active account and surface.
- Do not add a speculative model slug or project configuration merely to claim GPT-5.6 usage; record the actual Codex session and model evidence used for each meaningful feature.
- Each Build Week feature should have a dated, reviewable commit and tests proportional to its risk.
- For substantial changes, document the problem, the GPT-5.6/Codex contribution, the human product or engineering decisions, and the verification performed.
- Keep the submission narrative problem-first: Lattice exists to reduce fragmented, opaque agent workflows while retaining developer control.

## Coding conventions

- Follow the existing Swift 6 style and prefer small, intention-revealing types.
- Use structured concurrency carefully; avoid blocking cooperative executors.
- Keep UI state mutations on the appropriate actor.
- Prefer deterministic tests and bounded subprocess/network behavior.
- Maintain accessibility labels, values, hints, keyboard behavior, and reduced-motion behavior when changing UI.
- Avoid force unwraps in production paths and avoid swallowing errors that should reach the user.
- Comments should explain constraints or non-obvious intent, not restate code.

## Definition of done

A change is complete when it builds, relevant tests pass, failure behavior is truthful, safety and privacy claims still match reality, user-facing documentation is updated where needed, and the real product flow has been checked in proportion to the change.
