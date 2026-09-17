#!/usr/bin/env bash

set -Eeuo pipefail

CLUSTER_NAMESPACE="${CLUSTER_NAMESPACE:-}"
INFRAENV_NAME="${INFRAENV_NAME:-}"
DESTINATION="${DESTINATION:-/var/www/html/drivers/full_discovery.iso}"
MINIMUM_BYTES="${MINIMUM_BYTES:-104857600}"

usage() {
  cat <<'EOF'
Download the current ACM InfraEnv discovery ISO and publish it atomically.

Usage:
  refresh_infraenv_iso.sh [options]

Options:
  --namespace NAMESPACE   InfraEnv namespace (required)
  --infraenv NAME         InfraEnv name (required)
  --output PATH           Served ISO path
                          (default: /var/www/html/drivers/full_discovery.iso)
  --minimum-bytes BYTES   Reject smaller downloads (default: 104857600)
  -h, --help              Show this help

The script requires an authenticated oc session. It deliberately does not print
the signed InfraEnv URL or its embedded API key.

Example:
  sudo --preserve-env=KUBECONFIG ./scripts/refresh_infraenv_iso.sh \
    --namespace example-cluster \
    --infraenv example-cluster \
    --output /var/www/html/drivers/full_discovery.iso
EOF
}

while (($#)); do
  case "$1" in
    --namespace) CLUSTER_NAMESPACE="$2"; shift 2 ;;
    --infraenv) INFRAENV_NAME="$2"; shift 2 ;;
    --output) DESTINATION="$2"; shift 2 ;;
    --minimum-bytes) MINIMUM_BYTES="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$CLUSTER_NAMESPACE" || -z "$INFRAENV_NAME" ]]; then
  echo "--namespace and --infraenv are required" >&2
  exit 2
fi

if [[ "$DESTINATION" != /* ]]; then
  echo "--output must be an absolute path: ${DESTINATION}" >&2
  exit 2
fi

if [[ ! "$MINIMUM_BYTES" =~ ^[0-9]+$ ]] || ((MINIMUM_BYTES < 1)); then
  echo "--minimum-bytes must be a positive integer" >&2
  exit 2
fi

for command_name in oc curl dd wc date mv chmod mkdir; do
  command -v "$command_name" >/dev/null || {
    echo "Required command not found: ${command_name}" >&2
    exit 1
  }
done

destination_directory="$(dirname "$DESTINATION")"
destination_name="$(basename "$DESTINATION")"
temporary_iso=""
temporary_metadata=""

cleanup() {
  [[ -z "$temporary_iso" ]] || rm -f "$temporary_iso"
  [[ -z "$temporary_metadata" ]] || rm -f "$temporary_metadata"
}
trap cleanup EXIT

mkdir -p "$destination_directory"

infraenv_uid="$(
  oc get infraenv "$INFRAENV_NAME" \
    -n "$CLUSTER_NAMESPACE" \
    -o jsonpath='{.metadata.uid}'
)"

infraenv_resource_version="$(
  oc get infraenv "$INFRAENV_NAME" \
    -n "$CLUSTER_NAMESPACE" \
    -o jsonpath='{.metadata.resourceVersion}'
)"

image_ready="$(
  oc get infraenv "$INFRAENV_NAME" \
    -n "$CLUSTER_NAMESPACE" \
    -o jsonpath='{range .status.conditions[?(@.type=="ImageCreated")]}{.status}{end}'
)"

iso_url="$(
  oc get infraenv "$INFRAENV_NAME" \
    -n "$CLUSTER_NAMESPACE" \
    -o jsonpath='{.status.isoDownloadURL}'
)"

if [[ "$image_ready" != "True" ]]; then
  echo "InfraEnv ${CLUSTER_NAMESPACE}/${INFRAENV_NAME} is not image-ready" >&2
  exit 1
fi

if [[ -z "$iso_url" ]]; then
  echo "InfraEnv ${CLUSTER_NAMESPACE}/${INFRAENV_NAME} has no ISO download URL" >&2
  exit 1
fi

temporary_iso="$(mktemp "${destination_directory}/.${destination_name}.download.XXXXXX")"
temporary_metadata="$(mktemp "${destination_directory}/.${destination_name}.metadata.XXXXXX")"

echo "InfraEnv: ${CLUSTER_NAMESPACE}/${INFRAENV_NAME}"
echo "Downloading the current discovery ISO..."

curl \
  --fail \
  --location \
  --show-error \
  --retry 3 \
  --retry-delay 2 \
  --retry-all-errors \
  --connect-timeout 15 \
  --max-time 1800 \
  --output "$temporary_iso" \
  "$iso_url"

download_size="$(wc -c < "$temporary_iso" | tr -d '[:space:]')"
if ((download_size < MINIMUM_BYTES)); then
  echo "Downloaded file is unexpectedly small: ${download_size} bytes" >&2
  exit 1
fi

# ISO 9660 volume descriptors contain the CD001 identifier at byte 32769.
iso_magic="$(dd if="$temporary_iso" bs=1 skip=32769 count=5 2>/dev/null)"
if [[ "$iso_magic" != "CD001" ]]; then
  echo "Downloaded file does not contain the expected ISO 9660 signature" >&2
  exit 1
fi

if command -v sha256sum >/dev/null; then
  iso_sha256="$(sha256sum "$temporary_iso" | awk '{print $1}')"
elif command -v shasum >/dev/null; then
  iso_sha256="$(shasum -a 256 "$temporary_iso" | awk '{print $1}')"
else
  iso_sha256="not-calculated"
fi

downloaded_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "$temporary_metadata" <<EOF
namespace=${CLUSTER_NAMESPACE}
infraenv=${INFRAENV_NAME}
infraenv_uid=${infraenv_uid}
infraenv_resource_version=${infraenv_resource_version}
downloaded_at=${downloaded_at}
size_bytes=${download_size}
sha256=${iso_sha256}
EOF

chmod 0644 "$temporary_iso" "$temporary_metadata"

if command -v restorecon >/dev/null; then
  restorecon -F "$temporary_iso" "$temporary_metadata" >/dev/null 2>&1 || true
fi

mv -f "$temporary_iso" "$DESTINATION"
temporary_iso=""
mv -f "$temporary_metadata" "${DESTINATION}.metadata"
temporary_metadata=""

if command -v restorecon >/dev/null; then
  restorecon -F "$DESTINATION" "${DESTINATION}.metadata" >/dev/null 2>&1 || true
fi

echo "Published: ${DESTINATION}"
echo "Size: ${download_size} bytes"
echo "SHA-256: ${iso_sha256}"
echo "Metadata: ${DESTINATION}.metadata"
echo "Completed: ${downloaded_at}"
