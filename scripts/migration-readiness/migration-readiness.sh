#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  cat <<'EOF'
Usage: migration-readiness.sh --config <file> <command> [arguments]

Commands:
  validate [--offline]        Validate configuration and optional current context
  collect [--host]            Collect API and optional host diagnostics
  assess                      Evaluate migration prerequisites
  storage [plan|apply|delete] Render or run the disposable storage test
  configure-vm [render|plan|apply|delete]
                              Render or manage the disposable migration VM
  migrate --execute           Execute one live migration
  network-path                Measure API and configured endpoint availability
  bond-member --execute       Temporarily disable one reviewed bond member
  vm-bond-member --execute    Test VM TCP traffic during a bond-member outage
  network-suite --execute     Run the complete configured network test suite
EOF
}

if [[ "${1:-}" != "--config" || -z "${2:-}" || -z "${3:-}" ]]; then
  usage >&2
  exit 2
fi

config=$2
command_name=$3
shift 3

if [[ "${config}" != /* ]]; then
  config="${PWD}/${config}"
fi
export MIGRATION_READINESS_CONFIG="${config}"

case "${command_name}" in
  validate) script=validate-config.sh ;;
  collect) script=collect.sh ;;
  assess) script=assess-readiness.sh ;;
  storage) script=test-storage.sh ;;
  configure-vm) script=configure-migration-test.sh ;;
  migrate) script=test-live-migration.sh ;;
  network-path) script=test-network-path.sh ;;
  bond-member) script=test-bond-member.sh ;;
  vm-bond-member) script=test-vm-bond-member.sh ;;
  network-suite) script=test-network-suite.sh ;;
  *)
    echo "Unknown command: ${command_name}" >&2
    usage >&2
    exit 2
    ;;
esac

exec "${SCRIPT_DIR}/${script}" "$@"
