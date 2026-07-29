# Workload Availability (Node Health Check + Self Node Remediation + Fence Agents Remediation)

Installs the three operators from Red Hat's "Workload Availability for Red Hat
OpenShift" bundle, so a hard-failed node is detected and fenced instead of
relying on Kubernetes' default ~5-6 minute `NotReady` toleration before
workloads (including OpenShift Virtualization VMs) are rescheduled elsewhere.

## What's active by default

`nodehealthcheck.yaml` wires the `NodeHealthCheck` to the **Self Node
Remediation (SNR)** provider. SNR needs no BMC credentials — it self-fences
using the node's own watchdog / API-server-unreachable heuristic — so it
works immediately after this source syncs, with no extra secrets to manage.

## Optional upgrade: real BMC/Redfish power fencing

The Fence Agents Remediation (FAR) operator is installed by this source but
not wired up by default, because it requires per-node BMC credential
`Secret`s that must never be committed to git. See
[`fence-agents-remediation-template.example.yaml`](fence-agents-remediation-template.example.yaml)
for the activation steps — it reuses the same `bmc_address`/`bmc_username`/
`bmc_password` fields already recorded per node in
[`sources/ocp-baremetal-bootstrap`](../ocp-baremetal-bootstrap)'s inventory.

## Scope note for this cluster

All 5 `ocpv420` nodes are combined control-plane/worker (masters schedulable,
no dedicated workers), so `nodehealthcheck.yaml` selects on
`node-role.kubernetes.io/master` and there is no "safe" node subset to
exclude from remediation. This is accepted for this lab: 5-node etcd quorum
tolerates up to 2 simultaneous member losses, so fencing any single node is
safe. Re-evaluate this selector if the cluster ever adds dedicated worker
nodes.
