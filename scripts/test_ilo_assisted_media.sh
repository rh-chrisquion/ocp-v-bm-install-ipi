#!/usr/bin/env bash

set -Eeuo pipefail

ILO_HOST="${ILO_HOST:-}"
ILO_USER="${ILO_USER:-}"
ILO_PASSWORD="${ILO_PASSWORD:-}"
CLUSTER_NAMESPACE="${CLUSTER_NAMESPACE:-}"
INFRAENV_NAME="${INFRAENV_NAME:-}"
DNS_SERVERS="${DNS_SERVERS:-}"
CERTIFICATE_FILE="${CERTIFICATE_FILE:-}"
ISO_URL_OVERRIDE="${ISO_URL_OVERRIDE:-}"
AGENT_NAME="${AGENT_NAME:-}"
INSTALLATION_DISK_ID="${INSTALLATION_DISK_ID:-}"
HANDOFF_TIMEOUT="${HANDOFF_TIMEOUT:-7200}"
OUTPUT_FILE=""
CONFIGURE_DNS=false
MOUNT_ISO=false
REBOOT_HOST=false
SKIP_CLIENT_ISO_TEST=false
HANDOFF_TO_DISK=false
HANDOFF_REBOOT_REQUIRED=true

usage() {
  cat <<'EOF'
Audit and optionally test HPE iLO virtual media against an InfraEnv or hosted ISO.

Usage:
  test_ilo_assisted_media.sh --ilo-host ADDRESS [options]

Options:
  --ilo-host ADDRESS       iLO address (required unless ILO_HOST is set)
  --ilo-user USER          iLO user (required unless ILO_USER is set)
  --namespace NAMESPACE    InfraEnv namespace (required unless --iso-url is used)
  --infraenv NAME          InfraEnv name (required unless --iso-url is used)
  --iso-url URL            Mount this ISO URL instead of the InfraEnv URL
  --agent NAME             Agent resource used for disk pinning or boot handoff
  --installation-disk ID   Pin the Agent to this persistent disk ID before install
  --handoff-to-disk        Wait for Agent stage Rebooting, eject the ISO, select
                           local disk for one boot, and reboot the physical host
  --handoff-timeout SEC    Seconds to wait for Rebooting (default: 7200)
  --dns CSV                Static DNS list (required with --configure-dns)
  --certificate FILE       PEM certificate for validating the ISO HTTPS server
                           (default: retrieve and validate its current leaf certificate)
  --configure-dns          Apply DNS, reset iLO, and wait for it to return
  --mount                  Mount the ISO and set virtual CD boot once
  --skip-client-iso-test   Do not test the ISO URL from the machine running this script
  --reboot                 Reboot the physical host; requires --mount
  --output FILE            Tee output to FILE (default: /tmp/ilo-assisted-test-*.log)
  -h, --help               Show this help

Credentials are read from ILO_PASSWORD or prompted without echo. The ISO URL and
its embedded API key are intentionally omitted from output.

Examples:
  # Read-only audit
  ./scripts/test_ilo_assisted_media.sh --ilo-host 192.0.2.10

  # Apply DNS and reset only the iLO management processor
  ./scripts/test_ilo_assisted_media.sh --ilo-host 192.0.2.10 --configure-dns

  # Configure DNS, mount the ISO, set boot once, and reboot the physical host
  ./scripts/test_ilo_assisted_media.sh --ilo-host 192.0.2.10 \
    --configure-dns --mount --reboot

  # Mount an HTTP-hosted ISO that is reachable from iLO but not this client
  ./scripts/test_ilo_assisted_media.sh --ilo-host 192.0.2.11 \
    --iso-url http://192.0.2.20/discovery/full.iso \
    --skip-client-iso-test --mount --reboot

  # Before installation, explicitly pin the MR416i logical disk
  ./scripts/test_ilo_assisted_media.sh --ilo-host 192.0.2.10 \
    --agent 00000000-0000-0000-0000-000000000000 \
    --installation-disk /dev/disk/by-id/wwn-0xEXAMPLE

  # Run separately during installation to perform the ISO-to-disk handoff
  ./scripts/test_ilo_assisted_media.sh --ilo-host 192.0.2.10 \
    --agent 00000000-0000-0000-0000-000000000000 --handoff-to-disk
EOF
}

