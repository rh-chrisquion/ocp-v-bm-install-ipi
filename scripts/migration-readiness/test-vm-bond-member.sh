#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

if [[ "${1:-}" != "--execute" ]]; then
  echo "Usage: CONFIRM_NETWORK_DISRUPTION=${CLUSTER_NAME} $0 --execute" >&2
  exit 2
fi

for variable_name in \
  VM_RESILIENCY_NAMESPACE VM_RESILIENCY_NAME VM_RESILIENCY_SSH_USER \
  VM_RESILIENCY_SSH_IDENTITY_FILE VM_RESILIENCY_NETWORK_NAME \
  VM_RESILIENCY_GUEST_INTERFACE VM_RESILIENCY_TARGET_HOST \
  VM_RESILIENCY_TARGET_PORT VM_RESILIENCY_BOND VM_RESILIENCY_MEMBER \
  VM_RESILIENCY_TEST_DURATION_SECONDS VM_RESILIENCY_MAX_TCP_FAILURES
do
  require_value "${variable_name}"
done
require_confirmation CONFIRM_NETWORK_DISRUPTION "${CLUSTER_NAME}"
require_command virtctl
require_command jq
verify_cluster_context >/dev/null
initialize_results vm-bond-member

[[ -r "${VM_RESILIENCY_SSH_IDENTITY_FILE}" ]] || {
  echo "SSH identity file is not readable: ${VM_RESILIENCY_SSH_IDENTITY_FILE}" >&2
  exit 1
}
(( VM_RESILIENCY_TEST_DURATION_SECONDS >= RESILIENCY_OUTAGE_SECONDS + 20 )) || {
  echo "VM_RESILIENCY_TEST_DURATION_SECONDS must cover the outage plus at least 20 seconds" >&2
  exit 1
}

not_ready=$(oc get nodes --no-headers | awk '$2 != "Ready" {count++} END {print count+0}')
(( not_ready == 0 )) || {
  echo "Refusing link test while ${not_ready} node(s) are not Ready" >&2
  exit 1
}

vmi_json=$(oc get vmi "${VM_RESILIENCY_NAME}" \
  -n "${VM_RESILIENCY_NAMESPACE}" -o json)
vmi_phase=$(jq -r '.status.phase // ""' <<<"${vmi_json}")
vmi_node=$(jq -r '.status.nodeName // ""' <<<"${vmi_json}")
[[ "${vmi_phase}" == "Running" && -n "${vmi_node}" ]] || {
  echo "VMI ${VM_RESILIENCY_NAMESPACE}/${VM_RESILIENCY_NAME} is not running" >&2
  exit 1
}
jq -e --arg network "${VM_RESILIENCY_NETWORK_NAME}" \
  '.spec.networks[]? | select(.name == $network)' <<<"${vmi_json}" >/dev/null || {
  echo "VMI does not have network ${VM_RESILIENCY_NETWORK_NAME}" >&2
  exit 1
}

etcd_pod=$(oc -n openshift-etcd get pods -l app=etcd \
  -o jsonpath='{.items[0].metadata.name}')
oc -n openshift-etcd exec "${etcd_pod}" -- \
  etcdctl endpoint health --cluster -w table

guest_log="${MIGRATION_READINESS_RUN_DIR}/vm-traffic.log"
host_log="${MIGRATION_READINESS_RUN_DIR}/vm-bond-member.log"

guest_script=$(cat <<'GUEST_SCRIPT'
set -euo pipefail
target_host=$1
target_port=$2
expected_interface=$3
duration=$4

command -v timeout >/dev/null
target_ip=$(getent ahostsv4 "${target_host}" | awk 'NR == 1 { print $1 }')
[[ -n "${target_ip}" ]] || {
  echo "Unable to resolve target: ${target_host}" >&2
  exit 1
}
route=$(ip route get "${target_ip}")
echo "ROUTE ${route}"
grep -Eq "dev ${expected_interface}([[:space:]]|$)" <<<"${route}" || {
  echo "Target does not route through ${expected_interface}" >&2
  exit 1
}

probe() {
  timeout 2 bash -c 'exec 9<>"/dev/tcp/$1/$2"' -- \
    "${target_ip}" "${target_port}"
}

probe || {
  echo "Baseline TCP connection failed: ${target_ip}:${target_port}" >&2
  exit 1
}
echo "READY target=${target_ip}:${target_port} interface=${expected_interface}"

for ((second=1; second<=duration; second++)); do
  if probe; then
    echo "$(date -u +%FT%TZ) PROBE ${second} PASS"
  else
    echo "$(date -u +%FT%TZ) PROBE ${second} FAIL"
  fi
  sleep 1
done
GUEST_SCRIPT
)

