# OpenShift GitOps Repository

This repository is being aligned to an app-centric OpenShift GitOps model where:

- deployable application content lives in `sources/<app-name>/`
- per-cluster rollout is controlled by `clusters/<clusterName>/<app>.yaml` gate files
- organizational composition lives in `profiles/`
- architecture decisions are documented in `docs/adr/`

The active guardrails are in `AGENTS.md` and accepted ADRs (`0001`-`0010`).

## Repository layout

- `sources/`: application deployment units
  - `sources/app-of-apps/`: ApplicationSet and generator defaults
  - `sources/app-projects/`: AppProject/RBAC source content
  - `sources/ocp-baremetal-bootstrap/`: bare-metal bootstrap Ansible app source
- `clusters/`: cluster gate files and bootstrap overlays
  - `clusters/ocpv420/`: lab cluster gate set and app-of-apps bootstrap artifacts
- `profiles/`: team, cluster-type, and data-center profiles
- `docs/adr/`: architectural decision records
- `.github/`: CI and ADR compliance automation

## Bootstrap app source (bare metal)

The previous top-level Ansible scaffold was moved to:

- `sources/ocp-baremetal-bootstrap/site.yml`
- `sources/ocp-baremetal-bootstrap/inventories/lab/`
- `sources/ocp-baremetal-bootstrap/roles/`

This keeps bootstrap automation app-centric and consistent with ADR-0001.

### Bare-metal workflow

```bash
cd sources/ocp-baremetal-bootstrap
ansible-playbook site.yml
openshift-install agent create image --dir build
ansible-playbook site.yml -e ocp_agent_image_publish_enabled=true
```

## Guardrail automation

CI and guardrail checks are defined in:

- `.github/workflows/ci.yaml`
- `.github/scripts/adr-compliance.sh`
- `.yamllint.yaml`
- `.markdownlint.yaml`
- `.kube-linter.yaml`

ADR compliance script enforces key mechanical invariants such as:

- gate file naming and top-level key restrictions
- required `app-of-apps.yaml` per cluster directory
- no `startingCSV` under `sources/`
- no Argo destination `name: in-cluster`

## Conventions

- Use `oc` (not `kubectl`) for OpenShift cluster interaction examples.
- Keep defaults centralized and use gate files only for intentional deviations.
- Keep production-specific pins (for example versions/images) explicit and auditable.

