# OCP-V 4.20 bare-metal Ansible scaffold (HPE Gen11)

This Ansible scaffold generates `install-config.yaml` and `agent-config.yaml` for a 5-node OpenShift 4.20 bare-metal deployment where all nodes are both control plane and schedulable compute.

The network model is inventory-driven and expects three separate LACP (802.3ad) bonds per node:

- OCP data plane bond
- Storage bond
- UDP multicast bond

Each bond is defined by:

- Bond name
- Two physical NIC members
- MTU
- Optional gateway/default route
- Optional DNS servers

## Layout

- `site.yml`: entry playbook
- `inventories/lab/group_vars/all.yml`: all configurable values
- `roles/ocp_v420_baremetal/templates/install-config.yaml.j2`: installer config template
- `roles/ocp_v420_baremetal/templates/agent-config.yaml.j2`: host/bond network template
- `roles/ocp_v420_baremetal_image_server`: publishes generated ISO over HTTP for bare-metal hosts

## Configure

Edit `inventories/lab/group_vars/all.yml`:

- Cluster metadata (`ocp_cluster_name`, `ocp_base_domain`)
- Credentials (`ocp_pull_secret`, `ocp_ssh_public_key`)
- VIPs (`ocp_api_vip`, `ocp_ingress_vip`)
- Network CIDRs
- Bond definitions under `ocp_network_bonds`
- Node inventory under `ocp_nodes` (BMC, boot MAC, root device hint, per-bond IPs)
- `image_server` host in `inventories/lab/hosts.yml` (the machine that will host the ISO)
- Image publishing settings (`ocp_agent_image_*`)

## Generate manifests

```bash
cd ocp-v420-baremetal-ansible
ansible-playbook site.yml
```

Generated output:

- `build/install-config.yaml`
- `build/agent-config.yaml`

## Build an agent-based install image

After generation, run OpenShift installer from this same directory:

```bash
openshift-install agent create image --dir build
```

Use the resulting ISO to boot each HPE Gen11 node.

## Publish the generated image for bare-metal nodes

Set these values in `inventories/lab/group_vars/all.yml`:

- `ocp_agent_image_publish_enabled: true`
- `ocp_agent_image_url_host`: IP or FQDN of the provisioning host reachable by bare-metal nodes
- Optional: `ocp_agent_image_server_port`, `ocp_agent_image_publish_dir`, `ocp_agent_image_publish_filename`

Run the playbook again to publish and serve the ISO:

```bash
ansible-playbook site.yml -e ocp_agent_image_publish_enabled=true
```

The role will:

- Find the newest `*.iso` in `ocp_agent_image_source_dir` (defaults to `build/`)
- Copy it into the publish directory
- Install and start a systemd service (`ocp-agent-image-server`) using `python3 -m http.server`
- Print the final URL for node boot media configuration

