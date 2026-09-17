#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

offline=false
case "${1:-}" in
  "") ;;
  --offline) offline=true ;;
  *) echo "Usage: $0 [--offline]" >&2; exit 2 ;;
esac

for variable_name in \
  CLUSTER_NAME EXPECTED_API_HOST_FRAGMENT EXPECTED_NODES TEST_NAMESPACE PLAN_NAMESPACE \
  CSI_DRIVER_NAME STORAGE_CLASS STORAGE_WORKLOAD_NAMESPACE \
  STORAGE_BACKEND_SECRET_NAMESPACE STORAGE_BACKEND_SECRET_NAME \
  STORAGE_SMOKE_SIZE STORAGE_SMOKE_ACCESS_MODE \
  STORAGE_SMOKE_VOLUME_MODE VM_NAME VM_DISK_SIZE VM_ACCESS_MODE \
  VM_VOLUME_MODE VM_MEMORY VM_CPU_CORES VM_BOOT_SOURCE_KIND \
  VM_BOOT_SOURCE_NAME VM_BOOT_SOURCE_NAMESPACE VM_READY_TIMEOUT_SECONDS \
  VM_MIGRATION_TIMEOUT_SECONDS MINIMUM_MIGRATION_NODES VIRTUALIZATION_NAMESPACE \
  HYPERCONVERGED_NAME NETWORK_TEST_DURATION_SECONDS NETWORK_TEST_INTERVAL_SECONDS \
  RESILIENCY_OUTAGE_SECONDS RESILIENCY_PING_INTERVAL_SECONDS \
  RESILIENCY_MAX_PACKET_LOSS_PERCENT RESILIENCY_MAX_TCP_FAILURES; do
  require_value "${variable_name}"
done

case "${STORAGE_SMOKE_VOLUME_MODE}" in
  Filesystem | Block) ;;
  *) echo "STORAGE_SMOKE_VOLUME_MODE must be Filesystem or Block" >&2; exit 1 ;;
esac

case "${VM_VOLUME_MODE}" in
  Filesystem | Block) ;;
  *) echo "VM_VOLUME_MODE must be Filesystem or Block" >&2; exit 1 ;;
esac

for portal in ${ISCSI_PORTALS:-}; do
  if [[ ! "${portal}" =~ ^[a-zA-Z0-9.-]+:[0-9]+$ ]]; then
    echo "Invalid ISCSI_PORTALS entry; expected host:port: ${portal}" >&2
    exit 1
  fi
done

if [[ -n "${RESILIENCY_NODE:-}" || -n "${RESILIENCY_BOND:-}" ||
      -n "${RESILIENCY_MEMBER:-}" || -n "${RESILIENCY_PEER_IP:-}" ||
      -n "${RESILIENCY_PEER_PORT:-}" ]]; then
  for variable_name in \
    RESILIENCY_NODE RESILIENCY_BOND RESILIENCY_MEMBER \
    RESILIENCY_PEER_IP RESILIENCY_PEER_PORT
  do
    require_value "${variable_name}"
  done
fi

if [[ -n "${VM_RESILIENCY_NAMESPACE:-}" || -n "${VM_RESILIENCY_NAME:-}" ||
      -n "${VM_RESILIENCY_MEMBER:-}" || -n "${VM_RESILIENCY_TARGET_HOST:-}" ]]; then
  for variable_name in \
    VM_RESILIENCY_NAMESPACE VM_RESILIENCY_NAME VM_RESILIENCY_SSH_USER \
    VM_RESILIENCY_SSH_IDENTITY_FILE VM_RESILIENCY_NETWORK_NAME \
    VM_RESILIENCY_GUEST_INTERFACE VM_RESILIENCY_TARGET_HOST \
    VM_RESILIENCY_TARGET_PORT VM_RESILIENCY_BOND VM_RESILIENCY_MEMBER \
    VM_RESILIENCY_TEST_DURATION_SECONDS VM_RESILIENCY_MAX_TCP_FAILURES
  do
    require_value "${variable_name}"
  done
fi

echo "Configuration is structurally valid: ${MIGRATION_READINESS_CONFIG}"

if [[ "${offline}" == "false" ]] && command -v oc >/dev/null 2>&1 && oc whoami >/dev/null 2>&1; then
  server=$(verify_cluster_context)
  echo "OpenShift context validated: ${server}"

  for node in ${EXPECTED_NODES}; do
    oc get node "${node}" >/dev/null || {
      echo "Expected node is absent: ${node}" >&2
      exit 1
    }
  done
  echo "Expected nodes are present."
fi
