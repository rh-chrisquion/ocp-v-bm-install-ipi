#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_command curl
verify_cluster_context >/dev/null
initialize_results network-path

api_url=$(oc whoami --show-server)
targets=("${api_url%/}/readyz")
for target in ${NETWORK_TEST_URLS:-}; do
  targets+=("${target}")
done

end_time=$((SECONDS + NETWORK_TEST_DURATION_SECONDS))
successes=0
failures=0
report="${MIGRATION_READINESS_RUN_DIR}/network-path.tsv"
printf 'timestamp\ttarget\thttp_code\tconnect_seconds\ttotal_seconds\tresult\n' >"${report}"

curl_tls_args=()
if [[ "${NETWORK_TEST_INSECURE:-false}" == "true" ]]; then
  curl_tls_args+=(--insecure)
fi

while (( SECONDS < end_time )); do
  for target in "${targets[@]}"; do
    metrics=$(curl --noproxy '*' --silent --show-error "${curl_tls_args[@]}" \
      --output /dev/null --connect-timeout 5 --max-time 10 \
      --write-out '%{http_code}\t%{time_connect}\t%{time_total}' \
      "${target}" 2>/dev/null) && status=pass || status=fail
    if [[ "${status}" == "pass" ]]; then
      ((successes += 1))
    else
      ((failures += 1))
      metrics="000\t0\t0"
    fi
    printf '%s\t%s\t%b\t%s\n' "$(date -u +%FT%TZ)" "${target}" \
      "${metrics}" "${status}" | tee -a "${report}"
  done
  sleep "${NETWORK_TEST_INTERVAL_SECONDS}"
done

echo "successes=${successes} failures=${failures} report=${report}"
(( failures == 0 ))
