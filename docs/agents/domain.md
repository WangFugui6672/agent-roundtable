# Domain Docs

This repository uses a single-context domain documentation layout.

## Before exploring

Read:

- `GLOSSARY.md` at the repository root.
- Any ADRs under `docs/adr/` that touch the area being changed.

If `docs/adr/` does not exist, proceed silently.

## Vocabulary

Issue titles, PR descriptions, test names, design documents, and code identifiers must use the canonical terms defined in `GLOSSARY.md`.

If a required concept is missing from the glossary, treat it as a domain-modeling gap rather than silently inventing a synonym.

## Architecture decisions

Record durable, hard-to-reverse decisions under `docs/adr/` only when the decision:

- Is costly to reverse.
- Would surprise a future reader without context.
- Resulted from a real trade-off.

Current product and scope decisions are captured in `docs/PRD.md` until they become stable enough to promote to ADRs.

