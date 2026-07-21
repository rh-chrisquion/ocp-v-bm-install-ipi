# Proposed ADR Implementation Backlog

This backlog tracks follow-on implementation work for proposed ADRs once the
accepted-ADR baseline (`0001`-`0010`) is complete and CI guardrails are green.

## Prioritization order

1. ADR-0012: Agent-owned repository (`Genesis`) first-light controls
2. ADR-0011: Cluster config harvesting (Verifier candidate generation)
3. ADR-0015: Multi-cluster topology support (`hub-push` and `pull-agent`)
4. ADR-0016: Remediation PR authoring contract
5. ADR-0017: Loop engineering and decision review roles
6. ADR-0014: AI-assisted Gatekeeper policy authoring and promotion
7. ADR-0013: Agent cost metering and budget controls

## Backlog items

### ADR-0012: Agent-owned repository

- **Goal**: Implement first-light governance primitives for autonomous changes:
  branch-only writes, PR-only merge path, lane-aware approvals, and rollback-ready
  audit trail.
- **Deliverables**:
  - agent lane policy document and ownership model
  - PR template updates for autonomy metadata
  - branch protection/check requirements aligned to autonomy levels

### ADR-0011: Cluster config harvesting

- **Goal**: Add a Verifier/Harvester capability that proposes candidate manifests
  from cluster state without direct writes to `main`.
- **Deliverables**:
  - harvesting scope policy (which resources are in/out)
  - normalization/cleaning pipeline and safety filters
  - PR generation contract for harvested candidates

### ADR-0015: Multi-cluster topology

- **Goal**: Support both hub-push and pull-agent topologies in a single repo
  contract with explicit per-cluster topology metadata.
- **Deliverables**:
  - topology model field in cluster records
  - topology-specific placement and delivery behavior documentation
  - verifier sensor compatibility matrix by topology

### ADR-0016: Remediation PR authoring

- **Goal**: Standardize remediation PR output with reproducible change metadata.
- **Deliverables**:
  - remediation PR body template
  - required attachments (manifest, rationale, classification)
  - reviewer checklist for remediation safety and reversibility

### ADR-0017: Loop engineering and decision review

- **Goal**: Introduce explicit loop roles (Verifier, Reconciler, Auditor) and
  decision checkpoints around blast radius and reversibility.
- **Deliverables**:
  - role interface definitions and handoff contracts
  - review rubric for reversibility/blast-radius scoring
  - exception process for high-risk autonomous changes

### ADR-0014: AI-assisted admission control authoring

- **Goal**: Establish template-library-first Gatekeeper policy generation with
  dryrun -> warn -> deny promotion workflow.
- **Deliverables**:
  - `schema/gatekeeper-templates/` scaffold and governance
  - promotion policy and minimum soak periods
  - false-positive review and rollback guidance

### ADR-0013: Agent cost metering and budget

- **Goal**: Enforce budget visibility and controls for autonomous/assisted runs.
- **Deliverables**:
  - per-loop/per-lane cost attribution model
  - budget thresholds with policy actions
  - telemetry reporting and review cadence
