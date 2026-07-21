# OCP Bare-Metal Bootstrap

This source generates day-0 artifacts for agent-based OpenShift bare-metal
clusters, including combined control/compute integrity controls:

- `install-config.yaml`
- `agent-config.yaml`
- `cluster-manifests/agent-cluster-install.yaml` (with schedulable control-plane support)
- `openshift/` integrity manifests (workload partitioning, kubelet reservations, guardrails)

## Prerequisites

- `ansible-playbook`
- `openshift-install`
- `nmstatectl` (required by `openshift-install` during agent validations)

## End-to-end workflow

From `sources/ocp-baremetal-bootstrap`:

1) Create local secret material (kept local by root `.gitignore`):

```bash
mkdir -p secrets
cp /path/to/your/pull-secret.json secrets/pull-secret.json
```

2) Create and tune your local metadata file (gitignored):

```bash
cp inventories/lab/group_vars/all.yml inventories/lab/group_vars/all.local.yml
```

Then update real infrastructure values in `inventories/lab/group_vars/all.local.yml`:

- `ocp_schedulable_masters`
- `ocp_integrity_cpu_partitioning`
- `ocp_integrity_kubelet_reservations`
- `ocp_integrity_placement`

3) Generate all day-0 artifacts in one run:

```bash
ansible-playbook -i inventories/lab/hosts.yml site.yml
```

4) Build the agent ISO:

```bash
openshift-install agent create image --dir build
```

## Combined-node integrity runbook

### Verify day-0 manifests

```bash
ls build/cluster-manifests
ls build/openshift
```

Confirm these files exist:

- `build/cluster-manifests/agent-cluster-install.yaml`
- `build/openshift/99-control-plane-performanceprofile.yaml`
- `build/openshift/99-control-plane-kubeletconfig.yaml`
- `build/openshift/99-namespace-guardrails.yaml`
- `build/openshift/99-integrity-validating-admission.yaml`

### Verify applied state after install

```bash
oc get performanceprofile -n openshift-cluster-node-tuning-operator
oc get kubeletconfig control-plane-integrity -o yaml
oc get priorityclass platform-critical platform-standard
oc get validatingadmissionpolicy integrity-require-resources integrity-require-placement-for-platform
oc get ns platform-critical --show-labels
oc get resourcequota,limitrange,poddisruptionbudget -n platform-critical
```

### Verify allocatable headroom and placement behavior

```bash
oc describe node <control-compute-node> | rg "Allocatable|Capacity|Taints"
oc adm top nodes
oc get pods -n platform-critical -o wide
```

Success criteria:

- Control-plane steady-state usage trends below the configured 60% target.
- Kubelet reservations and eviction thresholds are present on master pool nodes.
- Platform workloads in guarded namespaces are denied without requests/limits.
- Platform workloads labeled `workload-tier=platform` are denied unless required placement fields are present.

### Upgrade and failure-drill checklist

- Drain/reboot one combined node and verify critical pods remain available (`oc get pdb -A`).
- Simulate an operator rollout and verify control-plane node CPU/memory stay within headroom.
- Confirm validating admission policies remain enforced after upgrade.
- Re-run this bootstrap playbook whenever inventory integrity baselines change.

## Governance alignment (ACM)

Post-bootstrap drift control is delivered in `sources/acm-integrity-policies`.
Label only intended combined-role on-prem clusters for policy placement:

- `gitops.openshift.io/deployment-model=onprem-combined`
- `gitops.openshift.io/control-compute=true`
