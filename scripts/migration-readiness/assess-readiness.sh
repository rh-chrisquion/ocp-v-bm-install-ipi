#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_command jq
"${SCRIPT_DIR}/validate-config.sh"
verify_cluster_context >/dev/null
initialize_results assessment

report="${MIGRATION_READINESS_RUN_DIR}/assessment.tsv"
printf 'status\tcheck\tdetail\n' >"${report}"
failures=0

pass() {
  printf 'PASS\t%s\t%s\n' "$1" "$2" | tee -a "${report}"
}

fail() {
  printf 'FAIL\t%s\t%s\n' "$1" "$2" | tee -a "${report}"
  ((failures += 1))
}

for node in ${EXPECTED_NODES}; do
  status=""
  if status=$(oc get node "${node}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) &&
     [[ "${status}" == "True" ]]; then
    pass node-ready "${node}"
  else
    fail node-ready "${node} status=${status:-missing}"
  fi
done

bad_operators=$(oc get clusteroperators -o json | jq -r '
  [.items[]
   | select(
       any(.status.conditions[]; .type == "Available" and .status != "True") or
       any(.status.conditions[]; .type == "Degraded" and .status == "True")
     )
   | .metadata.name]
  | join(",")
')
if [[ -z "${bad_operators}" ]]; then
  pass cluster-operators "all available and not degraded"
else
  fail cluster-operators "${bad_operators}"
fi

if oc get csidriver "${CSI_DRIVER_NAME}" >/dev/null 2>&1; then
  pass csi-driver "${CSI_DRIVER_NAME} registered"
else
  fail csi-driver "${CSI_DRIVER_NAME} is absent"
fi

if oc get storageclass "${STORAGE_CLASS}" >/dev/null 2>&1; then
  pass storage-class "${STORAGE_CLASS}"
else
  fail storage-class "${STORAGE_CLASS} is absent"
fi

if oc -n "${STORAGE_BACKEND_SECRET_NAMESPACE}" get secret \
  "${STORAGE_BACKEND_SECRET_NAME}" >/dev/null 2>&1; then
  pass storage-backend-secret "${STORAGE_BACKEND_SECRET_NAMESPACE}/${STORAGE_BACKEND_SECRET_NAME} exists; content not read"
else
  fail storage-backend-secret "${STORAGE_BACKEND_SECRET_NAMESPACE}/${STORAGE_BACKEND_SECRET_NAME} is absent"
fi

if storage_workloads_json=$(oc -n "${STORAGE_WORKLOAD_NAMESPACE}" get deployment,daemonset -o json 2>/dev/null); then
  storage_workload_count=$(jq -r '.items | length' <<<"${storage_workloads_json}")
  storage_workload_failures=$(jq -r '
    [.items[]
     | if .kind == "Deployment" then
         select((.status.availableReplicas // 0) < (.spec.replicas // 1))
       else
         select((.status.numberReady // 0) < (.status.desiredNumberScheduled // 0))
       end
     | .metadata.name]
    | join(",")
  ' <<<"${storage_workloads_json}")
else
  storage_workload_count=0
  storage_workload_failures="query failed"
fi
if (( storage_workload_count == 0 )); then
  fail storage-workloads "no deployments or daemonsets found in ${STORAGE_WORKLOAD_NAMESPACE}"
elif [[ -z "${storage_workload_failures}" ]]; then
  pass storage-workloads "${storage_workload_count} workloads report required replicas"
else
  fail storage-workloads "${storage_workload_failures}"
fi

if hco_json=$(oc -n "${VIRTUALIZATION_NAMESPACE}" get hyperconverged "${HYPERCONVERGED_NAME}" -o json 2>/dev/null); then
  hco_available=$(jq -r 'any(.status.conditions[]?; .type == "Available" and .status == "True")' <<<"${hco_json}")
  hco_degraded=$(jq -r 'any(.status.conditions[]?; .type == "Degraded" and .status == "True")' <<<"${hco_json}")
  if [[ "${hco_available}" == "true" && "${hco_degraded}" == "false" ]]; then
    pass virtualization "HyperConverged is available and not degraded"
  else
    fail virtualization "HyperConverged available=${hco_available} degraded=${hco_degraded}"
  fi
else
  fail virtualization "HyperConverged ${VIRTUALIZATION_NAMESPACE}/${HYPERCONVERGED_NAME} is absent"
fi

schedulable_nodes=$(oc get nodes -l kubevirt.io/schedulable=true --no-headers 2>/dev/null | wc -l | tr -d ' ')
if (( schedulable_nodes >= MINIMUM_MIGRATION_NODES )); then
  pass migration-nodes "${schedulable_nodes} KubeVirt nodes are schedulable"
else
  fail migration-nodes "${schedulable_nodes} schedulable; need ${MINIMUM_MIGRATION_NODES}"
fi

boot_source_resource=$(printf '%s' "${VM_BOOT_SOURCE_KIND}" | tr '[:upper:]' '[:lower:]')
if oc -n "${VM_BOOT_SOURCE_NAMESPACE}" get \
  "${boot_source_resource}.cdi.kubevirt.io/${VM_BOOT_SOURCE_NAME}" >/dev/null 2>&1; then
  pass boot-source "${VM_BOOT_SOURCE_NAMESPACE}/${VM_BOOT_SOURCE_NAME}"
else
  fail boot-source "${VM_BOOT_SOURCE_NAMESPACE}/${VM_BOOT_SOURCE_NAME} is absent"
fi

if (( failures == 0 )); then
  echo "READY: prerequisite checks passed. Run the storage smoke test next."
  exit 0
fi

echo "NOT READY: ${failures} prerequisite check(s) failed. See ${report}" >&2
exit 1
