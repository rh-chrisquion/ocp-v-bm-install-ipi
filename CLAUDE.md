# OpenShift GitOps Working Context

This repository targets an OpenShift GitOps model where repository structure is
the primary source of truth for what runs on each cluster.

## Core model

- Organize deployable content by application under `sources/<app-name>/`.
- Use `clusters/<clusterName>/<app>.yaml` gate files to control app rollout and
  per-cluster deviations.
- Keep organizational composition in `profiles/` (teams, cluster-types,
  data-centers).
- Keep architecture decisions in `docs/adr/`; accepted ADRs are binding.

## Guardrails

- Avoid ad-hoc top-level directory sprawl.
- Avoid tool-centric config copies (no duplicated per-tool trees for same app).
- Keep a single source of truth per app that can be consumed by Argo CD and
  bootstrap tooling.
- Use `oc` for OpenShift cluster command examples.
- Omit `startingCSV` in `sources/` subscriptions by default; production pinning
  belongs in explicit overrides.

## Operational assumptions

- App-of-apps is expected under `sources/app-of-apps`.
- Every generated application belongs to an Argo CD AppProject.
- Every AppProject is team-governed with LDAP-backed ownership and role mapping.
- Cluster naming should follow `<dc>-<type>-<env>-<n>` for shared environments,
  with documented lab exceptions where appropriate.

## Change policy

When proposing structural changes, cite relevant accepted ADRs from `docs/adr/`
and prefer minimal, auditable deviations over broad one-off customization.
