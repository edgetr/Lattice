# Security Policy

## Supported versions

Lattice is pre-release software. Security fixes are applied to the latest version on the default branch; older snapshots are not currently supported.

## Reporting a vulnerability

Please do not open a public issue for a vulnerability that could expose credentials, user data, arbitrary file writes, or unintended command execution. Instead, use GitHub's private vulnerability reporting feature for `edgetr/Lattice`.

Include the affected version or commit, reproduction steps, impact, and any suggested mitigation. Please avoid accessing data that is not yours and give the project a reasonable opportunity to investigate before public disclosure.

## Security boundaries

Lattice coordinates third-party provider CLIs and local runtimes. Those tools retain their own security models and terms. Lattice's harness sandbox is intended to constrain writes to configured roots where used; it is not a confidentiality boundary and does not generally block reads or network access.
