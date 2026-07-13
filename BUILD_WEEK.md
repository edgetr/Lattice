# OpenAI Build Week development log

This repository is the canonical starting point for Lattice's OpenAI Build Week development. The initial open-source release establishes the working product foundation; subsequent entries should make each meaningful Codex and GPT-5.6 contribution easy to identify and reproduce.

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

## Submission checklist

- [ ] Every submitted feature is represented by a dated commit.
- [ ] The primary Codex `/feedback` session ID is recorded in the Devpost submission.
- [ ] The README and demo distinguish working behavior from roadmap items.
- [ ] The demo audio explains how both Codex and GPT-5.6 were used.
- [ ] Setup, supported platforms, and judge testing instructions are current.
- [ ] A test build or other no-rebuild judging path is available.
- [ ] The public repository contains no credentials, private transcripts, or generated local state.
- [ ] Tests and release checks pass at the submitted commit.
