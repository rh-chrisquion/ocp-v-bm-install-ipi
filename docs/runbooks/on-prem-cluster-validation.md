# On-Prem Cluster Validation Runbook

Validates `ocpv420` — a 5-node combined control-plane/worker ("compact")
cluster (masters schedulable, 0 dedicated workers; see
[`sources/ocp-baremetal-bootstrap`](../../sources/ocp-baremetal-bootstrap)) —
against four failure/performance scenarios:

1. etcd stability and latency
2. Bonded-NIC port failure (network resiliency)
3. VM live migration, node-to-node
4. Worker node hard failure → automatic VM failover

This is a manual runbook (procedures + `oc`/CLI commands), in the same style
as the ["Combined-node integrity runbook"](../../sources/ocp-baremetal-bootstrap/README.md#combined-node-integrity-runbook).
Test resources (VMs, benchmark pods) are applied ad hoc with `oc apply -f`
and torn down afterward — they are dev-inner-loop artifacts per
[ADR-0006](../adr/0006-development-workflow-and-environment-promotion.md),
not GitOps sources.

## Pre-flight checklist (run before any test below)

```bash
# Cluster and node health
oc get clusterversion
oc get nodes -o wide
oc get co | grep -v "True.*False.*False"

# GitOps prerequisites synced (see sources/openshift-virtualization,
# sources/workload-availability, sources/hpe-csi-driver)
oc get csv -n openshift-cnv
oc get csv -n openshift-workload-availability
oc get csv -n hpe-storage
oc get storageclass

# etcd quorum healthy before any fencing/network test
oc -n openshift-etcd rsh $(oc -n openshift-etcd get pods -l app=etcd -o jsonpath='{.items[0].metadata.name}') \
  etcdctl endpoint health --cluster -w table
```

Stop and remediate before proceeding if: any `ClusterOperator` is
degraded, any node is `NotReady`, or etcd quorum is not 5/5 (or at least
4/5).

## 1. etcd stability and latency

### Baseline health and member status

```bash
ETCD_POD=$(oc -n openshift-etcd get pods -l app=etcd -o jsonpath='{.items[0].metadata.name}')

oc -n openshift-etcd exec "${ETCD_POD}" -- etcdctl endpoint health --cluster -w table
oc -n openshift-etcd exec "${ETCD_POD}" -- etcdctl endpoint status --cluster -w table
```

Confirm: all 5 members healthy, one leader, DB sizes roughly even across
members.

### Synthetic throughput/latency benchmark

```bash
oc -n openshift-etcd exec "${ETCD_POD}" -- etcdctl check perf
```

### Steady-state metrics

```bash
# fsync latency (p99 target < 10ms)
oc exec -n openshift-etcd "${ETCD_POD}" -c etcd -- \
  curl -s http://localhost:9979/metrics | grep etcd_disk_wal_fsync_duration_seconds

# inter-member round-trip time
oc exec -n openshift-etcd "${ETCD_POD}" -c etcd -- \
  curl -s http://localhost:9979/metrics | grep etcd_network_peer_round_trip_time_seconds

# leader changes — should stay flat outside intentional failover tests (section 4)
oc exec -n openshift-etcd "${ETCD_POD}" -c etcd -- \
  curl -s http://localhost:9979/metrics | grep etcd_server_leader_changes_seen_total

# DB size
oc exec -n openshift-etcd "${ETCD_POD}" -c etcd -- \
  curl -s http://localhost:9979/metrics | grep etcd_mvcc_db_total_size_in_bytes
```

Prefer pulling these same series from the in-cluster Prometheus
(`oc -n openshift-monitoring exec` a Thanos querier `curl`, or the OpenShift
console's Metrics tab) for a longer time window than a single `curl` snapshot.

### Optional: apply API load while watching the metrics above

```bash
for i in $(seq 1 200); do
  oc create configmap "etcd-load-test-${i}" -n default --from-literal=k=v --dry-run=client -o yaml \
    | oc label -f - --local -o yaml load-test=on-prem-validation \
    | oc apply -f -
done
# ...observe metrics above during and after this loop, then clean up...
oc delete configmap -n default -l load-test=on-prem-validation
```

Cross-reference control-plane CPU/memory against the utilization ceiling
already declared for this cluster
(`ocp_integrity_control_plane_target_max_utilization_percent: 60` in
`sources/ocp-baremetal-bootstrap`):

```bash
oc adm top nodes
```

### Pass/fail criteria

| Check | Pass threshold |
|---|---|
| `etcdctl endpoint health` | All members healthy |
| `etcd_disk_wal_fsync_duration_seconds` p99 | < 10ms |
| `etcd_network_peer_round_trip_time_seconds` p99 | < 50ms (same-DC) |
| `etcd_server_leader_changes_seen_total` | Flat during the test window |
| Control-plane CPU/memory under load | Stays below the 60% target |
| `etcdctl check perf` | Reports `PASS` |

## 2. Network resiliency — bonded pair port failure

Bonds are defined per node in `ocp_network_bonds`
(`sources/ocp-baremetal-bootstrap`): `bond_data` (`eth0`/`eth1`),
`bond_storage` (`eth2`/`eth3`), `bond_multicast` (`eth4`/`eth5`), all
802.3ad/LACP. Test `bond_data` first (full ping + throughput), then repeat a
lighter ping-only pass for `bond_storage` and `bond_multicast`.

Pick two nodes, `NODE_A` and `NODE_B`, and their `bond_data` IPs from
`ocp_nodes[*].bond_ipv4.data`.

### Start background traffic

```bash
NODE_A=example-node-01
NODE_B=example-node-02
NODE_B_DATA_IP=192.0.2.12   # bond_ipv4.data for NODE_B

# Continuous ping, in a separate terminal — leave running through the test
oc debug node/"${NODE_A}" -- chroot /host ping -i 0.2 "${NODE_B_DATA_IP}"
```

Throughput needs a container image (RHCOS doesn't ship `iperf3`), so run
throwaway `hostNetwork` pods pinned to each node:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: iperf3-server
  namespace: default
spec:
  hostNetwork: true
  nodeName: ${NODE_B}
  containers:
    - name: iperf3
      image: networkstatic/iperf3
      args: ["-s"]
  restartPolicy: Never
EOF

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: iperf3-client
  namespace: default
spec:
  hostNetwork: true
  nodeName: ${NODE_A}
  containers:
    - name: iperf3
      image: networkstatic/iperf3
      args: ["-c", "${NODE_B_DATA_IP}", "-t", "60", "-i", "5"]
  restartPolicy: Never
EOF

oc logs -f pod/iperf3-client -n default   # record baseline throughput
```

### Fail one bond member

```bash
oc debug node/"${NODE_A}" -- chroot /host ip link set eth0 down
```

### Verify the bond stays up

```bash
oc debug node/"${NODE_A}" -- chroot /host cat /proc/net/bonding/bond_data
```

Confirm: `Bonding Mode: IEEE 802.3ad`, `MII Status: up` overall, `eth0` shows
`down`/`Link Failure Count` incremented, `eth1` still `up` and is now the
only active aggregator member.

Re-check the ping terminal (near-zero/minimal loss) and re-run the `iperf3`
client (throughput drops — roughly halved for a 2-member LACP bond — but
never reaches zero):

```bash
oc delete pod iperf3-client -n default --ignore-not-found
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: iperf3-client
  namespace: default
spec:
  hostNetwork: true
  nodeName: ${NODE_A}
  containers:
    - name: iperf3
      image: networkstatic/iperf3
      args: ["-c", "${NODE_B_DATA_IP}", "-t", "60", "-i", "5"]
  restartPolicy: Never
EOF
oc logs -f pod/iperf3-client -n default
```

### Recovery

```bash
oc debug node/"${NODE_A}" -- chroot /host ip link set eth0 up
oc debug node/"${NODE_A}" -- chroot /host cat /proc/net/bonding/bond_data
```

Confirm both slaves re-aggregate (`MII Status: up` for both) and throughput
returns to baseline on a final `iperf3` run.

### Cleanup

```bash
oc delete pod iperf3-server iperf3-client -n default --ignore-not-found
```

### Repeat for the other bonds

- `bond_storage` (`eth2`/`eth3`): ping-only, using each node's
  `bond_ipv4.storage` address.
- `bond_multicast` (`eth4`/`eth5`): ping-only, using each node's
  `bond_ipv4.multicast` address.

### Pass/fail criteria

| Check | Pass threshold |
|---|---|
| Bond interface state during failure | Stays `UP`, one slave active |
| Ping loss during failure | 0% (LACP failover is sub-second) |
| Throughput during failure | > 0 (single-member bandwidth, not zero) |
| Bond state after recovery | Both slaves re-aggregate within a few seconds |
| Throughput after recovery | Returns to pre-failure baseline |

## 3. Test VM creation + live migration node-to-node

Requires [`sources/openshift-virtualization`](../../sources/openshift-virtualization)
and [`sources/hpe-csi-driver`](../../sources/hpe-csi-driver) (with its
backend `Secret`/`StorageClass` — see that source's README) to be synced
first. The VM disk must be on a `ReadWriteMany` `Block` volume for live
migration to work with the HPE CSI Driver.

### Create the test VM

```bash
cat <<EOF | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: validation-test-vm
  namespace: default
spec:
  running: true
  template:
    metadata:
      labels:
        kubevirt.io/domain: validation-test-vm
    spec:
      evictionStrategy: LiveMigrate
      domain:
        cpu:
          cores: 1
        resources:
          requests:
            memory: 1Gi
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
      volumes:
        - name: rootdisk
          dataVolume:
            name: validation-test-vm-rootdisk
  dataVolumeTemplates:
    - metadata:
        name: validation-test-vm-rootdisk
      spec:
        storage:
          accessModes:
            - ReadWriteMany
          volumeMode: Block
          resources:
            requests:
              storage: 10Gi
          storageClassName: hpe-standard
        sourceRef:
          kind: DataSource
          name: fedora
          namespace: openshift-virtualization-os-images
EOF

oc wait vmi validation-test-vm -n default --for=condition=Ready --timeout=5m
```

### Trigger migration and watch it complete

```bash
virtctl migrate validation-test-vm -n default
oc get vmim -n default -w   # wait for PHASE: Succeeded
```

### Verify near-zero downtime and the node change

```bash
# In a separate terminal, started before triggering the migration:
oc get vmi validation-test-vm -n default -o jsonpath='{.status.interfaces[0].ipAddress}'
ping -i 0.2 <vm-ip>   # keep running through the migration; expect no more than 1-2 dropped pings

oc get vmi validation-test-vm -n default -o wide   # confirm NODENAME changed
```

### Cleanup

```bash
oc delete vm validation-test-vm -n default
```

### Pass/fail criteria

| Check | Pass threshold |
|---|---|
| `VirtualMachineInstanceMigration` phase | `Succeeded` |
| Ping loss during migration | 0-2 dropped packets |
| `oc get vmi -o wide` `NODENAME` | Changed to a different node |
| VM reachable post-migration | Yes, same IP, no reboot |

## 4. Worker node hard failure → automatic VM failover

Uses [`sources/workload-availability`](../../sources/workload-availability)
(Node Health Check + Self Node Remediation, active by default) to fence a
hard-failed node and let `virt-controller` reschedule the VM
(`runStrategy`/`evictionStrategy: LiveMigrate` still applies — with
`evictionStrategy: LiveMigrate` and a dead source node, KubeVirt falls back
to restarting the VM elsewhere once the node is confirmed fenced).

### Pre-flight (in addition to the checklist above)

```bash
oc -n openshift-etcd exec "${ETCD_POD}" -- etcdctl endpoint health --cluster -w table
oc get pods -n openshift-workload-availability
oc get nodehealthcheck ocpv420-combined-nodes -o yaml | grep -A5 status
```

Confirm: etcd quorum healthy (5/5, or 4/5 minimum), NHC/SNR pods `Running`,
`NodeHealthCheck` status shows no `InProgress`/`Paused` conditions.

### Identify the VM's current node and its BMC

```bash
oc get vmi validation-test-vm -n default -o wide   # note NODENAME
```

Look up that node's `bmc_address`/`bmc_username`/`bmc_password` in
`sources/ocp-baremetal-bootstrap/inventories/lab/group_vars/all.local.yml`
(gitignored — never in git).

### Run 1: baseline, no remediation reacting

Temporarily scale down NHC to observe the unmitigated default behavior
(confirm the actual deployment name first: `oc get deploy -n
openshift-workload-availability`):

```bash
oc scale deployment/node-healthcheck-controller-manager -n openshift-workload-availability --replicas=0
```

Power off the node via Redfish (adjust the systems URI to match
`bmc_address`):

```bash
date -u   # record T0
curl -k -u "${BMC_USERNAME}:${BMC_PASSWORD}" -X POST \
  -H 'Content-Type: application/json' \
  -d '{"ResetType": "ForceOff"}' \
  "https://<bmc-ip>/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"
```

Watch for the default `NotReady` toleration to evict the VM's pod (no
active remediation reacting):

```bash
watch oc get vmi validation-test-vm -n default -o wide
```

Record how long it takes (expect ~5-6 minutes, or indefinitely if nothing
evicts it — this is the documented gap NHC/SNR close). If it never
reschedules, use the documented manual escape hatch:

```bash
oc delete node <failed-node>
```

Power the node back on via Redfish (`"ResetType": "On"` in the same `curl`
command), confirm it rejoins as `Ready`, then re-enable NHC:

```bash
oc scale deployment/node-healthcheck-controller-manager -n openshift-workload-availability --replicas=1
```

### Run 2: with NHC/Self Node Remediation active

```bash
oc get vmi validation-test-vm -n default -o wide   # confirm current node again

date -u   # record T0
curl -k -u "${BMC_USERNAME}:${BMC_PASSWORD}" -X POST \
  -H 'Content-Type: application/json' \
  -d '{"ResetType": "ForceOff"}' \
  "https://<bmc-ip>/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"
```

Watch fencing and rescheduling happen automatically:

```bash
watch oc get selfnoderemediation -n openshift-workload-availability
watch oc get vmi validation-test-vm -n default -o wide
```

Record: time from `T0` to the `SelfNodeRemediation` CR appearing, to the
node being marked fenced/rebooted, to the VMI's `NODENAME` changing and
`PHASE` returning to `Running`.

### Verify data integrity and recovery

```bash
oc get vmi validation-test-vm -n default -o wide   # new NODENAME
virtctl console validation-test-vm   # confirm the VM booted with its prior disk contents
```

### Cleanup

```bash
oc delete vm validation-test-vm -n default
```

### Pass/fail criteria

| Check | Pass threshold |
|---|---|
| Run 1 (no remediation) recovery time | ~5-6 min (default toleration) or never — documents the gap |
| Run 2 (NHC/SNR active) recovery time | Single-digit minutes, deterministic |
| VM data after failover | Intact (proves shared HPE-backed storage worked) |
| etcd quorum after fencing | Recovers to 5/5 once the node rejoins |
| `SelfNodeRemediation` CR | Created automatically, no manual intervention |

## Summary

| # | Test | Depends on |
|---|---|---|
| 1 | etcd stability and latency | Cluster only |
| 2 | Bonded-NIC port failure | Cluster only |
| 3 | VM live migration | `sources/openshift-virtualization`, `sources/hpe-csi-driver` |
| 4 | Worker node hard failure → VM failover | `sources/openshift-virtualization`, `sources/hpe-csi-driver`, `sources/workload-availability` |

Record results (timestamps, thresholds met/missed) for each run in this
section or an attached results log when this runbook is executed, so
subsequent runs have a baseline to compare against.
