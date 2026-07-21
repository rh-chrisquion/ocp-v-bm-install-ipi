#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REQUIRED_TOOLS=(terraform tflint tfsec checkov jq)

tool_missing() {
  ! command -v "$1" >/dev/null 2>&1
}

print_versions() {
  echo
  echo "Installed tool versions:"
  terraform version
  tflint --version
  tfsec --version
  checkov --version
  jq --version
}

install_with_brew() {
  local package

  if ! command -v brew >/dev/null 2>&1; then
    echo "ERROR: Homebrew is required to auto-install Terraform test dependencies on this host." >&2
    echo "Install Homebrew first: https://brew.sh" >&2
    exit 1
  fi

  for package in "${REQUIRED_TOOLS[@]}"; do
    if tool_missing "${package}"; then
      echo "Installing ${package} with Homebrew..."
      brew install "${package}"
    else
      echo "${package} already installed."
    fi
  done
}

main() {
  case "$(uname -s)" in
    Darwin|Linux)
      install_with_brew
      ;;
    *)
      echo "ERROR: Unsupported OS $(uname -s)." >&2
      echo "Install tools manually: ${REQUIRED_TOOLS[*]}" >&2
      exit 1
      ;;
  esac

  print_versions

  cat <<EOF

Terraform test dependencies are ready.

Suggested next steps:
  cd "${REPO_ROOT}/sources/rosa-hcp-hub-terraform/terraform"
  terraform fmt -check
  terraform init
  terraform validate
  tflint --init
  tflint
  tfsec .
  checkov -d .
EOF
}

main "$@"
