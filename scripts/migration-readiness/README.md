# OpenShift Virtualization migration-readiness toolkit

These scripts collect evidence and run guarded storage, migration, and network
resiliency tests against an OpenShift Virtualization cluster. All environment
details come from a local profile. The repository contains only a placeholder
profile and no cluster addresses, node names, credentials, or kubeconfigs.

## Configure

```bash
cp scripts/migration-readiness/config/cluster.env.example \
  /tmp/cluster.env
chmod 600 /tmp/cluster.env
${EDITOR:-vi} /tmp/cluster.env
```

Profiles are trusted shell input. Keep secrets out of them and set the desired
cluster context before running a command:

```bash
oc config use-context <context>
TOOL=./scripts/migration-readiness/migration-readiness.sh
PROFILE=/tmp/cluster.env

"${TOOL}" --config "${PROFILE}" validate
"${TOOL}" --config "${PROFILE}" assess
"${TOOL}" --config "${PROFILE}" collect --host
```

## Storage and migration tests

The storage test creates a temporary PVC and pod. The migration test creates a
temporary VM from the configured boot source. Mutating operations require the
cluster name as an explicit confirmation value.

```bash
CONFIRM_APPLY=<cluster-name> \
  "${TOOL}" --config "${PROFILE}" storage apply

CONFIRM_MIGRATION=<cluster-name> \
  "${TOOL}" --config "${PROFILE}" migration run

CONFIRM_DELETE=<cluster-name> \
  "${TOOL}" --config "${PROFILE}" storage delete
```

## Network resiliency suite

`NETWORK_RESILIENCY_CASES` uses one line per controlled failure:

```text
<node>|<bond>|<member>|<reachable-peer>|<tcp-port>
```

For each case, the suite establishes continuous traffic, takes one selected
bond member down, verifies traffic through the remaining member, restores the
link, and checks node, etcd, and bond health. Its exit trap attempts restoration
before stopping on any failure. Use only during an approved change window and
verify out-of-band access first.

```bash
CONFIRM_NETWORK_DISRUPTION=<cluster-name> \
  "${TOOL}" --config "${PROFILE}" network-suite --execute --skip-vm
```

The VM test is optional. Configure the `VM_RESILIENCY_*` values to maintain a
guest TCP connection while a member of the VM traffic bond is removed:

```bash
CONFIRM_NETWORK_DISRUPTION=<cluster-name> \
  "${TOOL}" --config "${PROFILE}" network-suite --execute
```

Individual stages can be omitted with `--skip-collect`,
`--skip-network-path`, `--skip-bond-members`, `--skip-vm`, or
`--skip-final-health`. Results and rollback evidence are written beneath the
artifact directory printed by the tool.
