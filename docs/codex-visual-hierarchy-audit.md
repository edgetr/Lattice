# Codex visual hierarchy audit for Lattice

Date: 2026-07-15

## Scope and method

This is a behavioral and visual-structure study of the installed Codex macOS app. It does not copy proprietary assets, exact measurements, source code, or branding. Evidence came from direct inspection of the live app at its regular workspace size, its accessibility hierarchy, and its sidebar and auxiliary-panel disclosure states.

## Observed evidence

- The transcript is the dominant reading surface. It has a constrained line length, generous vertical rhythm, and no enclosing card.
- Navigation is persistent but visually quiet. Sidebar rows use a single low-contrast selected fill; project and task actions are secondary to labels and appear as compact contextual controls.
- The top bar holds a short set of icon-led actions. Labels remain available to accessibility and help text instead of competing visually with the task title.
- The composer is the strongest floating surface. Route/access controls live inside or immediately beside it, while the transcript remains visually flat.
- Environment and source information is grouped in one auxiliary region. Opening the tool launcher replaces that region instead of nesting another panel over it.
- Long operational detail is progressively disclosed. Command runs, changed files, sources, and utility tools begin as summary rows or buttons.
- Muted semantic color carries most hierarchy. Accent color is reserved for focus, current state, warnings, and primary action feedback.
- Compact rows reflow or truncate secondary text while keeping the primary label and control target intact.

## Principles responsibly applied to Lattice

1. Preserve one dominant content plane. Transcript and catalog content should not sit inside multiple glass layers.
2. Reserve glass for chrome, floating controls, and overlays. Dense information uses quiet opaque semantic surfaces.
3. Keep primary actions visible and move global secondary actions into a clearly labeled overflow menu.
4. Use one selection signal at a time: a native selected row fill plus explicit accessibility state.
5. Prefer progressive disclosure for workspace, context, harness capability, and runtime detail while keeping safety-critical route and privacy controls visible.
6. Constrain reading width on wide windows; reduce margins and stack controls at narrow widths rather than compressing labels.
7. Keep status truthful in plain language. Color and symbols reinforce text but never replace it.
8. Respect Reduce Motion, Reduce Transparency, increased contrast, keyboard focus, native menus, and minimum interaction targets.

## Lattice identity retained

Lattice keeps its native SwiftUI structure, semantic system colors, SF Symbols, companion identity, route terminology, and explicit privacy/approval language. The cleanup borrows interaction principles—not Codex artwork, typography assets, colors, or a pixel layout.

## Responsive acceptance checks

- Narrow: 640 pt content region uses 16 pt side insets and a single-column card layout; provider readiness badges stack before they clip.
- Regular: 900 pt content region uses 24 pt side insets and keeps a readable 852 pt maximum content region.
- Wide: content caps at 1,280 pt; multi-card and side-by-side layouts activate only when their minimum widths fit.
- Unknown first layout: a stable 900 pt fallback prevents a transient zero-width or over-expanded page.
