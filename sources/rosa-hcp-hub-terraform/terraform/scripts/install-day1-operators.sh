#!/usr/bin/env bash
# Install day-1 OLM operators (OpenShift GitOps + External Secrets) against the
# newly created ROSA HCP hub, wait for CSVs to succeed, then lock Subscriptions
# to installPlanApproval=Manual so subsequent upgrades need explicit approval.
#
# Required env:
#   CLUSTER_API_URL  - https://api.<cluster>...:443
#   OC_USERNAME      - cluster-admin username (htpasswd sandbox admin by default)
#   OC_PASSWORD      - password for OC_USERNAME
#   MANIFESTS_DIR    - directory containing operator YAML manifests
set -euo pipefail

: "${CLUSTER_API_URL:?CLUSTER_API_URL is required}"
: "${OC_USERNAME:?OC_USERNAME is required}"
: "${OC_PASSWORD:?OC_PASSWORD is required}"
: "${MANIFESTS_DIR:?MANIFESTS_DIR is required}"

if ! command -v oc >/dev/null 2>&1; then
  echo "error: oc is required on PATH to install day-1 operators" >&2
  exit 1
fi

KUBECONFIG="$(mktemp)"
export KUBECONFIG
trap 'rm -f "${KUBECONFIG}"' EXIT

login_retries="${OC_LOGIN_RETRIES:-60}"
login_sleep="${OC_LOGIN_SLEEP_SECONDS:-10}"
csv_timeout="${CSV_WAIT_TIMEOUT_SECONDS:-900}"

echo "==> Waiting for API/OAuth readiness and logging in as ${OC_USERNAME}"
logged_in=0
for ((i = 1; i <= login_retries; i++)); do
  if oc login "${CLUSTER_API_URL}" \
    -u "${OC_USERNAME}" \
    -p "${OC_PASSWORD}" \
    --insecure-skip-tls-verify=true \
    >/dev/null 2>&1; then
    logged_in=1
    break
  fi
  echo "    login attempt ${i}/${login_retries} failed; sleeping ${login_sleep}s"
  sleep "${login_sleep}"
done

if [[ "${logged_in}" -ne 1 ]]; then
  cat >&2 <<EOF
error: could not oc login to ${CLUSTER_API_URL} as ${OC_USERNAME} after ${login_retries} attempts.

If private_cluster=true, the API has no public endpoint. Ensure this Terraform
runner can reach the API (VPN/TGW, or an active SSM port-forward via the bastion
— see README "Connecting to a private cluster via the bastion host") before
re-running apply, or temporarily set private_cluster=false for a public API.
EOF
  exit 1
fi

echo "==> Applying day-1 operator manifests from ${MANIFESTS_DIR}"
oc apply -f "${MANIFESTS_DIR}"

wait_for_csv() {
  local namespace="$1"
  local elapsed=0
  local phase=""

  echo "==> Waiting for CSV Succeeded in namespace ${namespace} (timeout ${csv_timeout}s)"
  while ((elapsed < csv_timeout)); do
    phase="$(oc get csv -n "${namespace}" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
    if [[ "${phase}" == "Succeeded" ]]; then
      echo "    ${namespace}: CSV phase=Succeeded"
      return 0
    fi
    echo "    ${namespace}: CSV phase=${phase:-<none yet>}; sleeping 15s"
    sleep 15
    elapsed=$((elapsed + 15))
  done

  echo "error: timed out waiting for CSV Succeeded in ${namespace}" >&2
  oc get csv,subscription,installplan -n "${namespace}" >&2 || true
  return 1
}

wait_for_csv "openshift-gitops-operator"
wait_for_csv "external-secrets-operator"

echo "==> Setting installPlanApproval=Manual on day-1 Subscriptions"
oc patch subscription openshift-gitops-operator \
  -n openshift-gitops-operator \
  --type merge \
  -p '{"spec":{"installPlanApproval":"Manual"}}'

oc patch subscription openshift-external-secrets-operator \
  -n external-secrets-operator \
  --type merge \
  -p '{"spec":{"installPlanApproval":"Manual"}}'

echo "==> Day-1 operators installed; Subscriptions locked to Manual approval"
oc get subscription -n openshift-gitops-operator openshift-gitops-operator \
  -o jsonpath='{.metadata.name}{" installPlanApproval="}{.spec.installPlanApproval}{"\n"}'
oc get subscription -n external-secrets-operator openshift-external-secrets-operator \
  -o jsonpath='{.metadata.name}{" installPlanApproval="}{.spec.installPlanApproval}{"\n"}'
