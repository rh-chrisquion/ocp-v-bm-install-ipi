#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENV_DIR="${1:-${REPO_ROOT}/.venv}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
REQUIREMENTS_FILE="${REPO_ROOT}/requirements-dev.txt"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
  echo "ERROR: Python binary not found: ${PYTHON_BIN}" >&2
  echo "Set PYTHON_BIN to a valid interpreter (for example: PYTHON_BIN=python3.12)." >&2
  exit 1
fi

if [[ ! -f "${REQUIREMENTS_FILE}" ]]; then
  echo "ERROR: Requirements file not found: ${REQUIREMENTS_FILE}" >&2
  exit 1
fi

echo "Creating virtual environment at: ${VENV_DIR}"
"${PYTHON_BIN}" -m venv "${VENV_DIR}"

# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"

echo "Upgrading pip/setuptools/wheel..."
python -m pip install --upgrade pip setuptools wheel

echo "Installing Python dependencies from ${REQUIREMENTS_FILE}..."
python -m pip install -r "${REQUIREMENTS_FILE}"

cat <<EOF

Virtual environment is ready.

Activate it with:
  source "${VENV_DIR}/bin/activate"

Optional quick checks:
  ansible-playbook --version
  yamllint --version
  python -c "import yaml; print(yaml.__version__)"
EOF
