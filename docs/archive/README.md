# Archived mechanism documents

Superseded DESIGN documents, kept whole as history. Each file here is the text of the top-level
document as it stood on main at 65cf2980 (2026-11-01); the top-level path keeps a stub that says
where the decisions now live. Nothing in this directory is a contract: the ADRs are
(`docs/ADR-README.md`), and they were not trimmed - `docs/ADR-capture.md` and its siblings carry
every decision in full. The cross-cutting index is `docs/ADR-graphics.md`.

| file | original | why it is here |
|---|---|---|
| `DESIGN-rest-zero-capture.md` | `docs/DESIGN-rest-zero-capture.md` | the staged rest-zero design; decided in `docs/ADR-capture.md` §14, §18, §20 and §32 (the deaf ladder and the relay it describes were changed by §32) |
| `DESIGN-toast-bridge.md` | `docs/DESIGN-toast-bridge.md` | the bridge's mechanism and option history; decided in `docs/ADR-toasts.md` |
| `DESIGN-p3-classifier-impl.md` | `docs/DESIGN-p3-classifier-impl.md` | the classifier's implementation notes; decided in `docs/ADR-toasts.md` §2 and §8 |
| `DESIGN-nonseamless-buildout.md` | `docs/DESIGN-nonseamless-buildout.md` | the non-seamless workstream notes; the decision is `docs/ADR-windows.md` §5 |

Code and findings that cite one of these documents by its old path and section (for example
`docs/DESIGN-rest-zero-capture.md C`) resolve through the stub to the copy here; the section
letters and numbers inside each copy are unchanged.