while (($#)); do
  case "$1" in
    --ilo-host) ILO_HOST="$2"; shift 2 ;;
    --ilo-user) ILO_USER="$2"; shift 2 ;;
    --namespace) CLUSTER_NAMESPACE="$2"; shift 2 ;;
    --infraenv) INFRAENV_NAME="$2"; shift 2 ;;
    --iso-url) ISO_URL_OVERRIDE="$2"; shift 2 ;;
    --agent) AGENT_NAME="$2"; shift 2 ;;
    --installation-disk) INSTALLATION_DISK_ID="$2"; shift 2 ;;
    --handoff-to-disk) HANDOFF_TO_DISK=true; shift ;;
    --handoff-timeout) HANDOFF_TIMEOUT="$2"; shift 2 ;;
    --dns) DNS_SERVERS="$2"; shift 2 ;;
    --certificate) CERTIFICATE_FILE="$2"; shift 2 ;;
    --configure-dns) CONFIGURE_DNS=true; shift ;;
    --mount) MOUNT_ISO=true; shift ;;
    --skip-client-iso-test) SKIP_CLIENT_ISO_TEST=true; shift ;;
    --reboot) REBOOT_HOST=true; shift ;;
    --output) OUTPUT_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$ILO_USER" ]]; then
  echo "--ilo-user or ILO_USER is required" >&2
  exit 2
fi

if [[ -z "$ILO_HOST" ]]; then
  echo "--ilo-host or ILO_HOST is required" >&2
  exit 2
fi

if [[ "$CONFIGURE_DNS" == true && -z "$DNS_SERVERS" ]]; then
  echo "--dns or DNS_SERVERS is required with --configure-dns" >&2
  exit 2
fi

if [[ -z "$ISO_URL_OVERRIDE" && ( -z "$CLUSTER_NAMESPACE" || -z "$INFRAENV_NAME" ) ]]; then
  echo "--namespace and --infraenv are required unless --iso-url is supplied" >&2
  exit 2
fi

if [[ "$REBOOT_HOST" == true && "$MOUNT_ISO" != true ]]; then
  echo "--reboot requires --mount" >&2
  exit 2
fi

if [[ -n "$INSTALLATION_DISK_ID" && -z "$AGENT_NAME" ]]; then
  echo "--installation-disk requires --agent" >&2
  exit 2
fi

if [[ "$HANDOFF_TO_DISK" == true && -z "$AGENT_NAME" ]]; then
  echo "--handoff-to-disk requires --agent" >&2
  exit 2
fi

if [[ "$HANDOFF_TO_DISK" == true ]] && \
   [[ "$CONFIGURE_DNS" == true || "$MOUNT_ISO" == true || \
      "$REBOOT_HOST" == true || -n "$INSTALLATION_DISK_ID" ]]; then
  echo "--handoff-to-disk must be run as a separate action" >&2
  exit 2
fi

