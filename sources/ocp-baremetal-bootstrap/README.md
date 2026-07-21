# OCP bare-metal bootstrap source

This source keeps bare-metal bootstrap automation app-centric under
`sources/ocp-baremetal-bootstrap`, aligned to ADR-0001.

## Contents

- `site.yml`: Ansible entry playbook
- `inventories/lab/`: inventory and variables
- `roles/ocp_v420_baremetal`: install-config and agent-config generation
- `roles/ocp_v420_baremetal_image_server`: generated ISO publishing and serving

## Usage

From this directory:

```bash
ansible-playbook site.yml
openshift-install agent create image --dir build
ansible-playbook site.yml -e ocp_agent_image_publish_enabled=true
```
