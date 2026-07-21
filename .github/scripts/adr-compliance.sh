#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${ROOT_DIR}"

failures=0

error() {
  echo "ERROR: $*"
  failures=1
}

check_required_dirs() {
  for dir in sources clusters profiles docs/adr; do
    if [[ ! -d "${dir}" ]]; then
      error "Required directory missing: ${dir}"
    fi
  done
}

check_sources_entry_points() {
  while IFS= read -r source_dir; do
    [[ -z "${source_dir}" ]] && continue

    if [[ -f "${source_dir}/kustomization.yaml" || -f "${source_dir}/kustomization.yml" || -f "${source_dir}/Chart.yaml" || -f "${source_dir}/Chart.yml" ]]; then
      continue
    fi

    if rg -n --glob '*.yaml' --glob '*.yml' '^\s*apiVersion:' "${source_dir}" >/dev/null 2>&1; then
      continue
    fi

    error "sources entry has no recognized entry point: ${source_dir}"
  done < <(find sources -mindepth 1 -maxdepth 1 -type d | sort)
}

check_cluster_gates() {
  local rfc1123='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
  local prod_pattern='^[a-z0-9]+-[a-z0-9]+-(prod|prd)-[0-9]+$'

  while IFS= read -r cluster_dir; do
    [[ -z "${cluster_dir}" ]] && continue

    local cluster_name
    cluster_name="$(basename "${cluster_dir}")"

    if [[ ! -f "${cluster_dir}/app-of-apps.yaml" ]]; then
      error "Missing required gate file: ${cluster_dir}/app-of-apps.yaml"
    fi

    if [[ "${cluster_name}" == *"-prod-"* || "${cluster_name}" == *"-prd-"* ]]; then
      if [[ ! "${cluster_name}" =~ ${prod_pattern} ]]; then
        error "Production cluster directory name does not match <dc>-<type>-<env>-<n>: ${cluster_name}"
      fi
    fi

    while IFS= read -r gate_file; do
      local filename
      local gate_name
      filename="$(basename "${gate_file}")"
      gate_name="${filename%.yaml}"

      if [[ ! "${gate_name}" =~ ${rfc1123} ]]; then
        error "Gate file name is not RFC1123 compatible: ${filename}"
      fi

      python3 - "${gate_file}" <<'PY'
import sys
import yaml

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    docs = list(yaml.safe_load_all(handle))

allowed = {"metadata", "spec"}
for index, doc in enumerate(docs):
    if doc in (None, {}):
        continue
    if not isinstance(doc, dict):
        print(f"ERROR: {path} document {index + 1} must be a mapping")
        sys.exit(2)
    extra_keys = set(doc.keys()) - allowed
    if extra_keys:
        joined = ", ".join(sorted(extra_keys))
        print(f"ERROR: {path} has unsupported top-level key(s): {joined}")
        sys.exit(2)
PY
      if [[ $? -ne 0 ]]; then
        failures=1
      fi
    done < <(find "${cluster_dir}" -maxdepth 1 -type f -name '*.yaml' | sort)
  done < <(find clusters -mindepth 1 -maxdepth 1 -type d | sort)
}

check_prohibited_patterns() {
  if rg -n 'startingCSV' sources >/dev/null 2>&1; then
    error "Found prohibited startingCSV in sources/"
  fi

  if rg -n 'name:\s*in-cluster' sources clusters >/dev/null 2>&1; then
    error "Found prohibited Argo destination name in-cluster"
  fi
}

main() {
  check_required_dirs
  check_sources_entry_points
  check_cluster_gates
  check_prohibited_patterns

  if [[ "${failures}" -ne 0 ]]; then
    echo "ADR compliance checks failed."
    exit 1
  fi

  echo "ADR compliance checks passed."
}

main "$@"
