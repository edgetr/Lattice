# Contributing to Lattice

Thank you for helping build Lattice. Contributions should preserve its central promise: powerful agent workflows with explicit user control and truthful system behavior.

## Set up

Requirements and build instructions are in [README.md](README.md). For the standard verification path, run:

```bash
./script/build_and_run.sh --test
./script/build_and_run.sh --verify
```

## Before opening a pull request

- Keep the change focused and explain the user problem it solves.
- Add or update tests for behavioral changes.
- Verify error and unavailable states, not only success paths.
- Update documentation when setup, security boundaries, or user-visible behavior changes.
- Do not include credentials, personal data, provider sessions, generated apps, or build caches.
- Confirm that any new dependency is necessary and license-compatible with MIT distribution.

For UI changes, include screenshots or a short recording and describe keyboard, accessibility, and reduced-motion behavior where relevant.

## Commit and pull-request guidance

Use concise, imperative commit subjects. Pull requests should describe:

1. The problem and intended user outcome.
2. The implementation and important tradeoffs.
3. Safety, privacy, or compatibility implications.
4. Tests and manual verification performed.

By contributing, you agree that your contribution is licensed under the repository's MIT License.
