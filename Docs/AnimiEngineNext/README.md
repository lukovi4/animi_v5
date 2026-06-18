# AnimiEngineNext Architecture Packet

Status: **FOUNDATION APPROVED - Task 001 planning authorized**

This folder defines the proposed architecture and validation process for a new
video engine built alongside the current product.

## Governing rule

No technical proposal in this folder becomes a final decision until the product
owner approves it. Items that depend on device behavior are approved only after
reproducible tests and recorded results.

## Source material

- `Docs/Animi - Canonical System Specification.docx`
- `Docs/deep-research-report.md`
- `Docs/deep-research-report_v2.md`
- Current project and template formats
- Current real templates under `SceneSources/`
- Product-owner decisions recorded in `decision-register.md`

## Documents

- `architecture-proposal.md` - proposed system boundaries, modules and flows.
- `validation-contract.md` - required tests, measurements, logs and evidence.
- `decision-register.md` - approved, pending and benchmark-dependent decisions.
- `source-traceability.md` - source-to-requirement and gap mapping.
- `approval-request.md` - short owner approval packet in plain language.
- `claude-task-001-proposal.md` - first proposed task for Claude Code.

## Current gate

Claude Code may plan Task 001. It must not write code until its plan and exact
file list are reviewed. Media-engine functionality remains unauthorized.

## Task 003 status (closed through §17 step 18)

Task 003 (the `AnimiEngineNext` render path) is implemented and verified through guarded reference
promotion. See `claude-task-003-implementation-report.md` for the full record. Key invariants now in force:

- **Reference promotion policy** — approved references are created ONLY by the guarded `ReferencePromoter`,
  ONLY from a single owner-approved sealed run, promoting that run's candidate **bytes** into
  `AnimiEngineNext/ReferenceData/` + an auditable `approval-manifest.json`. Promotion is transactional,
  **git-reversible**, and never auto-commits. The approved run of record is `694A5886-…`; `2E4AED19-…` is
  obsolete/rejected.
- **No self-blessing** — no comparison or matrix run ever writes an approved reference or copies current
  render output into the reference set; `ReferenceStore` is read-only; `outOfBounds` is record-only.
- **Device-gate policy** — the full matrix + comparison run on the M2 Pro; the iPhone 13 Pro
  (`iPhone14,2`) gate verifies only device-specific facts; the DeviceGateHost project is frozen (more
  linkage ⇒ STOP, not a project change).

Step 19 / Task 004 is **not** started.
