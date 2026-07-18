# Agent operating contract

This repository is the active home of the Neovim configuration. Current code,
tests, and typed knowledge records are authoritative for behavior and design.

## Hard invariants

- Only folding may change displayed source-row identity. Every non-folding
  transform preserves one displayed row per source row so navigation, debugging,
  diagnostics, and line numbers remain stable.
- The C/C++/CUDA frontend is presentation-only. Do not rewrite source-buffer bytes
  merely to obtain a visual spelling.
- Within a source row, conceal, virtual text, highlighting, alignment, and token
  reordering may be aggressive.
- User-visible frontend behavior requires deterministic headless interaction
  coverage. A static render assertion is insufficient when behavior depends on
  cursor position, mode, selection, viewport, edits, or module toggles.

## Knowledge workflow

- Canonical project knowledge will live under `knowledge/`; generated indexes are
  views, never independent sources of truth.
- Record verified facts, invariants, decisions, components, incidents, and open
  questions as typed records with provenance and explicit relationships.
- Supersede obsolete records; do not silently rewrite history into apparent
  consensus.
- Code comments are implementation evidence, not automatically authoritative
  design documentation.
- `knowledge/README.md` defines the factbase mechanics. Behavior and decisions
  belong in typed records, not only in an implementation comment or a chat turn.
- A visual-language choice must preserve the compared alternatives as validated
  buffer-local profiles and record the selected catalog hash when practical.

## Visual decision workflow

- Use `tools/style_lab serve --wait` when the owner must judge actual appearance.
  It renders through Neovim's embedded `ext_linegrid`, not a handwritten HTML
  approximation, and persists the result in `style_lab/selections.json`.
- Choices and scenes live in `style_lab/catalog.json`. External micro-excerpts
  require a pinned revision, direct source URL, license, and any adaptation note.
- A production buffer uses `style.lua` defaults. Experimental alternatives are
  buffer-local scratch profiles; never mutate process-global renderer functions
  to obtain a comparison.
- The browser may fit a code panel down to 80% of its normal font size. If it
  still overflows, preserve full size and horizontal scrolling. Ensure capture
  width contains the complete row before browser layout.

## Required agent workflow

1. Read this file.
2. Retrieve task context with `tools/knowledge query "<task in plain language>"
   --semantic`. The command always includes accepted invariants unless explicitly
   disabled. If the disposable semantic environment is absent, run
   `python3 tools/bootstrap_knowledge.py`; lexical retrieval works without it.
3. Verify retrieved claims against their evidence before changing behavior.
4. Run focused specs during work and `python3 tools/run_tests.py` before handoff.
5. When behavior or architecture changes, update canonical records, run
   `tools/knowledge validate`, `tools/knowledge build`, and both retrieval
   evaluations (`tools/knowledge eval --limit 5` and
   `tools/knowledge eval --semantic --limit 5`).
6. For a style-lab change, run `python3 tools/run_tests.py style_lab`; for a
   character-changing renderer, add or extend the interaction round-trip matrix.

Routine test output is disposable. Preserve fixtures and assertions, not logs.
