#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<EOF
Usage: CONFIRM_NETWORK_DISRUPTION=${CLUSTER_NAME} $0 --execute [options]

Options:
  --skip-collect       Skip host diagnostics collection
  --skip-network-path  Skip continuous API/URL reachability checks
  --skip-bond-members  Skip configured host bond-member cases
  --skip-vm            Skip the optional VM traffic bond-member test
  --skip-final-health  Skip final node, etcd and bond health verification
EOF
}

execute=false
run_collect=true
run_network_path=true
run_bond_members=true
run_vm=true
run_final_health=true

while (( $# > 0 )); do
  case "$1" in
    --execute) execute=true ;;
    --skip-collect) run_collect=false ;;
    --skip-network-path) run_network_path=false ;;
    --skip-bond-members) run_bond_members=false ;;
    --skip-vm) run_vm=false ;;
    --skip-final-health) run_final_health=false ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ "${execute}" == "true" ]] || {
  usage >&2
  exit 2
}
require_confirmation CONFIRM_NETWORK_DISRUPTION "${CLUSTER_NAME}"
verify_cluster_context >/dev/null
initialize_results network-suite

suite_result=FAIL
active_node=""
active_bond=""
active_member=""

recover_active_member() {
  [[ -n "${active_node}" && -n "${active_member}" ]] || return 0

  echo "ROLLBACK: restoring ${active_node} ${active_bond}/${active_member}" >&2
  if oc debug "node/${active_node}" --quiet -- chroot /host bash -c '
    set -e
    bond=$1
    member=$2
    ip link set dev "${member}" up
    for attempt in $(seq 1 30); do
      status=$(awk -v wanted="${member}" '\''
        /^Slave Interface:/ { current=$3; next }
        current == wanted && /^MII Status:/ { print $3; exit }
      '\'' "/proc/net/bonding/${bond}")
      [[ "${status}" == "up" ]] && exit 0
      sleep 1
    done
    exit 1
  ' -- "${active_bond}" "${active_member}"; then
    echo "ROLLBACK: PASS - ${active_member} is back in ${active_bond}" >&2
  else
    echo "ROLLBACK: FAIL - manually inspect ${active_node} ${active_bond}/${active_member}" >&2
  fi
  oc wait --for=condition=Ready "node/${active_node}" --timeout=5m || true
}

print_suite_result() {
  status=$?
  if [[ "${suite_result}" == "PASS" && ${status} -eq 0 ]]; then
    echo "RESULT: PASS - ${CLUSTER_NAME} network resiliency suite completed"
  else
    recover_active_member
    echo "RESULT: FAIL - ${CLUSTER_NAME} network resiliency suite stopped" >&2
    echo "Artifacts: ${MIGRATION_READINESS_RUN_DIR}" >&2
  fi
}
trap print_suite_result EXIT
trap 'exit 130' INT TERM

run_stage() {
  stage=$1
  shift
  printf '\n===== %s =====\n' "${stage}"
  "$@"
}

run_stage "VALIDATE CONFIGURATION AND CONTEXT" \
  "${SCRIPT_DIR}/migration-readiness.sh" \
  --config "${MIGRATION_READINESS_CONFIG}" validate

if [[ "${run_collect}" == "true" ]]; then
  run_stage "COLLECT HOST NETWORK BASELINE" \
    "${SCRIPT_DIR}/migration-readiness.sh" \
    --config "${MIGRATION_READINESS_CONFIG}" collect --host
else
  echo "SKIP: host diagnostics collection"
fi

if [[ "${run_network_path}" == "true" ]]; then
  run_stage "TEST API AND CONFIGURED URL PATHS" \
    "${SCRIPT_DIR}/migration-readiness.sh" \
    --config "${MIGRATION_READINESS_CONFIG}" network-path
else
  echo "SKIP: API and URL network-path test"
fi

