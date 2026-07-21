# AGENTS.md

Operational context for AI agents working in this workspace.

## Purpose

Treat this repository as the source of truth for OpenShift GitOps configuration across clusters.
Changes should preserve a structure-driven model where behavior is derived from repository layout.

## Core guardrails

### Do

- Keep repository structure strict and schema-aligned.
- Consult `docs/adr/` before proposing structural or model-level changes.
- Organize deployment content by application under `sources/<app-name>`.
- Keep org defaults centralized and express only intentional deviations in per-cluster gate files.
- Use `oc` for cluster interactions.

### Don't

- Do not create ad-hoc top-level directories or alternate layout patterns.
- Do not organize configs by delivery tool.
- Do not duplicate bootstrap copies of application configuration.
- Do not add `startingCSV` in `sources/` subscription manifests by default.
- Do not introduce naming or ownership patterns that bypass AppProject/team governance.

## Repository model

- `sources/<app-name>` is the primary unit of deployment.
- `clusters/<clusterName>/<app>.yaml` gate files control app rollout and overrides by cluster.
- `profiles/` captures organizational composition (teams, cluster-types, and overrides).
- `docs/adr/` contains architecture decision records and must be treated as binding context.

## App-of-apps model

- Applications are generated from cluster list x gate-file discovery.
- Empty gate files (`{}`) imply defaults.
- Gate files should contain only explicit, auditable deviations.
- ApplicationSet implementation is expected under `sources/app-of-apps`.

## Governance model

- Every generated Application must belong to an AppProject.
- Every AppProject must be owned by one or more LDAP-backed teams.
- Team roles map to OpenShift roles:
  - admins -> `admin`
  - developers -> `edit`
  - viewers -> `view`
- One team may own multiple AppProjects; one AppProject may be shared by multiple teams.

## Cluster and naming conventions

- Preferred cluster naming: `<dc>-<type>-<env>-<n>` (unless approved lab/personal exception).
- Each cluster should map to exactly one cluster-type profile.
- Cluster-type profiles compose one or more reusable app-groups.
- Preserve data-center, cluster-type, and environment metadata used for RHACM label placement.

## Delivery model

`sources/<app-name>` content must remain consumable by Argo CD and reusable by bootstrap tooling
(for example: Ansible, RHACM governance, pipelines). Keep a single source of configuration truth.

## Agent execution checklist

Before opening a PR or finalizing generated content:

1. Confirm the change follows existing layout contracts.
2. Confirm the change is organized by app, not by tool.
3. Confirm AppProject/team ownership implications are preserved.
4. Confirm gate-file overrides are intentional and minimal.
5. Confirm OpenShift command examples use `oc`.
6. Confirm operator subscription changes avoid `startingCSV` unless intentionally pinned via override.
7. Confirm any structural change proposal cites relevant ADR context.
