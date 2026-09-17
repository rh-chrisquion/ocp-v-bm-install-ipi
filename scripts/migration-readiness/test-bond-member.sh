#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

test_result=FAIL
print_result() {
  status=$?
  if [[ "${test_result}" == "PASS" && ${status} -eq 0 ]]; then
    echo "RESULT: PASS - ${RESILIENCY_NODE} ${RESILIENCY_BOND}/${RESILIENCY_MEMBER} maintained ${RESILIENCY_PEER_IP}:${RESILIENCY_PEER_PORT} connectivity"
  else
    echo "RESULT: FAIL - bond-member resiliency test did not complete successfully" >&2
  fi
}
trap print_result EXIT

if [[ "${1:-}" != "--execute" ]]; then
  echo "Usage: CONFIRM_NETWORK_DISRUPTION=${CLUSTER_NAME} $0 --execute" >&2
  exit 2
fi

for variable_name in \
  RESILIENCY_NODE \
  RESILIENCY_BOND \
  RESILIENCY_MEMBER \
  RESILIENCY_PEER_IP \
  RESILIENCY_PEER_PORT
do
  require_value "${variable_name}"
done
require_confirmation CONFIRM_NETWORK_DISRUPTION "${CLUSTER_NAME}"
verify_cluster_context >/dev/null
initialize_results bond-member

not_ready=$(oc get nodes --no-headers | awk '$2 != "Ready" {count++} END {print count+0}')
if (( not_ready != 0 )); then
  echo "Refusing link test while ${not_ready} node(s) are not Ready" >&2
  exit 1
fi

oc get node "${RESILIENCY_NODE}" >/dev/null

etcd_pod=$(oc -n openshift-etcd get pods -l app=etcd \
  -o jsonpath='{.items[0].metadata.name}')
oc -n openshift-etcd exec "${etcd_pod}" -- \
  etcdctl endpoint health --cluster -w table