if [[ "${run_bond_members}" == "true" ]]; then
  require_value NETWORK_RESILIENCY_CASES
  case_number=0
  while IFS='|' read -r node bond member peer_ip peer_port; do
    [[ -n "${node}" ]] || continue
    ((case_number += 1))
    active_node=${node}
    active_bond=${bond}
    active_member=${member}
    case_dir="${MIGRATION_READINESS_RUN_DIR}/bond-case-$((case_number))-${node}-${member}"
    mkdir -p "${case_dir}"
    printf '\n===== BOND CASE %d: %s %s/%s -> %s:%s =====\n' \
      "${case_number}" "${node}" "${bond}" "${member}" "${peer_ip}" "${peer_port}"

    RESILIENCY_NODE="${node}" \
    RESILIENCY_BOND="${bond}" \
    RESILIENCY_MEMBER="${member}" \
    RESILIENCY_PEER_IP="${peer_ip}" \
    RESILIENCY_PEER_PORT="${peer_port}" \
    MIGRATION_READINESS_RUN_DIR="${case_dir}" \
    CONFIRM_NETWORK_DISRUPTION="${CLUSTER_NAME}" \
      "${SCRIPT_DIR}/migration-readiness.sh" \
      --config "${MIGRATION_READINESS_CONFIG}" bond-member --execute

    active_node=""
    active_bond=""
    active_member=""
  done <<<"${NETWORK_RESILIENCY_CASES}"
  (( case_number > 0 )) || {
    echo "NETWORK_RESILIENCY_CASES contains no runnable cases" >&2
    exit 1
  }
else
  echo "SKIP: host bond-member tests"
fi

if [[ "${run_vm}" == "true" ]]; then
  if [[ -n "${VM_RESILIENCY_NAME:-}" ]]; then
    active_node=$(oc get vmi "${VM_RESILIENCY_NAME}" \
      -n "${VM_RESILIENCY_NAMESPACE}" -o jsonpath='{.status.nodeName}')
    active_bond=${VM_RESILIENCY_BOND}
    active_member=${VM_RESILIENCY_MEMBER}
    vm_case_dir="${MIGRATION_READINESS_RUN_DIR}/vm-bond-case"
    mkdir -p "${vm_case_dir}"
    run_stage "TEST VM TRAFFIC BOND RESILIENCY" env \
      MIGRATION_READINESS_RUN_DIR="${vm_case_dir}" \
      CONFIRM_NETWORK_DISRUPTION="${CLUSTER_NAME}" \
      "${SCRIPT_DIR}/migration-readiness.sh" \
      --config "${MIGRATION_READINESS_CONFIG}" vm-bond-member --execute
    active_node=""
    active_bond=""
    active_member=""
  else
    echo "SKIP: VM traffic test is not configured in ${MIGRATION_READINESS_CONFIG}"
  fi
else
  echo "SKIP: VM traffic bond-member test"
fi

if [[ "${run_final_health}" == "true" ]]; then
  run_stage "VERIFY FINAL NODE HEALTH" bash -c '
    set -euo pipefail
    not_ready=$(oc get nodes --no-headers | awk '\''$2 != "Ready" {count++} END {print count+0}'\'')
    (( not_ready == 0 ))
    oc get nodes -o wide
  '

  etcd_pod=$(oc -n openshift-etcd get pods -l app=etcd \
    -o jsonpath='{.items[0].metadata.name}')
  run_stage "VERIFY FINAL ETCD HEALTH" \
    oc -n openshift-etcd exec "${etcd_pod}" -- \
    etcdctl endpoint health --cluster -w table

  if [[ "${run_bond_members}" == "true" ]]; then
    while IFS='|' read -r node bond member peer_ip peer_port; do
      [[ -n "${node}" ]] || continue
      run_stage "VERIFY RECOVERED MEMBER: ${node} ${bond}/${member}" \
        oc debug "node/${node}" --quiet -- chroot /host bash -c '
          set -e
          bond=$1
          member=$2
          read -r up_members member_status < <(awk -v wanted="${member}" '\''
            /^Slave Interface:/ { current=$3; next }
            current != "" && /^MII Status:/ {
              if ($3 == "up") up++
              if (current == wanted) selected=$3
              current=""
            }
            END { print up+0, selected }
          '\'' "/proc/net/bonding/${bond}")
          echo "bond=${bond} up_members=${up_members} member=${member} status=${member_status}"
          (( up_members >= 2 )) && [[ "${member_status}" == "up" ]]
        ' -- "${bond}" "${member}"
    done <<<"${NETWORK_RESILIENCY_CASES}"
  fi
else
  echo "SKIP: final node and etcd health checks"
fi

suite_result=PASS
