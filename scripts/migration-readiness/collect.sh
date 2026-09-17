#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

include_host=false
if [[ "${1:-}" == "--host" ]]; then
  include_host=true
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--host]" >&2
  exit 2
fi

"${SCRIPT_DIR}/validate-config.sh"
verify_cluster_context >/dev/null
initialize_results diagnostics
: >"${MIGRATION_READINESS_RUN_DIR}/command-status.tsv"

capture_shell cluster-overview '
  date -u
  oc whoami --show-server
  oc get --raw=/readyz
  oc get clusterversion
  oc get nodes -o wide
  oc get clusteroperators
'

capture_shell operators '
  oc get subscriptions.operators.coreos.com -A
  oc get clusterserviceversions.operators.coreos.com -A
  oc get installplans.operators.coreos.com -A
'

capture_shell network-api '
  oc get network.config.openshift.io cluster -o yaml
  oc get network.operator.openshift.io cluster -o yaml
  oc get ingresscontroller.operator.openshift.io -A
  oc get network-attachment-definitions.k8s.cni.cncf.io -A
  oc get nodeNetworkConfigurationPolicies.nmstate.io 2>/dev/null || true
  oc get nodeNetworkConfigurationEnactments.nmstate.io -A 2>/dev/null || true
  oc get nodeNetworkStates.nmstate.io -A 2>/dev/null || true
'

capture_shell storage-api '
  oc get storageclass
  oc get csidriver
  oc get csinode
  oc get volumeattachments.storage.k8s.io
  oc get persistentvolume
  oc get persistentvolumeclaim -A
  if [[ -n "${STORAGE_CUSTOM_RESOURCE:-}" ]]; then
    oc get "${STORAGE_CUSTOM_RESOURCE}" -A 2>/dev/null || true
  fi
  oc -n "${STORAGE_WORKLOAD_NAMESPACE}" get deployment,daemonset,pod -o wide 2>/dev/null || true
  oc -n "${STORAGE_BACKEND_SECRET_NAMESPACE}" get secret \
    -o custom-columns=NAME:.metadata.name,TYPE:.type 2>/dev/null || true
  oc get storageprofiles.cdi.kubevirt.io -o wide 2>/dev/null || true
'

capture_shell virtualization-api '
  oc -n "${VIRTUALIZATION_NAMESPACE}" get hyperconverged,kubevirt,cdi,ssp 2>/dev/null || true
  oc -n "${VIRTUALIZATION_NAMESPACE}" get deployment,daemonset,pod -o wide 2>/dev/null || true
  oc get virtualmachines.kubevirt.io -A
  oc get virtualmachineinstances.kubevirt.io -A
  oc get virtualmachineinstancemigrations.kubevirt.io -A
  oc get datasources.cdi.kubevirt.io -A
  oc get datavolumes.cdi.kubevirt.io -A
  oc get migrationpolicies.migrations.kubevirt.io 2>/dev/null || true
  oc get nodes \
    -L kubevirt.io/schedulable,kubevirt.io/ksm-enabled,kubevirt.io/heartbeat
'

capture_shell recent-warning-events '
  oc get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -200
'

if [[ "${include_host}" == "true" ]]; then
  for node in ${EXPECTED_NODES}; do
    safe_node=${node//[^a-zA-Z0-9_.-]/_}
    capture "host-${safe_node}" oc debug "node/${node}" --quiet -- chroot /host bash -c '
      set -o pipefail
      echo "### links and addresses"
      ip -brief link
      ip -brief address
      echo "### routes"
      ip route
      ip -6 route
      echo "### bonds"
      for bond_file in /proc/net/bonding/*; do
        test -e "${bond_file}" || continue
        echo "--- ${bond_file}"
        cat "${bond_file}"
      done
      echo "### NetworkManager"
      nmcli -f GENERAL,WIRED-PROPERTIES device show 2>/dev/null || true
      echo "### iSCSI"
      iscsiadm -m session 2>/dev/null || true
      echo "### configured iSCSI portal paths"
      for portal in ${1}; do
        host=${portal%:*}
        port=${portal##*:}
        echo "--- ${portal}"
        ip route get "${host}" 2>&1 || true
        if timeout 5 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
          echo "TCP/${port} OPEN"
        else
          echo "TCP/${port} FAILED"
        fi
      done
      echo "### multipath"
      multipath -ll 2>/dev/null || true
      echo "### KVM"
      test -c /dev/kvm && ls -l /dev/kvm || true
      grep -Eoc "(vmx|svm)" /proc/cpuinfo || true
    ' _ "${ISCSI_PORTALS:-}"
  done
fi

cat >"${MIGRATION_READINESS_RUN_DIR}/summary.txt" <<EOF
Cluster: ${CLUSTER_NAME}
Configuration: ${MIGRATION_READINESS_CONFIG}
Host inspection included: ${include_host}
Results: ${MIGRATION_READINESS_RUN_DIR}

Review command-status.tsv and every non-zero command before configuration or
disruptive tests. A missing optional CRD can be acceptable; degraded operators,
NotReady nodes, failed CSI components, or unschedulable KubeVirt nodes are
stop conditions.
EOF

cat "${MIGRATION_READINESS_RUN_DIR}/summary.txt"