host_script=$(cat <<'HOST_SCRIPT'
set -euo pipefail

bond=$1
member=$2
peer_ip=$3
outage_seconds=$4
ping_interval=$5
max_packet_loss=$6
peer_port=$7
max_tcp_failures=$8
ping_output=$(mktemp)
ping_pid=""
member_disabled=false

restore_member() {
  if [[ "${member_disabled}" == "true" ]]; then
    ip link set dev "${member}" up || true
  fi
  if [[ -n "${ping_pid}" ]]; then
    kill "${ping_pid}" 2>/dev/null || true
    wait "${ping_pid}" 2>/dev/null || true
  fi
  exec 3>&- 3<&- || true
  rm -f "${ping_output}"
}
trap restore_member EXIT INT TERM

interface_uses_bond() {
  local interface=$1
  local candidate lower
  local -a pending=("${interface}")
  local -A visited=()

  while (( ${#pending[@]} > 0 )); do
    candidate=${pending[0]}
    pending=("${pending[@]:1}")
    [[ -n "${visited[${candidate}]:-}" ]] && continue
    visited["${candidate}"]=1
    [[ "${candidate}" == "${bond}" ]] && return 0

    for lower in /sys/class/net/"${candidate}"/lower_*; do
      [[ -e "${lower}" ]] || continue
      pending+=("${lower##*/lower_}")
    done
  done
  return 1
}

tcp_session_is_established() {
  awk -v inode="${tcp_socket_inode}" '
    NR > 1 && $4 == "01" && $10 == inode { found=1 }
    END { exit !found }
  ' /proc/net/tcp /proc/net/tcp6
}

tcp_connect() {
  timeout 2 bash -c 'exec 9<>"/dev/tcp/$1/$2"' -- \
    "${peer_ip}" "${peer_port}"
}

member_mii_status() {
  awk -v wanted="${member}" '
    /^Slave Interface:/ { current=$3; next }
    current == wanted && /^MII Status:/ { print $3; exit }
  ' "/proc/net/bonding/${bond}"
}

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
if (( up_members < 2 )); then
  echo "Refusing test: ${bond} has fewer than two up links" >&2
  exit 1
fi

route_output=$(ip route get "${peer_ip}")
echo "Route: ${route_output}"
route_interface=$(awk '{ for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit } }' \
  <<<"${route_output}")
if [[ -z "${route_interface}" ]] || ! interface_uses_bond "${route_interface}"; then
  echo "Refusing test: ${peer_ip} routes through ${route_interface:-unknown}, not ${bond} or an interface backed by it" >&2
  exit 1
fi

ping -I "${route_interface}" -c 5 -W 2 "${peer_ip}"
tcp_connect || {
  echo "Refusing test: cannot establish TCP connection to ${peer_ip}:${peer_port}" >&2
  exit 1
}

# Keep one exact TCP session open across the member outage. Its socket inode
# lets the test distinguish this session from existing iSCSI connections.
exec 3<>"/dev/tcp/${peer_ip}/${peer_port}"
tcp_socket_inode=$(readlink "/proc/$$/fd/3" | sed -n 's/^socket:\[\([0-9][0-9]*\)\]$/\1/p')
[[ -n "${tcp_socket_inode}" ]] || {
  echo "Could not identify the test TCP socket" >&2
  exit 1
}
tcp_session_is_established || {
  echo "Test TCP session is not established before disruption" >&2
  exit 1
}
echo "TCP session established: ${peer_ip}:${peer_port} inode=${tcp_socket_inode}"

echo "Before failure"
cat "/proc/net/bonding/${bond}"

ping_count=$(awk -v duration="$((outage_seconds + 10))" -v interval="${ping_interval}" \
  'BEGIN { print int(duration / interval) + 1 }')
ping -D -I "${route_interface}" -i "${ping_interval}" -c "${ping_count}" -W 2 "${peer_ip}" \
  >"${ping_output}" 2>&1 &
ping_pid=$!
sleep 2

echo "Disabling ${member} for ${outage_seconds}s"
ip link set dev "${member}" down
member_disabled=true
sleep 1

[[ "$(cat "/sys/class/net/${bond}/carrier")" == "1" ]] || {
  echo "Bond ${bond} lost carrier after disabling ${member}" >&2
  exit 1
}
[[ "$(member_mii_status)" == "down" ]] || {
  echo "Selected member ${member} did not enter MII down state" >&2
  exit 1
}
echo "Selected member is down and ${bond} remains operational"

tcp_failures=0
for ((second=2; second<=outage_seconds; second++)); do
  sleep 1
  if ! tcp_session_is_established; then
    echo "Persistent TCP session left ESTABLISHED state during outage" >&2
    exit 1
  fi
  if tcp_connect; then
    echo "TCP probe ${second}: PASS"
  else
    echo "TCP probe ${second}: FAIL"
    ((tcp_failures += 1))
  fi
done

ip link set dev "${member}" up
member_disabled=false
for ((attempt=1; attempt<=30; attempt++)); do
  [[ "$(member_mii_status)" == "up" ]] && break
  sleep 1
done
[[ "$(member_mii_status)" == "up" ]] || {
  echo "Member ${member} did not rejoin ${bond} within 30 seconds" >&2
  exit 1
}
sleep 8
wait "${ping_pid}" || true
ping_pid=""
cat "${ping_output}"

if ! tcp_session_is_established; then
  echo "Persistent TCP session did not survive the member outage" >&2
  exit 1
fi
if (( tcp_failures > max_tcp_failures )); then
  echo "TCP failures ${tcp_failures} exceed allowed ${max_tcp_failures}" >&2
  exit 1
fi
echo "Persistent TCP session survived; outage TCP failures=${tcp_failures}"

packet_loss=$(sed -n 's/.* \([0-9.][0-9.]*\)% packet loss.*/\1/p' \
  "${ping_output}" | tail -n 1)
if [[ -z "${packet_loss}" ]]; then
  echo "Could not determine packet loss" >&2
  exit 1
fi
if ! awk -v actual="${packet_loss}" -v maximum="${max_packet_loss}" \
  'BEGIN { exit !(actual <= maximum) }'; then
  echo "Packet loss ${packet_loss}% exceeds ${max_packet_loss}%" >&2
  exit 1
fi

echo "After recovery"
cat "/proc/net/bonding/${bond}"
ip -s link show dev "${member}"
ping -I "${route_interface}" -c 5 -W 2 "${peer_ip}"
tcp_connect
HOST_SCRIPT
)

# Some supported oc clients do not expose stdin forwarding for `oc debug`.
# Pass the script as a single bash -c argument so the safety checks and restore
# trap work consistently across client versions.
oc debug "node/${RESILIENCY_NODE}" --quiet -- chroot /host bash -c \
  "${host_script}" -- \
  "${RESILIENCY_BOND}" "${RESILIENCY_MEMBER}" "${RESILIENCY_PEER_IP}" \
  "${RESILIENCY_OUTAGE_SECONDS}" "${RESILIENCY_PING_INTERVAL_SECONDS}" \
  "${RESILIENCY_MAX_PACKET_LOSS_PERCENT}" "${RESILIENCY_PEER_PORT}" \
  "${RESILIENCY_MAX_TCP_FAILURES}" |
  tee "${MIGRATION_READINESS_RUN_DIR}/bond-member.log"

oc wait --for=condition=Ready "node/${RESILIENCY_NODE}" --timeout=5m
oc get nodes -o wide | tee -a "${MIGRATION_READINESS_RUN_DIR}/bond-member.log"
test_result=PASS
