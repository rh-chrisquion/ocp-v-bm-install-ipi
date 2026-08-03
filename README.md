# OpenShift GitOps Repository

This repository is being aligned to an app-centric OpenShift GitOps model where:

- deployable application content lives in `sources/<app-name>/`
- per-cluster rollout is controlled by `clusters/<clusterName>/<app>.yaml` gate files
- organizational composition lives in `profiles/`
- architecture decisions are documented in `docs/adr/`

The active guardrails are in `AGENTS.md` and accepted ADRs (`0001`-`0010`).

## Repository layout

- `sources/`: application deployment units
  - `sources/app-of-apps/`: ApplicationSet and generator defaults
  - `sources/app-projects/`: AppProject/RBAC source content
  - `sources/ocp-baremetal-bootstrap/`: bare-metal bootstrap Ansible app source
  - `sources/rosa-hcp-network-terraform/`: AWS network foundation (VPC/subnets/NAT) for ROSA HCP
  - `sources/rosa-hcp-hub-terraform/`: ROSA HCP hub cluster provisioning (see "Deploying ROSA HCP from a blank environment" below)
- `clusters/`: cluster gate files and bootstrap overlays
  - `clusters/ocpv420/`: lab cluster gate set and app-of-apps bootstrap artifacts
- `profiles/`: team, cluster-type, and data-center profiles
- `docs/adr/`: architectural decision records
- `.github/`: CI and ADR compliance automation

## Deploying ROSA HCP from a blank environment

This walks through standing up the ROSA HCP hub cluster (network + cluster
stacks under `sources/rosa-hcp-network-terraform` and
`sources/rosa-hcp-hub-terraform`) starting from nothing but AWS and Red Hat
account access. See each source's own README for deeper detail; this section
is the end-to-end happy path.

### 1. Prerequisites

- An AWS account (or a cross-account role a client has granted you) with
  permission to create VPCs, IAM roles, and ROSA resources.
- A Red Hat account with ROSA enabled and an
  [OCM API token](https://console.redhat.com/openshift/token) (used as
  `rhcs_token`).
- Local tooling:
  - [Terraform](https://developer.hashicorp.com/terraform/install) `>= 1.6.0`
  - [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
    configured with credentials (`aws sts get-caller-identity` should succeed)
  - [ROSA CLI](https://docs.openshift.com/rosa/rosa_install_access_delete_clusters/rosa_getting_started_iam/rosa-installing-rosa.html)
    and `oc`, useful for verification and account role prerequisites
- Your AWS account must be enabled for ROSA at least once
  (`rosa verify permissions`, `rosa verify quota`, and `rosa init` are the
  standard one-time account bootstrap steps if this hasn't been done before).

### 2. Provision the network stack

The network stack creates the VPC, public/private subnets per AZ, NAT
gateways, and (by default) VPC endpoints that the ROSA cluster stack will
discover automatically.

```bash
cd sources/rosa-hcp-network-terraform/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set aws_region, network_name, CIDRs/AZs for this
# environment. Leave network_name at its default unless you also change it
# to match in the hub stack.
terraform init
terraform plan
terraform apply
```

### 3. Provision the ROSA HCP cluster stack

The cluster stack auto-discovers the VPC, private subnets, and machine CIDR
from AWS by tag as long as `network_name` and `aws_region` match the network
stack, so no manual output copying is required by default.

```bash
cd ../../rosa-hcp-hub-terraform/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set rhcs_token, cluster_name, env, aws_region
# (matching the network stack), account_role_prefix, operator_role_prefix.
terraform init
terraform plan
```

Review the `discovered_vpc_id`, `effective_subnet_ids`,
`effective_availability_zones`, and `effective_machine_cidr` outputs in the
plan to confirm the network stack resolved correctly, then:

```bash
terraform apply
```

Cluster creation (ROSA HCP control plane + worker machine pools) typically
takes 15-25 minutes.

### 4. Access the cluster

By default (`create_htpasswd_admin = true`), a sandbox cluster-admin user is
created for initial access:

```bash
terraform output cluster_console_url
terraform output htpasswd_admin_username
terraform output -raw htpasswd_admin_password
```

Log in with `oc login $(terraform output -raw cluster_api_url) -u <username> -p <password>`.

For shared or production clusters, front the cluster with your
organization's SSO instead by setting `enable_oidc_idp = true` (see the
"Identity providers" section in `sources/rosa-hcp-hub-terraform/terraform.tfvars.example`)
and disabling `create_htpasswd_admin` once that's confirmed working.

### 5. Next steps

- Bootstrap the app-of-apps (`sources/app-of-apps`) against the new cluster
  to start reconciling GitOps-managed workloads (ACM, AAP, Argo CD, etc.).
- Add a `clusters/<clusterName>/` gate-file directory for this cluster
  following the conventions in `docs/adr/0001-sources-by-app.md` and
  `docs/adr/0007-cluster-naming-convention.md`.
- To run this from CI instead of locally, see "GitHub Actions deployment" in
  `sources/rosa-hcp-hub-terraform/README.md`.

### Tearing down

Destroy in reverse order (cluster stack first, then network stack) to avoid
dependency errors:

```bash
cd sources/rosa-hcp-hub-terraform/terraform && terraform destroy
cd ../../rosa-hcp-network-terraform/terraform && terraform destroy
```

## Bootstrap app source (bare metal)

The previous top-level Ansible scaffold was moved to:

- `sources/ocp-baremetal-bootstrap/site.yml`
- `sources/ocp-baremetal-bootstrap/inventories/lab/`
- `sources/ocp-baremetal-bootstrap/roles/`

This keeps bootstrap automation app-centric and consistent with ADR-0001.

### Bare-metal workflow

```bash
cd sources/ocp-baremetal-bootstrap
ansible-playbook site.yml
openshift-install agent create image --dir build
ansible-playbook site.yml -e ocp_agent_image_publish_enabled=true
```

## Guardrail automation

CI and guardrail checks are defined in:

- `.github/workflows/ci.yaml`
- `.github/scripts/adr-compliance.sh`
- `.yamllint.yaml`
- `.markdownlint.yaml`
- `.kube-linter.yaml`

ADR compliance script enforces key mechanical invariants such as:

- gate file naming and top-level key restrictions
- required `app-of-apps.yaml` per cluster directory
- no `startingCSV` under `sources/`
- no Argo destination `name: in-cluster`

## Conventions

- Use `oc` (not `kubectl`) for OpenShift cluster interaction examples.
- Keep defaults centralized and use gate files only for intentional deviations.
- Keep production-specific pins (for example versions/images) explicit and auditable.
