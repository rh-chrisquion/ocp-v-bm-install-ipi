# OCP-V 4.20 bare-metal Ansible scaffold (HPE Gen11)

This project automates two parts of an OpenShift 4.20 bare-metal agent install workflow:

1. Generate `install-config.yaml` and `agent-config.yaml`
2. Optionally publish and serve the generated agent ISO to bare-metal hosts

The current model is a 5-node deployment where all nodes are control-plane and schedulable compute.

## Current playbook behavior

`site.yml` contains two plays:

- `ocp_v420_baremetal` on `localhost`: always runs and generates manifests
- `ocp_v420_baremetal_image_server` on `image_server`: runs only when `ocp_agent_image_publish_enabled=true`

The image-server play requires privilege escalation (`become: true`) because it writes to `/var/lib` and installs a `systemd` unit.

## Network model

The network model is inventory-driven and expects three LACP (802.3ad) bonds per node:

- OCP data plane bond
- Storage bond
- UDP multicast bond

Each bond defines:

- Bond name
- Two physical NIC members
- MTU
- Optional gateway/default route
- Optional DNS servers

## Repository layout

- `site.yml`: entry playbook
- `inventories/lab/hosts.yml`: inventory (includes `image_server` group)
- `inventories/lab/group_vars/all.yml`: all configurable values
- `roles/ocp_v420_baremetal`: manifest generation role
- `roles/ocp_v420_baremetal_image_server`: ISO publishing + HTTP service role

## Inventory configuration

Update `inventories/lab/group_vars/all.yml`:

- Cluster metadata (`ocp_cluster_name`, `ocp_base_domain`)
- Credentials (`ocp_pull_secret`, `ocp_ssh_public_key`)
- VIPs (`ocp_api_vip`, `ocp_ingress_vip`)
- Network CIDRs and `ocp_network_bonds`
- Node inventory under `ocp_nodes` (BMC, boot MAC, root device hint, per-bond IPs)
- Image publishing variables (`ocp_agent_image_*`)

Update `inventories/lab/hosts.yml`:

- Set the `image_server` host to the provisioning machine that will serve the ISO
- Ensure Ansible can connect to that host and escalate privileges

## End-to-end workflow

From the project directory:

```bash
cd ocp-v420-baremetal-ansible
```

### 1) Generate manifests

```bash
ansible-playbook site.yml
```

Expected output files:

- `build/install-config.yaml`
- `build/agent-config.yaml`

### 2) Build the agent ISO

```bash
openshift-install agent create image --dir build
```

### 3) Publish and serve the ISO

Set `ocp_agent_image_publish_enabled: true` and set `ocp_agent_image_url_host` to an IP/FQDN reachable by bare-metal hosts, then run:

```bash
ansible-playbook site.yml -e ocp_agent_image_publish_enabled=true
```

The image-server role will:

- Locate the newest `*.iso` in `ocp_agent_image_source_dir` (default: `./build`)
- Copy it to `ocp_agent_image_publish_dir` (default: `/var/lib/ocp-agent-image`)
- Install and start `ocp-agent-image-server` (`python3 -m http.server`)
- Print the final boot URL for node media configuration

## Image publishing variables

Common variables in `inventories/lab/group_vars/all.yml`:

- `ocp_agent_image_publish_enabled` (default: `false`)
- `ocp_agent_image_source_dir` (default: `{{ ocp_install_dir }}`)
- `ocp_agent_image_glob` (default: `*.iso`)
- `ocp_agent_image_publish_dir` (default: `/var/lib/ocp-agent-image`)
- `ocp_agent_image_publish_filename` (optional override)
- `ocp_agent_image_server_port` (default: `8080`)
- `ocp_agent_image_url_host` (must be reachable by bare-metal hosts)

