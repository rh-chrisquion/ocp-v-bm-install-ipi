#!/usr/bin/env bash

set -euo pipefail

MIGRATION_READINESS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd "${MIGRATION_READINESS_DIR}/../.." && pwd)

if [[ -z "${MIGRATION_READINESS_CONFIG:-}" ]]; then
  echo "No cluster configuration selected." >&2
  echo "Use migration-readiness.sh --config <file> <command>." >&2
  exit 1
fi
if [[ ! -f "${MIGRATION_READINESS_CONFIG}" ]]; then
  echo "Configuration file not found: ${MIGRATION_READINESS_CONFIG}" >&2
  exit 1
fi
MIGRATION_READINESS_CONFIG=$(cd "$(dirname "${MIGRATION_READINESS_CONFIG}")" && pwd)/$(basename "${MIGRATION_READINESS_CONFIG}")

# Configuration files are trusted shell input. Export their values so diagnostic
# subshells use the same selected cluster profile.
set -a
# shellcheck source=/dev/null
source "${MIGRATION_READINESS_CONFIG}"
set +a

require_command() {
  local command_name=$1
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "Required command is unavailable: ${command_name}" >&2
    exit 1
  }
}

require_value() {
  local variable_name=$1
  local value=${!variable_name:-}
  if [[ -z "${value}" || "${value}" == *REPLACE_ME* ]]; then
    echo "Required configuration value is empty or unresolved: ${variable_name}" >&2
    exit 1
  fi
}

verify_cluster_context() {
  require_command oc

  local current_server
  current_server=$(oc whoami --show-server 2>/dev/null) || {
    echo "No usable OpenShift login is active." >&2
    exit 1
  }

  if [[ "${current_server}" != *"${EXPECTED_API_HOST_FRAGMENT}"* ]] &&
     [[ "${ALLOW_CONTEXT_MISMATCH:-false}" != "true" ]]; then
    echo "Refusing to use unexpected cluster context: ${current_server}" >&2
    echo "Expected API hostname to contain: ${EXPECTED_API_HOST_FRAGMENT}" >&2
    echo "Set ALLOW_CONTEXT_MISMATCH=true only after reviewing the target." >&2
    exit 1
  fi

  printf '%s\n' "${current_server}"
}

initialize_results() {
  local run_kind=$1
  local run_id
  run_id=$(date -u +%Y%m%dT%H%M%SZ)

  if [[ -z "${MIGRATION_READINESS_RUN_DIR:-}" ]]; then
    MIGRATION_READINESS_RUN_DIR="${REPOSITORY_ROOT}/.artifacts/migration-readiness/${CLUSTER_NAME}/${run_id}-${run_kind}"
  fi
  export MIGRATION_READINESS_RUN_DIR
  mkdir -p "${MIGRATION_READINESS_RUN_DIR}"
}

section() {
  printf '\n===== %s =====\n' "$*"
}

capture() {
  local label=$1
  shift
  local output_file="${MIGRATION_READINESS_RUN_DIR}/${label}.log"
  local status

  section "${label}"
  set +e
  "$@" 2>&1 | tee "${output_file}"
  status=${PIPESTATUS[0]}
  set -e

  printf '%s\t%s\n' "${label}" "${status}" >>"${MIGRATION_READINESS_RUN_DIR}/command-status.tsv"
  return 0
}

capture_shell() {
  local label=$1
  local command_text=$2
  capture "${label}" bash -o pipefail -c "${command_text}"
}

require_confirmation() {
  local variable_name=$1
  local expected_value=$2
  if [[ "${!variable_name:-}" != "${expected_value}" ]]; then
    echo "Refusing requested change." >&2
    echo "Set ${variable_name}=${expected_value} after reviewing the command and target." >&2
    exit 1
  fi
}

server_dry_run_manifest() {
  local manifest=$1
  local target_namespace=$2
  local validation_namespace=${PLAN_NAMESPACE:-default}
  local namespace_manifest="${MIGRATION_READINESS_RUN_DIR}/namespace-server-dry-run.yaml"
  local namespaced_manifest="${MIGRATION_READINESS_RUN_DIR}/resources-server-dry-run.yaml"

  if oc get namespace "${target_namespace}" >/dev/null 2>&1; then
    oc apply --dry-run=server -f "${manifest}"
    return
  fi

  # A dry-run Namespace is not persisted, so subsequent documents cannot be
  # admitted in it. Validate that request separately, then validate namespaced
  # resources in an existing namespace without changing the apply manifest.
  oc get namespace "${validation_namespace}" >/dev/null || {
    echo "PLAN_NAMESPACE does not exist: ${validation_namespace}" >&2
    exit 1
  }

  awk '/^---[[:space:]]*$/ { exit } { print }' \
    "${manifest}" >"${namespace_manifest}"

  awk '
    BEGIN { document = 1 }
    /^---[[:space:]]*$/ {
      document++
      if (document > 2) print "---"
      next
    }
    document > 1 { print }
  ' "${manifest}" |
    sed "s/namespace: ${target_namespace}/namespace: ${validation_namespace}/g" \
      >"${namespaced_manifest}"

  oc apply --dry-run=server -f "${namespace_manifest}"
  oc apply --dry-run=server -f "${namespaced_manifest}"
  echo "Test namespace is absent; namespaced resources were server-dry-run in ${validation_namespace}."
  echo "The apply manifest still targets ${target_namespace}."
}
