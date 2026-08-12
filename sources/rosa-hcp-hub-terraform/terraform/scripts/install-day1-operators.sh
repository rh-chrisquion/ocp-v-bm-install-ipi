#!/usr/bin/env bash
# Install day-1 OLM operators (OpenShift GitOps + External Secrets) against the
# newly created ROSA HCP hub, wait for CSVs to succeed, lock Subscriptions to
# installPlanApproval=Manual, then (when ESO_IAM_ROLE_ARN is set) deploy the
# External Secrets operand, annotate the IRSA ServiceAccount, and create the
# ClusterSecretStore for AWS Secrets Manager.
#
# Required env:
#   CLUSTER_API_URL  - https://api.<cluster>...:443
#   OC_USERNAME      - cluster-admin username (htpasswd sandbox admin by default)
#   OC_PASSWORD      - password for OC_USERNAME
#   MANIFESTS_DIR    - directory containing operator YAML manifests
#
# Optional env (ESO ClusterSecretStore / IRSA):
#   CONFIGURE_GITOPS_APPSET - "true" to register repo + apply operators appset
#   GITOPS_MANIFESTS_DIR    - directory containing gitops bootstrap templates
#   GITOPS_APP_OF_APPS_REPO_URL - git repo URL to register/use in appset
#   GITOPS_APP_OF_APPS_REPO_REVISION - git revision for generator/source
#   GITOPS_REPOSITORY_SECRET_NAME - Argo CD repository secret name
#   ESO_IAM_ROLE_ARN       - IAM role ARN for IRSA (skips ESO config when unset)
#   ESO_MANIFESTS_DIR      - directory with ExternalSecretsConfig + ClusterSecretStore
#   AWS_REGION             - region written into ClusterSecretStore (default us-east-2)
#   ESO_NAMESPACE          - operand namespace (default external-secrets)
#   ESO_SERVICE_ACCOUNT    - SA to annotate (default external-secrets)
#   ESO_CLUSTER_SECRET_STORE - ClusterSecretStore name (default aws-secrets-manager)
#   ESO_RUN_E2E_TEST       - "true" to create/validate a test ExternalSecret
#   ESO_E2E_SECRET_NAME    - Secrets Manager secret name for e2e
#   ESO_E2E_SECRET_VALUE   - expected secret value for e2e
#   ESO_E2E_NAMESPACE      - namespace for the test ExternalSecret (default default)
set -euo pipefail

: "${CLUSTER_API_URL:?CLUSTER_API_URL is required}"
: "${OC_USERNAME:?OC_USERNAME is required}"
: "${OC_PASSWORD:?OC_PASSWORD is required}"
: "${MANIFESTS_DIR:?MANIFESTS_DIR is required}"

AWS_REGION="${AWS_REGION:-us-east-2}"
CONFIGURE_GITOPS_APPSET="${CONFIGURE_GITOPS_APPSET:-false}"
GITOPS_APP_OF_APPS_REPO_URL="${GITOPS_APP_OF_APPS_REPO_URL:-https://github.com/ravishar-rh/gitops-app-of-apps.git}"
GITOPS_APP_OF_APPS_REPO_REVISION="${GITOPS_APP_OF_APPS_REPO_REVISION:-main}"
GITOPS_REPOSITORY_SECRET_NAME="${GITOPS_REPOSITORY_SECRET_NAME:-repo-gitops-app-of-apps}"
ESO_NAMESPACE="${ESO_NAMESPACE:-external-secrets}"
ESO_SERVICE_ACCOUNT="${ESO_SERVICE_ACCOUNT:-external-secrets}"
ESO_CLUSTER_SECRET_STORE="${ESO_CLUSTER_SECRET_STORE:-aws-secrets-manager}"
ESO_RUN_E2E_TEST="${ESO_RUN_E2E_TEST:-false}"
ESO_E2E_NAMESPACE="${ESO_E2E_NAMESPACE:-default}"

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
pod_timeout="${ESO_POD_WAIT_TIMEOUT_SECONDS:-600}"
css_timeout="${CSS_WAIT_TIMEOUT_SECONDS:-300}"

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
# Top-level only (does not recurse into manifests/eso/).
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

