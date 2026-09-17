#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

if [[ "${1:-}" != "--execute" ]]; then
  echo "Usage: CONFIRM_MIGRATION=${CLUSTER_NAME} $0 --execute" >&2
  exit 2
fi

require_confirmation CONFIRM_MIGRATION "${CLUSTER_NAME}"
verify_cluster_context >/dev/null
require_command virtctl
require_command jq
initialize_results live-migration

oc -n "${TEST_NAMESPACE}" get vm "${VM_NAME}" >/dev/null
oc -n "${TEST_NAMESPACE}" wait --for=jsonpath='{.status.phase}'=Succeeded \
  "dv/${VM_NAME}-rootdisk" --timeout="${VM_READY_TIMEOUT_SECONDS}s"

if ! oc -n "${TEST_NAMESPACE}" get vmi "${VM_NAME}" >/dev/null 2>&1; then
  virtctl -n "${TEST_NAMESPACE}" start "${VM_NAME}"
fi

deadline=$((SECONDS + VM_READY_TIMEOUT_SECONDS))
until oc -n "${TEST_NAMESPACE}" get vmi "${VM_NAME}" >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    echo "VMI was not created before timeout" >&2
    exit 1
  fi
  sleep 5
done

oc -n "${TEST_NAMESPACE}" wait --for=condition=Ready \
  "vmi/${VM_NAME}" --timeout="${VM_READY_TIMEOUT_SECONDS}s"

source_node=$(oc -n "${TEST_NAMESPACE}" get vmi "${VM_NAME}" \
  -o jsonpath='{.status.nodeName}')
echo "Source node: ${source_node}" | tee "${MIGRATION_READINESS_RUN_DIR}/migration.log"

virtctl -n "${TEST_NAMESPACE}" migrate "${VM_NAME}"

deadline=$((SECONDS + VM_MIGRATION_TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  migration_json=$(oc -n "${TEST_NAMESPACE}" get vmim -o json)
  phase=$(jq -r --arg vmi_name "${VM_NAME}" '
    .items
    | map(select(.spec.vmiName == $vmi_name))
    | sort_by(.metadata.creationTimestamp)
    | last
    | .status.phase // "Pending"
  ' <<<"${migration_json}")
  echo "$(date -u +%FT%TZ) phase=${phase}" | tee -a \
    "${MIGRATION_READINESS_RUN_DIR}/migration.log"
  case "${phase}" in
    Succeeded) break ;;
    Failed) echo "Migration failed" >&2; exit 1 ;;
  esac
  sleep 5
done

if [[ "${phase:-Pending}" != "Succeeded" ]]; then
  echo "Migration did not succeed before timeout" >&2
  exit 1
fi

destination_node=$(oc -n "${TEST_NAMESPACE}" get vmi "${VM_NAME}" \
  -o jsonpath='{.status.nodeName}')
echo "Destination node: ${destination_node}" | tee -a \
  "${MIGRATION_READINESS_RUN_DIR}/migration.log"

if [[ "${source_node}" == "${destination_node}" ]]; then
  echo "Migration reported success but the node did not change" >&2
  exit 1
fi

oc -n "${TEST_NAMESPACE}" get vm,vmi,vmim -o wide | tee -a \
  "${MIGRATION_READINESS_RUN_DIR}/migration.log"
