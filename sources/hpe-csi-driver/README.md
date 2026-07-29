# HPE CSI Driver for Kubernetes

Installs the HPE CSI Operator for OpenShift, so PVCs (in particular VM disks
used for on-prem cluster validation) live on shared block storage backed by
an HPE primary storage array (Alletra, Nimble, Primera, or 3PAR) — storage
that survives a single node's live migration or hard failure. Node-local
storage (hostpath-provisioner, LVM Storage) cannot do this — the disk simply
disappears with the node.

Reference: [HPE Storage Container Orchestrator Documentation — Red Hat OpenShift](https://scod.hpedev.io/csi_driver/partners/redhat_openshift/index.html).

## What's applied by this source

- `hpe-storage` `Namespace`
- The 4 `SecurityContextConstraints` HPE's OpenShift guide requires before
  installing the operator (privileged host access for the controller/node/CSP
  pods)
- `OperatorGroup` + `Subscription` (catalog: `certified-operators`, channel
  `stable`, **`installPlanApproval: Manual`** per HPE's explicit guidance —
  see below)
- `HPECSIDriver` CR with an empty spec (operator defaults cover all supported
  arrays and image references)

## Manual prerequisites (not GitOps-managed)

1. **Approve the InstallPlan.** HPE explicitly says never to enable automatic
   updates for this operator — upgrades require following version-specific
   pre-req steps first. After this source's first sync, approve the initial
   install manually:

   ```bash
   oc -n hpe-storage patch $(oc get installplans -n hpe-storage -o name) \
     -p '{"spec":{"approved":true}}' --type merge
   ```

2. **Create the backend Secret and StorageClass.** These depend on the exact
   HPE array model serving `ocpv420` and must never be committed to git. See
   [`storageclass.example.yaml`](storageclass.example.yaml) for the
   activation steps.

3. **NVMe/iSCSI host identity fix (if applicable).** On some node images, the
   CSI node driver fails to start with a "duplicate NQN" error. If that
   occurs, apply the `MachineConfig` documented at
   [Duplicate NQNs issue](https://scod.hpedev.io/csi_driver/partners/redhat_openshift/index.html#duplicate-nqns-issue)
   (use the "converged cluster" / `master` role variant for `ocpv420`, since
   all 5 nodes are combined control-plane/worker).

## OpenShift Virtualization interop note

If VM disks are cloned from the `openshift-virtualization-os-images`
namespace and need to support live migration, confirm the `hpe-standard`
`StorageProfile` reports `ReadWriteMany` (`oc get storageprofile hpe-standard
-o yaml`) — recent OpenShift EUS releases default this correctly, but older
ones may need a manual patch. See the SCOD page linked above for details.