if [[ ! "$HANDOFF_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  echo "--handoff-timeout must be a positive integer" >&2
  exit 2
fi

for command_name in curl python3; do
  command -v "$command_name" >/dev/null || {
    echo "Required command not found: $command_name" >&2
    exit 1
  }
done

if [[ ( "$MOUNT_ISO" == true && -z "$ISO_URL_OVERRIDE" ) || \
      -n "$INSTALLATION_DISK_ID" || "$HANDOFF_TO_DISK" == true ]]; then
  command -v oc >/dev/null || {
    echo "Required command not found: oc" >&2
    exit 1
  }
fi

if [[ -z "$ILO_PASSWORD" ]]; then
  read -rsp "iLO password: " ILO_PASSWORD
  echo
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_FILE="${OUTPUT_FILE:-/tmp/ilo-assisted-test-${ILO_HOST}-${timestamp}.log}"
mkdir -p "$(dirname "$OUTPUT_FILE")"
exec > >(tee -a "$OUTPUT_FILE") 2>&1

redfish_request() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local body_file http_code

  body_file="$(mktemp)"
  if [[ -n "$data" ]]; then
    http_code="$(curl -skS \
      -u "${ILO_USER}:${ILO_PASSWORD}" \
      -X "$method" \
      -H 'Content-Type: application/json' \
      -d "$data" \
      -o "$body_file" \
      -w '%{http_code}' \
      "https://${ILO_HOST}${path}")"
  else
    http_code="$(curl -skS \
      -u "${ILO_USER}:${ILO_PASSWORD}" \
      -X "$method" \
      -o "$body_file" \
      -w '%{http_code}' \
      "https://${ILO_HOST}${path}")"
  fi

  echo "${method} ${path} -> HTTP ${http_code}"
  if [[ ! "$http_code" =~ ^2 ]]; then
    python3 -m json.tool "$body_file" 2>/dev/null || sed -n '1,80p' "$body_file"
    rm -f "$body_file"
    return 1
  fi

  rm -f "$body_file"
}

pin_installation_disk() {
  local agent_body current_disk current_stage disk_eligible

  echo "===== Pin Agent installation disk ====="
  agent_body="$(mktemp)"
  if ! oc get agent "$AGENT_NAME" \
    -n "$CLUSTER_NAMESPACE" \
    -o json >"$agent_body"; then
    rm -f "$agent_body"
    return 1
  fi

  IFS=$'\t' read -r current_stage current_disk disk_eligible < <(
    INSTALLATION_DISK_ID="$INSTALLATION_DISK_ID" python3 - "$agent_body" <<'PY'
import json
import os
import sys

with open(sys.argv[1]) as stream:
    agent = json.load(stream)

stage = agent.get("status", {}).get("progress", {}).get("currentStage") or "None"
current = agent.get("spec", {}).get("installation_disk_id") or "None"
expected = os.environ["INSTALLATION_DISK_ID"]
eligible = any(
    disk.get("id") == expected
    and disk.get("installationEligibility", {}).get("eligible") is True
    for disk in agent.get("status", {}).get("inventory", {}).get("disks", [])
)
print(stage, current, "true" if eligible else "false", sep="\t")
PY
  )
  rm -f "$agent_body"

  echo "Agent: ${CLUSTER_NAMESPACE}/${AGENT_NAME}"
  echo "Current stage: ${current_stage}"
  echo "Current installation disk: ${current_disk}"
  echo "Requested installation disk: ${INSTALLATION_DISK_ID}"

  if [[ "$disk_eligible" != true ]]; then
    echo "Requested disk is not present and installation-eligible in Agent inventory" >&2
    return 1
  fi

  if [[ "$current_disk" == "$INSTALLATION_DISK_ID" ]]; then
    echo "Installation disk is already pinned"
    return 0
  fi

  case "$current_stage" in
    Installing*|Rebooting|Done|"Waiting for control plane"|Joined|Finalizing*)
      echo "Refusing to change the installation disk after installation has started" >&2
      return 1
      ;;
  esac

  INSTALLATION_DISK_ID="$INSTALLATION_DISK_ID" python3 -c '
import json
import os
print(json.dumps({
    "spec": {"installation_disk_id": os.environ["INSTALLATION_DISK_ID"]}
}))
' | oc patch agent "$AGENT_NAME" \
    -n "$CLUSTER_NAMESPACE" \
    --type merge \
    --patch-file /dev/stdin

  current_disk="$(oc get agent "$AGENT_NAME" \
    -n "$CLUSTER_NAMESPACE" \
    -o jsonpath='{.spec.installation_disk_id}')"
  if [[ "$current_disk" != "$INSTALLATION_DISK_ID" ]]; then
    echo "Agent installation disk verification failed" >&2
    return 1
  fi
  echo "Installation disk pin: PASS"
}

show_state() {
  echo "===== iLO network ====="
  curl -skS \
    -u "${ILO_USER}:${ILO_PASSWORD}" \
    "https://${ILO_HOST}/redfish/v1/Managers/1/EthernetInterfaces/1/" |
    python3 -c '
import json, sys
e = json.load(sys.stdin)
if "error" in e:
    raise SystemExit(json.dumps(e))
print("IPv4:", e.get("IPv4Addresses"))
print("StaticNameServers:", e.get("StaticNameServers"))
'

  echo "===== Virtual media ====="
  curl -skS \
    -u "${ILO_USER}:${ILO_PASSWORD}" \
    "https://${ILO_HOST}/redfish/v1/Managers/1/VirtualMedia/2/" |
    python3 -c '
import json, sys
from urllib.parse import urlsplit
v = json.load(sys.stdin)
if "error" in v:
    raise SystemExit(json.dumps(v))
print("Inserted:", v.get("Inserted"))
print("ConnectedVia:", v.get("ConnectedVia"))
print("ImageName:", v.get("ImageName"))
print("ImageScheme:", urlsplit(v.get("Image") or "").scheme)
print("Protocol:", v.get("TransferProtocolType"))
print("BootOnNextServerReset:",
      v.get("Oem", {}).get("Hpe", {}).get("BootOnNextServerReset"))
'

  echo "===== Computer system ====="
  curl -skS \
    -u "${ILO_USER}:${ILO_PASSWORD}" \
    "https://${ILO_HOST}/redfish/v1/Systems/1/" |
    python3 -c '
import json, sys
s = json.load(sys.stdin)
if "error" in s:
    raise SystemExit(json.dumps(s))
b = s.get("Boot", {})
print("PowerState:", s.get("PowerState"))
print("PostState:", s.get("Oem", {}).get("Hpe", {}).get("PostState"))
print("BootOverrideEnabled:", b.get("BootSourceOverrideEnabled"))
print("BootOverrideTarget:", b.get("BootSourceOverrideTarget"))
print("BootMode:", b.get("BootSourceOverrideMode"))
'
}

