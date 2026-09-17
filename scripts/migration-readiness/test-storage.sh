#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

action=${1:-plan}
case "${action}" in
  plan | apply | delete) ;;
  *) echo "Usage: $0 [plan|apply|delete]" >&2; exit 2 ;;
esac

"${SCRIPT_DIR}/validate-config.sh"
verify_cluster_context >/dev/null
initialize_results storage

claim_name="migration-storage-smoke"
pod_name="migration-storage-smoke"
manifest="${MIGRATION_READINESS_RUN_DIR}/storage-smoke.yaml"

if [[ "${STORAGE_SMOKE_VOLUME_MODE}" == "Filesystem" ]]; then
  test_command='set -eu; date -u > /data/probe; sync; sha256sum /data/probe; cat /data/probe'
else
  test_command='set -eu; printf migration-readiness | dd of=/dev/test-volume bs=1 conv=fsync; dd if=/dev/test-volume bs=19 count=1 status=none'
fi

cat >"${manifest}" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${TEST_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: migration-readiness
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${claim_name}
  namespace: ${TEST_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: migration-readiness
spec:
  accessModes:
    - ${STORAGE_SMOKE_ACCESS_MODE}
  volumeMode: ${STORAGE_SMOKE_VOLUME_MODE}
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: ${STORAGE_SMOKE_SIZE}
---
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${TEST_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: migration-readiness
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: registry.access.redhat.com/ubi9/ubi-minimal:latest
      command: [/bin/sh, -c]
      args:
        - |
          ${test_command}
EOF

if [[ "${STORAGE_SMOKE_VOLUME_MODE}" == "Filesystem" ]]; then
  cat >>"${manifest}" <<EOF
      volumeMounts:
        - name: test-volume
          mountPath: /data
EOF
else
  cat >>"${manifest}" <<EOF
      volumeDevices:
        - name: test-volume
          devicePath: /dev/test-volume
EOF
fi

cat >>"${manifest}" <<EOF
  volumes:
    - name: test-volume
      persistentVolumeClaim:
        claimName: ${claim_name}
EOF

case "${action}" in
  plan)
    server_dry_run_manifest "${manifest}" "${TEST_NAMESPACE}"
    echo "Rendered ${manifest}"
    ;;
  apply)
    require_confirmation CONFIRM_APPLY "${CLUSTER_NAME}"
    oc apply -f "${manifest}"
    oc -n "${TEST_NAMESPACE}" wait --for=jsonpath='{.status.phase}'=Bound \
      "pvc/${claim_name}" --timeout=5m
    oc -n "${TEST_NAMESPACE}" wait --for=jsonpath='{.status.phase}'=Succeeded \
      "pod/${pod_name}" --timeout=5m
    oc -n "${TEST_NAMESPACE}" logs "pod/${pod_name}"
    oc -n "${TEST_NAMESPACE}" get pvc,pod -o wide
    ;;
  delete)
    require_confirmation CONFIRM_DELETE "${CLUSTER_NAME}"
    oc -n "${TEST_NAMESPACE}" delete pod "${pod_name}" --ignore-not-found
    oc -n "${TEST_NAMESPACE}" delete pvc "${claim_name}" --ignore-not-found
    ;;
esac