virtctl -n "${VM_RESILIENCY_NAMESPACE}" ssh \
  "${VM_RESILIENCY_SSH_USER}@vm/${VM_RESILIENCY_NAME}" \
  -i "${VM_RESILIENCY_SSH_IDENTITY_FILE}" \
  --local-ssh-opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
  -c "bash -c $(printf '%q' "${guest_script}") -- \
$(printf '%q' "${VM_RESILIENCY_TARGET_HOST}") \
$(printf '%q' "${VM_RESILIENCY_TARGET_PORT}") \
$(printf '%q' "${VM_RESILIENCY_GUEST_INTERFACE}") \
$(printf '%q' "${VM_RESILIENCY_TEST_DURATION_SECONDS}")" \
  >"${guest_log}" 2>&1 &
guest_pid=$!

cleanup() {
  kill "${guest_pid}" 2>/dev/null || true
  wait "${guest_pid}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

for ((attempt=1; attempt<=60; attempt++)); do
  grep -q '^READY ' "${guest_log}" 2>/dev/null && break
  kill -0 "${guest_pid}" 2>/dev/null || {
    cat "${guest_log}" >&2
    echo "VM traffic process exited before becoming ready" >&2
    exit 1
  }
  sleep 1
done
grep -q '^READY ' "${guest_log}" || {
  cat "${guest_log}" >&2
  echo "Timed out waiting for VM traffic readiness" >&2
  exit 1
}

host_script=$(cat <<'HOST_SCRIPT'
set -euo pipefail
bond=$1
member=$2
outage_seconds=$3
member_disabled=false

restore_member() {
  if [[ "${member_disabled}" == "true" ]]; then
    ip link set dev "${member}" up || true
  fi
}
trap restore_member EXIT INT TERM

test -r "/proc/net/bonding/${bond}" || {
  echo "Bond does not exist: ${bond}" >&2
  exit 1
}
test -e "/sys/class/net/${bond}/lower_${member}" || {
  echo "${member} is not a member of ${bond}" >&2
  exit 1
}
up_members=$(awk '
  /^Slave Interface:/ { in_slave=1; next }
  in_slave && /^MII Status:/ {
    if ($3 == "up") count++
    in_slave=0
  }
  END { print count+0 }
' "/proc/net/bonding/${bond}")
(( up_members >= 2 )) || {
  echo "Refusing test: ${bond} has fewer than two up links" >&2
  exit 1
}

echo "Before failure"
cat "/proc/net/bonding/${bond}"
echo "Disabling ${member} for ${outage_seconds}s"
ip link set dev "${member}" down
member_disabled=true
sleep 1
[[ "$(cat "/sys/class/net/${bond}/carrier")" == "1" ]] || {
  echo "Bond ${bond} lost carrier" >&2
  exit 1
}
member_status=$(awk -v wanted="${member}" '
  /^Slave Interface:/ { current=$3; next }
  current == wanted && /^MII Status:/ { print $3; exit }
' "/proc/net/bonding/${bond}")
[[ "${member_status}" == "down" ]] || {
  echo "Selected member ${member} did not enter MII down state" >&2
  exit 1
}
echo "Selected member is down and ${bond} remains operational"
sleep "$((outage_seconds - 1))"
ip link set dev "${member}" up
member_disabled=false

for ((attempt=1; attempt<=30; attempt++)); do
  status=$(awk -v wanted="${member}" '
    /^Slave Interface:/ { current=$3; next }
    current == wanted && /^MII Status:/ { print $3; exit }
  ' "/proc/net/bonding/${bond}")
  [[ "${status}" == "up" ]] && break
  sleep 1
done
[[ "${status:-}" == "up" ]] || {
  echo "Member ${member} did not rejoin ${bond} within 30 seconds" >&2
  exit 1
}
echo "After recovery"
cat "/proc/net/bonding/${bond}"
HOST_SCRIPT
)

oc debug "node/${vmi_node}" --quiet -- chroot /host bash -c \
  "${host_script}" -- \
  "${VM_RESILIENCY_BOND}" "${VM_RESILIENCY_MEMBER}" \
  "${RESILIENCY_OUTAGE_SECONDS}" | tee "${host_log}"

wait "${guest_pid}" || {
  cat "${guest_log}" >&2
  echo "VM traffic process failed" >&2
  exit 1
}
guest_pid=""
cat "${guest_log}"

tcp_failures=$(awk '$2 == "PROBE" && $4 == "FAIL" { count++ } END { print count+0 }' \
  "${guest_log}")
(( tcp_failures <= VM_RESILIENCY_MAX_TCP_FAILURES )) || {
  echo "VM TCP failures ${tcp_failures} exceed allowed ${VM_RESILIENCY_MAX_TCP_FAILURES}" >&2
  exit 1
}

oc wait --for=condition=Ready "node/${vmi_node}" --timeout=5m
echo "PASS: VM traffic survived ${VM_RESILIENCY_MEMBER} failure; TCP failures=${tcp_failures}"