show_events() {
  echo "===== Recent iLO events ====="
  curl -skS \
    -u "${ILO_USER}:${ILO_PASSWORD}" \
    "https://${ILO_HOST}/redfish/v1/Managers/1/LogServices/IEL/Entries/" |
    python3 -c '
import json, re, sys
d = json.load(sys.stdin)
if "error" in d:
    raise SystemExit(json.dumps(d))
for event in d.get("Members", [])[-15:]:
    message = event.get("Message") or ""
    message = re.sub(r"(/byapikey/)[^/\s]+", r"\1<redacted>", message)
    print(event.get("Created"), "|", event.get("MessageId"), "|", message)
'
}

configure_dns() {
  local dns_payload went_down
  dns_payload="$(DNS_SERVERS="$DNS_SERVERS" python3 -c '
import json, os
print(json.dumps({"StaticNameServers": os.environ["DNS_SERVERS"].split(",")}))
')"

  echo "===== Configure static DNS ====="
  echo "Requested DNS: ${DNS_SERVERS}"
  redfish_request PATCH \
    /redfish/v1/Managers/1/EthernetInterfaces/1/ \
    "$dns_payload"

  echo "===== Reset iLO management processor ====="
  redfish_request POST \
    /redfish/v1/Managers/1/Actions/Manager.Reset/ \
    '{"ResetType":"ForceRestart"}'

  echo "Waiting for iLO ${ILO_HOST} to begin resetting..."
  went_down=false
  for _ in {1..24}; do
    if ! curl -skS \
      --connect-timeout 3 \
      -u "${ILO_USER}:${ILO_PASSWORD}" \
      -o /dev/null \
      "https://${ILO_HOST}/redfish/v1/"; then
      went_down=true
      echo "iLO reset is in progress"
      break
    fi
    sleep 5
  done

  if [[ "$went_down" != true ]]; then
    echo "Warning: iLO did not become unavailable; continuing with readiness checks"
  fi

  echo "Waiting for iLO ${ILO_HOST} to return..."
  for _ in {1..60}; do
    if curl -skS \
      --connect-timeout 3 \
      -u "${ILO_USER}:${ILO_PASSWORD}" \
      -o /dev/null \
      "https://${ILO_HOST}/redfish/v1/"; then
      echo "iLO is available"
      return 0
    fi
    sleep 5
  done

  echo "Timed out waiting for iLO" >&2
  return 1
}

wait_for_finished_post() {
  local post_state="Unknown"

  echo "===== Wait for system POST to finish ====="
  for _ in {1..90}; do
    post_state="$(curl -skS \
      -u "${ILO_USER}:${ILO_PASSWORD}" \
      "https://${ILO_HOST}/redfish/v1/Systems/1/" | \
      python3 -c '
import json
import sys

system = json.load(sys.stdin)
print(system.get("Oem", {}).get("Hpe", {}).get("PostState") or "Unknown")
')"
    echo "PostState: ${post_state}"
    if [[ "$post_state" == "FinishedPost" ]]; then
      return 0
    fi
    sleep 10
  done

  echo "Timed out waiting for the physical host to finish POST" >&2
  return 1
}

wait_for_agent_rebooting() {
  local deadline last_stage="" stage=""
  deadline=$((SECONDS + HANDOFF_TIMEOUT))

  echo "===== Wait for Agent disk-handoff stage ====="
  echo "Agent: ${CLUSTER_NAMESPACE}/${AGENT_NAME}"
  while ((SECONDS < deadline)); do
    stage="$(oc get agent "$AGENT_NAME" \
      -n "$CLUSTER_NAMESPACE" \
      -o jsonpath='{.status.progress.currentStage}')"
    if [[ "$stage" != "$last_stage" ]]; then
      echo "Agent stage: ${stage:-Unknown}"
      last_stage="$stage"
    fi

    case "$stage" in
      Rebooting)
        HANDOFF_REBOOT_REQUIRED=true
        return 0
        ;;
      Done|"Waiting for control plane"|Joined)
        echo "Agent already passed Rebooting; cleaning up discovery media without another reboot"
        HANDOFF_REBOOT_REQUIRED=false
        return 0
        ;;
    esac
    sleep 15
  done

  echo "Timed out waiting for Agent stage Rebooting" >&2
  return 1
}

