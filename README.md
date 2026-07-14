# Lattice

**A native macOS control plane for AI coding agents.**

Lattice brings coding harnesses, local models, provider-owned CLIs, permissions, privacy controls, and durable project conversations into one coherent SwiftUI workspace. It is designed for developers who want the power of agentic tools without losing visibility into what is running, where data can go, or which actions require approval.

> [!IMPORTANT]
> Lattice is early open-source software. The repository currently produces an unsigned development build for local testing; it is not yet a notarized production release.

## Why Lattice

AI-assisted development is increasingly split across terminal sessions, provider-specific apps, local runtimes, and incompatible approval systems. That fragmentation makes it difficult to preserve context, compare models, understand tool activity, or enforce consistent privacy boundaries.

Lattice is building a single native workspace where developers can:

- Keep project conversations and action history together.
- Connect provider-owned coding harnesses without scraping terminal output.
- Choose between cloud and local execution explicitly.
- Review tool activity and approve consequential actions.
- Discover models based on the providers and runtimes actually available.
- Extend the workspace with user-owned skills and extensions.

## Current capabilities

### Native workspace

- Durable chats with drafts, queues, continuation, branching, editing, deletion, pinning, and search.
- Project-bound working directories and a floating overlay.
- Model and connection management with truthful unavailable states.
- Session import/export with sensitive runtime state removed.
- Recovery surfaces for corrupt or unwritable persistent data.

### Execution routes

Every new chat starts with an explicit user choice:

- **Code** — Build, debug, and ship.
- **Work** — Research, browse, and act.
- **Local** — Private models on this Mac.

The model chooser shows only runtime-discovered models for the selected mode. Lattice never automatically switches modes, providers, runtimes, or models.

| Mode | Provider | Integration |
| --- | --- | --- |
| Code | Codex | Pi RPC with a Lattice system-instruction and permission extension |
| Code | OpenCode Go/Zen | Pi RPC with an explicitly enabled Keychain credential |
| Code | Grok | Grok Build ACP |
| Code | Antigravity | Transcript-driven `agy --print` |
| Work | Codex / Grok / OpenCode | Unmodified Hermes ACP with an isolated Lattice profile and curated toolsets |
| Local | Apple Intelligence | Foundation Models on supported macOS versions |
| Local | Ollama | Local model catalog, pull/install, and streaming chat |

Pi and Hermes are runtime components, not model providers. Their setup and diagnostics live in a collapsed Connections section. Direct Codex app-server and OpenCode ACP remain compatibility routes for existing chats and v1 archives, but are not offered for new chats.

Authentication is runtime-owned and isolated: Pi owns the Code Codex login, while Hermes owns the Work Codex and Grok logins. One OpenCode key may be stored in macOS Keychain, but Code and Work access must be enabled and validated separately. Lattice never copies OAuth sessions between CLIs.

### Safety and privacy

Each session has explicit execution and privacy choices. What they enforce depends on the selected runtime—inspect **Route & safety** in the chat inspector before running:

- **Ask** requests approval for material or non-reversible work when the selected provider protocol can forward permission requests. Antigravity Ask stays plan-only.
- **Smart** may auto-allow scoped reads only after a structured provider request arrives; writes remain approval-gated when reversibility or scope evidence is incomplete.
- **YOLO** is explicitly high-trust and may auto-allow provider permission requests. Legacy direct Codex YOLO uses provider `danger-full-access`. Live provider tools do **not** pass through `LocalToolBroker`.
- **Cloud allowed** permits connected cloud and local routes.
- **Local only** blocks routes classified as cloud and keeps execution on available local backends.

Where Lattice applies `sandbox-exec`, it is a **write-containment control**, not a confidentiality boundary: reads and network remain allowed. Legacy direct Codex sandbox settings are provider-configured, not Lattice `sandbox-exec`. Antigravity only receives a provider sandbox option that Lattice does not independently verify. Local chat has no delegated tool loop. Do not treat Local mode as encryption, YOLO as isolation from secrets, or any route as prompt-injection or exfiltration prevention.

## Requirements

### Run Lattice

- macOS 15 or later
- Apple silicon for the current packaging target
- Optional provider CLIs or local runtimes for the routes you want to use

### Build Lattice

- Swift 6 toolchain
- Xcode 26 or a current Swift 6 toolchain with a complete macOS SDK
- Standard macOS packaging tools used by the build script

## Build and run

Clone the repository and run:

```bash
git clone https://github.com/edgetr/Lattice.git
cd Lattice
./script/build_and_run.sh
```

The packaged development app is written to `dist/Lattice.app` and opened automatically.

Additional build-script actions:

```bash
./script/build_and_run.sh --debug
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
```

## Verify

Use the repository script so SwiftPM and the Command Line Tools fallback follow the same checks:

```bash
# Unit tests, or the core verification fallback
./script/build_and_run.sh --test

# Build and validate the app bundle without launching it
./script/build_and_run.sh --verify

# Tests, bundle verification, and distribution-readiness report
./script/build_and_run.sh --release-check
```

With a full Xcode/SwiftPM environment, you can also run:

```bash
swift test
swift build
```

Provider credentials are not required for core verification.

## Data locations

Lattice stores product data under:

```text
~/Library/Application Support/Lattice/
```

Notable data includes durable sessions, user-managed extensions and skills, and compatible harness session state. Secrets managed directly by Lattice use macOS Keychain. Provider CLIs retain their own credential stores and terms.

Legacy `Nisa` identifiers exist only to migrate data created before the Lattice name. New product data and public interfaces should use `Lattice` naming.

## Project structure

```text
Package.swift                 Swift package definition
Sources/Lattice/              SwiftUI application target
Sources/LatticeCore/          Domain, policy, persistence, and harness logic
Tests/LatticeCoreTests/       Swift Testing coverage
Resources/                    Application artwork
script/build_and_run.sh       Build, test, package, and verification entry point
script/verify_core.swift      Command Line Tools verification fallback
AGENTS.md                     Repository guidance for coding agents
BUILD_WEEK.md                 Build Week contribution and evidence log
```

## Development principles

- Unavailable providers must remain visibly unavailable; never simulate success.
- Prefer structured provider protocols over terminal scraping.
- Keep permission, privacy, and sandbox claims narrower than the implementation.
- Never commit credentials, provider sessions, user transcripts, or generated build products.
- Preserve user control over consequential actions and cloud routing.
- Keep core policy testable without provider accounts.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow and [SECURITY.md](SECURITY.md) for responsible vulnerability reporting.

## Roadmap

Lattice is moving toward a dependable daily workspace for multi-agent software development. Near-term work includes deeper structured harness integrations, clearer cross-agent planning and review, richer extension APIs, improved onboarding, broader accessibility coverage, and a signed/notarized distribution path.

## OpenAI Build Week

Lattice is being developed during OpenAI Build Week with Codex and GPT-5.6. Build Week contributions will be kept in dated commits and documented in the repository so the role of Codex, GPT-5.6, and human product decisions remains clear.

The running contribution record and submission checklist live in [BUILD_WEEK.md](BUILD_WEEK.md).

## License

Lattice is available under the [MIT License](LICENSE).