# --- OpenShift GitOps repository + operators ApplicationSet (optional) ---
if [[ "${CONFIGURE_GITOPS_APPSET}" == "true" ]]; then
  : "${GITOPS_MANIFESTS_DIR:?GITOPS_MANIFESTS_DIR is required when CONFIGURE_GITOPS_APPSET=true}"
  if [[ ! -d "${GITOPS_MANIFESTS_DIR}" ]]; then
    echo "error: GITOPS_MANIFESTS_DIR does not exist: ${GITOPS_MANIFESTS_DIR}" >&2
    exit 1
  fi

  echo "==> Waiting for OpenShift GitOps namespace and ApplicationSet CRD"
  for i in $(seq 1 60); do
    if oc get ns openshift-gitops >/dev/null 2>&1 \
      && oc get crd applicationsets.argoproj.io >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done
  if ! oc get ns openshift-gitops >/dev/null 2>&1 || ! oc get crd applicationsets.argoproj.io >/dev/null 2>&1; then
    echo "error: openshift-gitops namespace or applicationsets.argoproj.io CRD not ready after wait" >&2
    exit 1
  fi

  echo "==> Applying Argo CD repository secret and operators ApplicationSet"
  export GITOPS_APP_OF_APPS_REPO_URL GITOPS_APP_OF_APPS_REPO_REVISION GITOPS_REPOSITORY_SECRET_NAME
  if command -v envsubst >/dev/null 2>&1; then
    envsubst '${GITOPS_APP_OF_APPS_REPO_URL} ${GITOPS_APP_OF_APPS_REPO_REVISION} ${GITOPS_REPOSITORY_SECRET_NAME}' \
      < "${GITOPS_MANIFESTS_DIR}/repository-secret.yaml" | oc apply -f -
    envsubst '${GITOPS_APP_OF_APPS_REPO_URL} ${GITOPS_APP_OF_APPS_REPO_REVISION} ${GITOPS_REPOSITORY_SECRET_NAME}' \
      < "${GITOPS_MANIFESTS_DIR}/operators-applicationset.yaml" | oc apply -f -
  else
    sed -e "s#\${GITOPS_APP_OF_APPS_REPO_URL}#${GITOPS_APP_OF_APPS_REPO_URL}#g" \
        -e "s#\${GITOPS_APP_OF_APPS_REPO_REVISION}#${GITOPS_APP_OF_APPS_REPO_REVISION}#g" \
        -e "s#\${GITOPS_REPOSITORY_SECRET_NAME}#${GITOPS_REPOSITORY_SECRET_NAME}#g" \
        "${GITOPS_MANIFESTS_DIR}/repository-secret.yaml" | oc apply -f -
    sed -e "s#\${GITOPS_APP_OF_APPS_REPO_URL}#${GITOPS_APP_OF_APPS_REPO_URL}#g" \
        -e "s#\${GITOPS_APP_OF_APPS_REPO_REVISION}#${GITOPS_APP_OF_APPS_REPO_REVISION}#g" \
        -e "s#\${GITOPS_REPOSITORY_SECRET_NAME}#${GITOPS_REPOSITORY_SECRET_NAME}#g" \
        "${GITOPS_MANIFESTS_DIR}/operators-applicationset.yaml" | oc apply -f -
  fi

  oc get secret -n openshift-gitops "${GITOPS_REPOSITORY_SECRET_NAME}" \
    -o jsonpath='{.metadata.name}{" configured"}{"\n"}' 2>/dev/null || true
  oc get applicationset -n openshift-gitops operators \
    -o jsonpath='{.metadata.name}{" configured"}{"\n"}'
fi