eject_virtual_media() {
  local body connected_via eject_code inserted oem_eject_target standard_eject_target

  body="$(mktemp)"
  curl -skS \
    -u "${ILO_USER}:${ILO_PASSWORD}" \
    -o "$body" \
    "https://${ILO_HOST}/redfish/v1/Managers/1/VirtualMedia/2/"

  IFS=$'\t' read -r inserted connected_via standard_eject_target oem_eject_target < <(
    python3 - "$body" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    media = json.load(stream)

standard = (
    media.get("Actions", {})
    .get("#VirtualMedia.EjectMedia", {})
    .get("target", "")
)
oem = (
    media.get("Oem", {})
    .get("Hpe", {})
    .get("Actions", {})
    .get("#HpeiLOVirtualMedia.EjectVirtualMedia", {})
    .get("target", "")
)
print(
    "true" if media.get("Inserted") is True else "false",
    media.get("ConnectedVia") or "Unknown",
    standard,
    oem,
    sep="\t",
)
PY
  )
  rm -f "$body"

  echo "Inserted: ${inserted}"
  echo "ConnectedVia: ${connected_via}"
  if [[ "$inserted" != true ]]; then
    echo "Virtual media is already ejected"
    return 0
  fi
  if [[ "$connected_via" == "Applet" ]]; then
    echo "Virtual media is owned by an iLO remote-console applet" >&2
    echo "Disconnect it in the remote console before retrying the handoff" >&2
    return 1
  fi
  if [[ -z "$standard_eject_target" ]]; then
    echo "Standard EjectMedia action was not advertised" >&2
    return 1
  fi

  body="$(mktemp)"
  eject_code="$(curl -skS \
    -u "${ILO_USER}:${ILO_PASSWORD}" \
    -X POST \
    -H 'Content-Type: application/json' \
    -d '{}' \
    -o "$body" \
    -w '%{http_code}' \
    "https://${ILO_HOST}${standard_eject_target}")"
  echo "POST EjectMedia -> HTTP ${eject_code}"

  if [[ ! "$eject_code" =~ ^2 ]] && \
     grep -q 'UnsupportedOperation' "$body" && \
     [[ -n "$oem_eject_target" ]]; then
    echo "Standard eject was unsupported; trying HPE OEM eject action"
    eject_code="$(curl -skS \
      -u "${ILO_USER}:${ILO_PASSWORD}" \
      -X POST \
      -H 'Content-Type: application/json' \
      -d '{}' \
      -o "$body" \
      -w '%{http_code}' \
      "https://${ILO_HOST}${oem_eject_target}")"
    echo "POST HpeiLOVirtualMedia.EjectVirtualMedia -> HTTP ${eject_code}"
  fi

  if [[ ! "$eject_code" =~ ^2 ]] && ! grep -q 'NoVirtualMediaConnectionAvailable' "$body"; then
    python3 -m json.tool "$body" 2>/dev/null || sed -n '1,80p' "$body"
    rm -f "$body"
    return 1
  fi
  rm -f "$body"

  inserted="$(curl -skS \
    -u "${ILO_USER}:${ILO_PASSWORD}" \
    "https://${ILO_HOST}/redfish/v1/Managers/1/VirtualMedia/2/" | \
    python3 -c '
import json
import sys
print("true" if json.load(sys.stdin).get("Inserted") is True else "false")
')"
  if [[ "$inserted" == true ]]; then
    echo "Virtual-media eject verification failed" >&2
    return 1
  fi
  echo "Virtual-media eject: PASS"
}

handoff_to_disk() {
  echo "===== Discovery ISO to local-disk handoff ====="
  wait_for_agent_rebooting

  # BootOnNextServerReset is HPE-specific and can otherwise override the
  # standard Redfish one-time boot setting on subsequent host resets.
  if ! redfish_request PATCH \
    /redfish/v1/Managers/1/VirtualMedia/2/ \
    '{"Oem":{"Hpe":{"BootOnNextServerReset":false}}}'; then
    echo "iLO may be in POST; waiting for it to become modifiable"
    wait_for_finished_post
    redfish_request PATCH \
      /redfish/v1/Managers/1/VirtualMedia/2/ \
      '{"Oem":{"Hpe":{"BootOnNextServerReset":false}}}'
  fi

  echo "===== Eject discovery ISO ====="
  if ! eject_virtual_media; then
    echo "The host may have started POST during the handoff; waiting and retrying"
    wait_for_finished_post
    redfish_request PATCH \
      /redfish/v1/Managers/1/VirtualMedia/2/ \
      '{"Oem":{"Hpe":{"BootOnNextServerReset":false}}}'
    eject_virtual_media
  fi

  if [[ "$HANDOFF_REBOOT_REQUIRED" == true ]]; then
    echo "===== Select local disk for the next boot ====="
    if ! redfish_request PATCH \
      /redfish/v1/Systems/1/ \
      '{"Boot":{"BootSourceOverrideTarget":"Hdd","BootSourceOverrideEnabled":"Once"}}'; then
      echo "The host may have started POST during the handoff; waiting and retrying"
      wait_for_finished_post
      redfish_request PATCH \
        /redfish/v1/Systems/1/ \
        '{"Boot":{"BootSourceOverrideTarget":"Hdd","BootSourceOverrideEnabled":"Once"}}'
    fi
  fi

  echo "===== Verify disk handoff ====="
  if ! {
    curl -skS \
      -u "${ILO_USER}:${ILO_PASSWORD}" \
      "https://${ILO_HOST}/redfish/v1/Managers/1/VirtualMedia/2/"
    curl -skS \
      -u "${ILO_USER}:${ILO_PASSWORD}" \
      "https://${ILO_HOST}/redfish/v1/Systems/1/"
  } | HANDOFF_REBOOT_REQUIRED="$HANDOFF_REBOOT_REQUIRED" python3 -c '
import json
import os
import sys

decoder = json.JSONDecoder()
content = sys.stdin.read()
media, offset = decoder.raw_decode(content)
system, _ = decoder.raw_decode(content, offset)
boot = system.get("Boot", {})
checks = {
    "ISOEjected": media.get("Inserted") is not True,
    "BootOnNextServerReset=False": (
        media.get("Oem", {}).get("Hpe", {}).get("BootOnNextServerReset") is False
    ),
}
if os.environ["HANDOFF_REBOOT_REQUIRED"] == "true":
    checks["BootOverrideEnabled=Once"] = boot.get("BootSourceOverrideEnabled") == "Once"
    checks["BootOverrideTarget=Hdd"] = boot.get("BootSourceOverrideTarget") == "Hdd"
for name, passed in checks.items():
    print("{}: {}".format(name, "PASS" if passed else "FAIL"))
if not all(checks.values()):
    raise SystemExit("Refusing to reboot because disk-handoff checks failed")
'; then
    return 1
  fi

  if [[ "$HANDOFF_REBOOT_REQUIRED" == true ]]; then
    reboot_host
    echo "Disk-handoff reboot submitted"
  else
    echo "Discovery-media cleanup completed; the Agent is already past Rebooting"
  fi
}

