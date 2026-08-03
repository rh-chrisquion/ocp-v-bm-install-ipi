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
  If `terraform apply` on the hub stack fails during cluster creation with:

  ```text
  Error: Can't create cluster with name '<name>': status is 400, identifier
  is '400', code is 'CLUSTERS-MGMT-400' ... billing account <account-id> not
  linked to organization <org-id> at the aws marketplace
  ```

  the AWS account has never been subscribed to the ROSA listing in AWS
  Marketplace and/or linked to your Red Hat org via OCM -- this is an
  account-enablement gap, not a Terraform or repo configuration problem. Fix:

  1. In the AWS Console for that account, search "ROSA" and click
     **Enable ROSA** (one-time Marketplace subscription; no cost until a
     cluster is actually created).
  2. **Important:** the AWS console page may already show ROSA as enabled
     (a green "You previously enabled ROSA..." message) even when the
     account-to-Red-Hat-org link isn't actually complete -- this happens on
     accounts that had ROSA subscribed once before (for example a recycled
     sandbox/demo AWS account). Enablement and org-linking are two separate
     steps. Look for a distinct **connect**/**link account** button further
     down the same "Verify ROSA prerequisites" page in the AWS console and
     click through it -- do not assume the green checkmark alone means
     you're done.
  3. `rosa login --token=<your OCM token>`, then `rosa init` to link the
     account's `ocm-role`/`user-role` to your Red Hat org.
  4. Confirm with `rosa verify permissions` and `rosa verify quota` before
     re-running `terraform apply`.

  Ephemeral/sandbox AWS accounts (for example training or demo environments)
  often block `aws-marketplace:Subscribe` via Service Control Policy
  specifically to prevent this kind of Marketplace subscription. If step 1
  fails with a permissions error, you likely need a different, persistent
  AWS account rather than a temporary sandbox one -- no `rosa`/Terraform
  configuration change can work around an SCP-blocked account.

  If the same error persists even after enabling and clicking through any
  connect/link button, the AWS account may be permanently linked to a
  *different* Red Hat organization from a prior use (Red Hat's account
  linking is one AWS account <-> one Red Hat org, and cannot be changed by
  the customer once set). On recycled/pooled sandbox accounts, requesting a
  fresh environment is usually faster than opening a Red Hat support ticket
  to release the old linking.

### 2. Verify AWS credentials

Before running Terraform, confirm your AWS credentials actually work:

```bash
aws sts get-caller-identity
```

This should return your account ID, user/role ARN, and caller ID. If it
instead fails with an error like:

```text
An error occurred (InvalidClientTokenId) when calling the GetCallerIdentity
operation: The security token included in the request is invalid.
```

this is an AWS credential problem, not a Terraform or repo configuration
issue -- Terraform will fail with the identical error on `plan`/`apply` since
it authenticates to AWS the same way. `InvalidClientTokenId` means AWS
doesn't recognize the access key ID at all (as opposed to `SignatureDoesNotMatch`,
which would mean the secret is wrong for an otherwise-valid key). Common
causes:

- The access key was deleted, deactivated, or rotated out.
- Stale/incorrect credentials left in `~/.aws/credentials` (e.g. from a
  different account or an old engagement).
- An `AWS_ACCESS_KEY_ID`/`AWS_PROFILE` environment variable is overriding
  the profile you meant to use.

Fix by updating `~/.aws/credentials` (or your active profile/SSO session)
with a valid access key, then re-run `aws sts get-caller-identity` until it
succeeds. There is no `terraform.tfvars` setting that works around this --
`aws_assume_role_arn` only layers a role assumption on top of already-valid
base credentials, so base credentials must authenticate successfully first
regardless of whether you use it.

### 3. Provision the network stack

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

### 4. Provision the ROSA HCP cluster stack

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

### 5. Access the cluster

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

If you set `private_cluster = true` (only settable at cluster creation --
see the source README), the API/console have no public endpoint. Set
`create_bastion = true` alongside it and see "Connecting to a private
cluster via the bastion host" in `sources/rosa-hcp-hub-terraform/README.md`
for the SSM-based connection steps. If on-prem-to-VPC connectivity already
exists instead (Transit Gateway/VPN Gateway, per the network stack's
`create_onprem_private_routes`), see "Optional on-prem DNS resolution" in
`sources/rosa-hcp-network-terraform/README.md` for a simpler on-prem-bastion
alternative that needs no SSM tunnel.

### 6. Next steps

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