# --- ESO operand + ClusterSecretStore (optional) ---

if [[ -z "${ESO_IAM_ROLE_ARN:-}" ]]; then
  echo "==> ESO_IAM_ROLE_ARN unset; skipping ClusterSecretStore / IRSA configuration"
  exit 0
fi

: "${ESO_MANIFESTS_DIR:?ESO_MANIFESTS_DIR is required when ESO_IAM_ROLE_ARN is set}"

if [[ ! -d "${ESO_MANIFESTS_DIR}" ]]; then
  echo "error: ESO_MANIFESTS_DIR does not exist: ${ESO_MANIFESTS_DIR}" >&2
  exit 1
fi

echo "==> Applying ExternalSecretsConfig operand CR"
oc apply -f "${ESO_MANIFESTS_DIR}/external-secrets-config.yaml"

echo "==> Waiting for External Secrets operand pods in ${ESO_NAMESPACE}"
elapsed=0
while ((elapsed < pod_timeout)); do
  if oc get namespace "${ESO_NAMESPACE}" >/dev/null 2>&1 \
    && oc get sa "${ESO_SERVICE_ACCOUNT}" -n "${ESO_NAMESPACE}" >/dev/null 2>&1; then
    ready="$(oc get deploy -n "${ESO_NAMESPACE}" -o jsonpath='{range .items[*]}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null | awk '{s+=$1} END{print s+0}')"
    desired="$(oc get deploy -n "${ESO_NAMESPACE}" -o jsonpath='{range .items[*]}{.spec.replicas}{"\n"}{end}' 2>/dev/null | awk '{s+=$1} END{print s+0}')"
    if [[ "${desired}" -gt 0 && "${ready}" -ge "${desired}" ]]; then
      echo "    ${ESO_NAMESPACE}: deployments ready (${ready}/${desired})"
      break
    fi
    echo "    ${ESO_NAMESPACE}: deployments ${ready:-0}/${desired:-0}; sleeping 15s"
  else
    echo "    waiting for namespace/SA ${ESO_NAMESPACE}/${ESO_SERVICE_ACCOUNT}; sleeping 15s"
  fi
  sleep 15
  elapsed=$((elapsed + 15))
  if ((elapsed >= pod_timeout)); then
    echo "error: timed out waiting for External Secrets operand in ${ESO_NAMESPACE}" >&2
    oc get all,sa -n "${ESO_NAMESPACE}" >&2 || true
    oc get externalsecretsconfig -n external-secrets-operator -o yaml >&2 || true
    exit 1
  fi
done

echo "==> Annotating ServiceAccount ${ESO_SERVICE_ACCOUNT} with IRSA role"
oc annotate serviceaccount "${ESO_SERVICE_ACCOUNT}" \
  -n "${ESO_NAMESPACE}" \
  "eks.amazonaws.com/role-arn=${ESO_IAM_ROLE_ARN}" \
  --overwrite

echo "==> Restarting external-secrets deployment to pick up IRSA"
if oc get deploy external-secrets -n "${ESO_NAMESPACE}" >/dev/null 2>&1; then
  oc rollout restart deployment/external-secrets -n "${ESO_NAMESPACE}"
  oc rollout status deployment/external-secrets -n "${ESO_NAMESPACE}" --timeout="${pod_timeout}s"
else
  echo "    warning: deployment/external-secrets not found; continuing"
fi

echo "==> Applying ClusterSecretStore ${ESO_CLUSTER_SECRET_STORE} (region=${AWS_REGION})"
# Prefer envsubst when available; fall back to sed for the single placeholder.
if command -v envsubst >/dev/null 2>&1; then
  export AWS_REGION
  envsubst '${AWS_REGION}' < "${ESO_MANIFESTS_DIR}/clustersecretstore.yaml" | oc apply -f -
else
  sed "s/\${AWS_REGION}/${AWS_REGION}/g" "${ESO_MANIFESTS_DIR}/clustersecretstore.yaml" | oc apply -f -