mount_iso() {
  local certificate_file="" certificate_is_temporary=false
  local eject_body eject_code http_code insert_body insert_payload
  local insert_target iso_host iso_scheme iso_url media_body media_connected_via
  local oem_eject_target oem_target standard_target

  if [[ -n "$ISO_URL_OVERRIDE" ]]; then
    iso_url="$ISO_URL_OVERRIDE"
    echo "ISO source: custom URL"
  else
    iso_url="$(oc get infraenv "$INFRAENV_NAME" \
      -n "$CLUSTER_NAMESPACE" \
      -o jsonpath='{.status.isoDownloadURL}')"
    echo "ISO source: InfraEnv ${CLUSTER_NAMESPACE}/${INFRAENV_NAME}"
  fi
  if [[ -z "$iso_url" ]]; then
    echo "ISO URL is empty" >&2
    return 1
  fi

  read -r iso_scheme iso_host < <(ISO_URL="$iso_url" python3 -c '
import os
from urllib.parse import urlsplit
url = urlsplit(os.environ["ISO_URL"])
print(url.scheme, url.hostname or "")
')
  if [[ "$iso_scheme" != "http" && "$iso_scheme" != "https" ]]; then
    echo "ISO URL must use HTTP or HTTPS" >&2
    return 1
  fi
  if [[ -z "$iso_host" ]]; then
    echo "Could not determine the ISO hostname" >&2
    return 1
  fi
  echo "ISO scheme: ${iso_scheme}"
  echo "ISO host: ${iso_host}"

  if [[ "$SKIP_CLIENT_ISO_TEST" == true ]]; then
    echo "===== Client ISO test skipped ====="
    echo "The iLO controller must be able to reach the ISO URL directly."
  else
    echo "===== Test ISO from this client ====="
    curl -fsS \
      --location \
      --range 0-1048575 \
      --max-time 120 \
      -o /dev/null \
      -w 'HTTP=%{http_code} Bytes=%{size_download} Time=%{time_total} RemoteIP=%{remote_ip}\n' \
      "$iso_url"
  fi

  if [[ "$iso_scheme" == "https" ]]; then
    command -v openssl >/dev/null || {
      echo "Required command not found for an HTTPS ISO: openssl" >&2
      return 1
    }

    if [[ -n "$CERTIFICATE_FILE" ]]; then
      certificate_file="$CERTIFICATE_FILE"
      if [[ ! -s "$certificate_file" ]]; then
        echo "Certificate file does not exist or is empty: ${certificate_file}" >&2
        return 1
      fi
    else
      certificate_file="$(mktemp)"
      certificate_is_temporary=true

      echo "===== Retrieve ISO server certificate ====="
      if ! openssl s_client \
        -connect "${iso_host}:443" \
        -servername "$iso_host" \
        -verify_return_error \
        </dev/null 2>/dev/null | \
        openssl x509 -outform PEM >"$certificate_file"; then
        echo "Could not retrieve a trusted certificate from ${iso_host}:443" >&2
        rm -f "$certificate_file"
        return 1
      fi
    fi

    echo "===== Validate ISO server certificate ====="
    if ! openssl x509 \
      -in "$certificate_file" \
      -noout \
      -subject \
      -issuer \
      -dates \
      -checkhost "$iso_host"; then
      echo "Certificate validation failed for ${iso_host}" >&2
      if [[ "$certificate_is_temporary" == true ]]; then
        rm -f "$certificate_file"
      fi
      return 1
    fi
  fi

  # iLO rejects eject, insert, and boot-override changes during portions of POST.
  wait_for_finished_post

  media_body="$(mktemp)"
  http_code="$(curl -skS \
    -u "${ILO_USER}:${ILO_PASSWORD}" \
    -o "$media_body" \
    -w '%{http_code}' \
    "https://${ILO_HOST}/redfish/v1/Managers/1/VirtualMedia/2/")"
  echo "GET VirtualMedia -> HTTP ${http_code}"
  if [[ ! "$http_code" =~ ^2 ]]; then
    python3 -m json.tool "$media_body" 2>/dev/null || sed -n '1,80p' "$media_body"
    rm -f "$media_body"
    if [[ "$certificate_is_temporary" == true ]]; then
      rm -f "$certificate_file"
    fi
    return 1
  fi

  media_connected_via="$(python3 - "$media_body" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    media = json.load(stream)

print(media.get("ConnectedVia") or "Unknown")
PY
)"
  if [[ "$media_connected_via" == "Applet" ]]; then
    echo "Virtual media is owned by an iLO remote-console applet." >&2
    echo "Disconnect virtual media and close active remote-console sessions, then retry." >&2
    rm -f "$media_body"
    if [[ "$certificate_is_temporary" == true ]]; then
      rm -f "$certificate_file"
    fi
    return 1
  fi

  read -r standard_target oem_target oem_eject_target < <(python3 - "$media_body" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    media = json.load(stream)

standard = (
    media.get("Actions", {})
    .get("#VirtualMedia.InsertMedia", {})
    .get("target", "")
)
oem = (
    media.get("Oem", {})
    .get("Hpe", {})
    .get("Actions", {})
    .get("#HpeiLOVirtualMedia.InsertVirtualMedia", {})
    .get("target", "")
)
oem_eject = (
    media.get("Oem", {})
    .get("Hpe", {})
    .get("Actions", {})
    .get("#HpeiLOVirtualMedia.EjectVirtualMedia", {})
    .get("target", "")
)
print(standard, oem, oem_eject)
PY
  )
  rm -f "$media_body"

  if [[ "$iso_scheme" == "https" ]]; then
    if [[ -z "$oem_target" ]]; then
      echo "HPE OEM InsertVirtualMedia action was not advertised by this iLO" >&2
      if [[ "$certificate_is_temporary" == true ]]; then
        rm -f "$certificate_file"
      fi
      return 1
    fi
    insert_target="$oem_target"
    echo "HPE OEM action: ${oem_target}"
  else
    if [[ -z "$standard_target" ]]; then
      echo "Standard InsertMedia action was not advertised by this iLO" >&2
      return 1
    fi
    insert_target="$standard_target"
    echo "Standard Redfish action: ${standard_target}"
  fi

  echo "===== Eject existing media, if any ====="
  eject_body="$(mktemp)"
  eject_code="$(curl -skS \
    -u "${ILO_USER}:${ILO_PASSWORD}" \
    -X POST \
    -H 'Content-Type: application/json' \
    -d '{}' \
    -o "$eject_body" \
    -w '%{http_code}' \
    "https://${ILO_HOST}/redfish/v1/Managers/1/VirtualMedia/2/Actions/VirtualMedia.EjectMedia/")"
  echo "POST EjectMedia -> HTTP ${eject_code}"
  if [[ ! "$eject_code" =~ ^2 ]] && \
     grep -q 'UnsupportedOperation' "$eject_body" && \
     [[ -n "$oem_eject_target" ]]; then
    echo "Standard eject was unsupported; trying HPE OEM eject action"
    eject_code="$(curl -skS \
      -u "${ILO_USER}:${ILO_PASSWORD}" \
      -X POST \
      -H 'Content-Type: application/json' \
      -d '{}' \
      -o "$eject_body" \
      -w '%{http_code}' \
      "https://${ILO_HOST}${oem_eject_target}")"
    echo "POST HpeiLOVirtualMedia.EjectVirtualMedia -> HTTP ${eject_code}"
  fi
  if [[ ! "$eject_code" =~ ^2 ]] && ! grep -q 'NoVirtualMediaConnectionAvailable' "$eject_body"; then
    python3 -m json.tool "$eject_body" 2>/dev/null || sed -n '1,80p' "$eject_body"
    rm -f "$eject_body"
    if [[ "$certificate_is_temporary" == true ]]; then
      rm -f "$certificate_file"
    fi
    return 1
  fi
  rm -f "$eject_body"

  if [[ "$iso_scheme" == "https" ]]; then
    insert_payload="$(ISO_URL="$iso_url" CERTIFICATE_FILE="$certificate_file" python3 -c '
import json
import os

with open(os.environ["CERTIFICATE_FILE"]) as stream:
    certificate = stream.read()

print(json.dumps({
    "Image": os.environ["ISO_URL"],
    "Certificate": certificate,
    "WriteProtected": True,
}))
')"
    echo "===== Insert HTTPS ISO with HPE certificate-aware action ====="
  else
    insert_payload="$(ISO_URL="$iso_url" python3 -c '
import json
import os

print(json.dumps({
    "Image": os.environ["ISO_URL"],
    "Inserted": True,
    "WriteProtected": True,
    "TransferProtocolType": "HTTP",
}))
')"
    echo "===== Insert HTTP ISO with standard Redfish action ====="
  fi

  insert_body="$(mktemp)"
  http_code="$(curl -skS \
    -u "${ILO_USER}:${ILO_PASSWORD}" \
    -X POST \
    -H 'Content-Type: application/json' \
    --data-binary "$insert_payload" \
    -o "$insert_body" \
    -w '%{http_code}' \
    "https://${ILO_HOST}${insert_target}")"
  echo "POST InsertMedia -> HTTP ${http_code}"
  if [[ ! "$http_code" =~ ^2 ]]; then
    python3 -m json.tool "$insert_body" 2>/dev/null || sed -n '1,80p' "$insert_body"
    rm -f "$insert_body"
    if [[ "$certificate_is_temporary" == true ]]; then
      rm -f "$certificate_file"
    fi
    return 1
  fi
  python3 -m json.tool "$insert_body" 2>/dev/null || true
  rm -f "$insert_body"
  if [[ "$certificate_is_temporary" == true ]]; then
    rm -f "$certificate_file"
  fi

  echo "===== Set virtual CD boot once ====="
  redfish_request PATCH \
    /redfish/v1/Managers/1/VirtualMedia/2/ \
    '{"Oem":{"Hpe":{"BootOnNextServerReset":true}}}'
  redfish_request PATCH \
    /redfish/v1/Systems/1/ \
    '{"Boot":{"BootSourceOverrideTarget":"Cd","BootSourceOverrideEnabled":"Once"}}'

  echo "===== Verify mount and boot readiness ====="
  if ! {
    curl -skS \
      -u "${ILO_USER}:${ILO_PASSWORD}" \
      "https://${ILO_HOST}/redfish/v1/Managers/1/VirtualMedia/2/"
    curl -skS \
      -u "${ILO_USER}:${ILO_PASSWORD}" \
      "https://${ILO_HOST}/redfish/v1/Systems/1/"
  } | EXPECTED_ISO_URL="$iso_url" python3 -c '
import json
import os
import sys

decoder = json.JSONDecoder()
content = sys.stdin.read()
media, offset = decoder.raw_decode(content)
system, _ = decoder.raw_decode(content, offset)

boot = system.get("Boot", {})
hpe = media.get("Oem", {}).get("Hpe", {})
checks = {
    "Inserted": media.get("Inserted") is True,
    "MountedImageMatches": media.get("Image") == os.environ["EXPECTED_ISO_URL"],
    "BootOnNextServerReset": hpe.get("BootOnNextServerReset") is True,
    "BootOverrideEnabled=Once": boot.get("BootSourceOverrideEnabled") == "Once",
    "BootOverrideTarget=Cd": boot.get("BootSourceOverrideTarget") == "Cd",
}

for name, passed in checks.items():
    print("{}: {}".format(name, "PASS" if passed else "FAIL"))

if not all(checks.values()):
    raise SystemExit("Refusing to reboot because mount/boot readiness checks failed")
'; then
    return 1
  fi
}

reboot_host() {
  echo "===== Reboot physical host ====="
  echo "Test started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  redfish_request POST \
    /redfish/v1/Systems/1/Actions/ComputerSystem.Reset/ \
    '{"ResetType":"ForceRestart"}'
}

echo "Output: ${OUTPUT_FILE}"
echo "Target iLO: ${ILO_HOST}"
echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

show_state

if [[ -n "$INSTALLATION_DISK_ID" ]]; then
  pin_installation_disk
fi

if [[ "$CONFIGURE_DNS" == true ]]; then
  configure_dns
  show_state
fi

if [[ "$MOUNT_ISO" == true ]]; then
  mount_iso
  show_state
fi

if [[ "$HANDOFF_TO_DISK" == true ]]; then
  handoff_to_disk
elif [[ "$REBOOT_HOST" == true ]]; then
  reboot_host
  echo "The reboot was submitted. Rerun without action flags after POST to collect final state and events."
else
  show_events
fi

echo "Completed: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
