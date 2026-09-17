#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

action=${1:-render}
case "${action}" in
  render | plan | apply | delete) ;;
  *) echo "Usage: $0 [render|plan|apply|delete]" >&2; exit 2 ;;
esac

"${SCRIPT_DIR}/validate-config.sh"
verify_cluster_context >/dev/null
initialize_results migration-config
manifest="${MIGRATION_READINESS_RUN_DIR}/migration-test-vm.yaml"
boot_source_resource=$(printf '%s' "${VM_BOOT_SOURCE_KIND}" | tr '[:upper:]' '[:lower:]')

oc get storageclass "${STORAGE_CLASS}" >/dev/null
oc -n "${VM_BOOT_SOURCE_NAMESPACE}" get \
  "${boot_source_resource}.cdi.kubevirt.io/${VM_BOOT_SOURCE_NAME}" >/dev/null

cat >"${manifest}" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${TEST_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: migration-readiness
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: ${TEST_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: migration-readiness
spec:
  runStrategy: Manual
  dataVolumeTemplates:
    - metadata:
        name: ${VM_NAME}-rootdisk
      spec:
        sourceRef:
          kind: ${VM_BOOT_SOURCE_KIND}
          name: ${VM_BOOT_SOURCE_NAME}
          namespace: ${VM_BOOT_SOURCE_NAMESPACE}
        storage:
          accessModes:
            - ${VM_ACCESS_MODE}
          volumeMode: ${VM_VOLUME_MODE}
          storageClassName: ${STORAGE_CLASS}
          resources:
            requests:
              storage: ${VM_DISK_SIZE}
  template:
    metadata:
      labels:
        kubevirt.io/domain: ${VM_NAME}
        app.kubernetes.io/part-of: migration-readiness
    spec:
      evictionStrategy: LiveMigrate
      domain:
        cpu:
          cores: ${VM_CPU_CORES}
        memory:
          guest: ${VM_MEMORY}
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume:
            name: ${VM_NAME}-rootdisk
EOF

case "${action}" in
  render)
    echo "Rendered ${manifest}"
    ;;
  plan)
    server_dry_run_manifest "${manifest}" "${TEST_NAMESPACE}"
    echo "Rendered ${manifest}"
    ;;
  apply)
    require_confirmation CONFIRM_APPLY "${CLUSTER_NAME}"
    oc apply -f "${manifest}"
    oc -n "${TEST_NAMESPACE}" get vm,dv,pvc
    ;;
  delete)
    require_confirmation CONFIRM_DELETE "${CLUSTER_NAME}"
    oc -n "${TEST_NAMESPACE}" delete vm "${VM_NAME}" --ignore-not-found
    ;;
esac