fi

echo "==> Waiting for ClusterSecretStore Ready=True"
elapsed=0
while ((elapsed < css_timeout)); do
  status="$(oc get clustersecretstore "${ESO_CLUSTER_SECRET_STORE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  reason="$(oc get clustersecretstore "${ESO_CLUSTER_SECRET_STORE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || true)"
  if [[ "${status}" == "True" ]]; then
    echo "    ClusterSecretStore Ready=True reason=${reason}"
    break
  fi
  echo "    Ready=${status:-<none>} reason=${reason:-<none>}; sleeping 10s"
  sleep 10
  elapsed=$((elapsed + 10))
  if ((elapsed >= css_timeout)); then
    echo "error: timed out waiting for ClusterSecretStore ${ESO_CLUSTER_SECRET_STORE} Ready=True" >&2
    echo "--- ClusterSecretStore status ---" >&2
    oc get clustersecretstore "${ESO_CLUSTER_SECRET_STORE}" -o yaml >&2 || true
    echo "--- recent external-secrets controller errors ---" >&2
    oc logs -n "${ESO_NAMESPACE}" deploy/external-secrets --tail=50 2>&1 \
      | grep -Ei 'error|unable|assume|timeout|InvalidProvider' >&2 || true
    echo "--- networkpolicies (deny-all without TCP/443 egress blocks STS) ---" >&2
    oc get networkpolicy -n "${ESO_NAMESPACE}" >&2 || true
    exit 1
  fi
done

if [[ "${ESO_RUN_E2E_TEST}" != "true" ]]; then
  echo "==> ESO ClusterSecretStore configuration complete (e2e skipped)"
  exit 0
fi

: "${ESO_E2E_SECRET_NAME:?ESO_E2E_SECRET_NAME is required when ESO_RUN_E2E_TEST=true}"
: "${ESO_E2E_SECRET_VALUE:?ESO_E2E_SECRET_VALUE is required when ESO_RUN_E2E_TEST=true}"

echo "==> Running ESO e2e ExternalSecret sync test"
oc apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: e2e-test-secret
  namespace: ${ESO_E2E_NAMESPACE}
spec:
  refreshInterval: 10s
  secretStoreRef:
    name: ${ESO_CLUSTER_SECRET_STORE}
    kind: ClusterSecretStore
  target:
    name: e2e-test-secret
    creationPolicy: Owner
  data:
    - secretKey: test-value
      remoteRef:
        key: ${ESO_E2E_SECRET_NAME}
EOF

echo "==> Waiting for e2e ExternalSecret Ready"
elapsed=0
while ((elapsed < css_timeout)); do
  status="$(oc get externalsecret e2e-test-secret -n "${ESO_E2E_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [[ "${status}" == "True" ]]; then
    synced="$(oc get secret e2e-test-secret -n "${ESO_E2E_NAMESPACE}" \
      -o jsonpath='{.data.test-value}' | base64 -d)"
    if [[ "${synced}" == "${ESO_E2E_SECRET_VALUE}" ]]; then
      echo "E2E PASSED: Kubernetes Secret value matches AWS Secrets Manager value"
      oc delete externalsecret e2e-test-secret -n "${ESO_E2E_NAMESPACE}" --ignore-not-found
      oc delete secret e2e-test-secret -n "${ESO_E2E_NAMESPACE}" --ignore-not-found
      exit 0
    fi
    echo "E2E FAILED: value mismatch (got '${synced}')" >&2
    exit 1
  fi
  echo "    ExternalSecret Ready=${status:-<none>}; sleeping 10s"
  sleep 10
  elapsed=$((elapsed + 10))
done

echo "E2E FAILED: ExternalSecret did not become Ready within ${css_timeout}s" >&2
oc get externalsecret e2e-test-secret -n "${ESO_E2E_NAMESPACE}" -o yaml >&2 || true
exit 1
