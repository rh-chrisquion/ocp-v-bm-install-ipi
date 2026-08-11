# ROSA HCP Hub Terraform Source

This source contains Terraform for provisioning the central management ROSA HCP
cluster that will host ACM, AAP, and optional Argo CD workloads.

## Design targets

- Hosted Control Plane (HCP) ROSA cluster
- OpenShift `4.22.x`
- Upsized workers for hub tooling (`m5.2xlarge` default)
- Autoscaled machine pools with per-AZ min/max controls
- Module-aligned implementation using `terraform-redhat/rosa-hcp/rhcs`
- VPC/subnet/CIDR auto-discovery from AWS by tag (no manual output copying required by default)
- Day-1 install of OpenShift GitOps and External Secrets Operator as part of
  `terraform apply` (no separate operator install step)
- Day-1 External Secrets IRSA role + `ClusterSecretStore` for AWS Secrets
  Manager as part of the same apply

## Terraform roots

Use two stacks:

- Network foundation: `sources/rosa-hcp-network-terraform/terraform`
- ROSA cluster stack: `sources/rosa-hcp-hub-terraform/terraform`

## Quick start

```bash
cd sources/rosa-hcp-network-terraform/terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply

cd sources/rosa-hcp-hub-terraform/terraform
cp terraform.tfvars.example terraform.tfvars
# Keep aws_region aligned to the network stack region.
# By default, aws_subnet_ids, aws_availability_zones, and machine_cidr are
# auto-discovered from AWS (see "VPC/subnet/CIDR auto-discovery" below) as
# long as network_name matches the network stack.
terraform init
terraform plan
```

`terraform.tfvars` is gitignored so environment-specific values stay local.

## VPC/subnet/CIDR auto-discovery

By default (`enable_vpc_discovery = true`), this stack looks up its network
inputs directly from AWS instead of requiring manual copy/paste from the
network stack's outputs:

- The VPC is found by its `Name` tag: `"${network_name}-vpc"`.
- Private worker subnets are found within that VPC by
  `private_subnet_selector_tags` (default `Attributes = "private"`).
- `machine_cidr` comes from the discovered VPC's CIDR block.
- `aws_availability_zones` are derived per-subnet, so AZ-to-subnet
  correspondence is always correct regardless of subnet ID ordering.

This means as long as `network_name` here matches the sibling
`rosa-hcp-network-terraform` stack's `network_name` (default
`rosa-hcp-hub-network` in both), and `aws_region` matches, no manual
`terraform output` extraction is needed. Use `terraform plan` and inspect the
`discovered_vpc_id`, `effective_subnet_ids`, `effective_availability_zones`,
and `effective_machine_cidr` outputs to confirm what was resolved.

Any of `aws_subnet_ids`, `aws_availability_zones`, or `machine_cidr` can
still be set explicitly in `terraform.tfvars` to override auto-discovery for
that field, which is useful when the VPC isn't managed by the sibling network
stack (for example, a VPC owned by a separate landing-zone team). Set
`enable_vpc_discovery = false` to disable auto-discovery entirely and require
all three values explicitly, matching the previous manual behavior.

## Day-1 operators (GitOps + External Secrets)

With `install_day1_operators = true` (default), the same `terraform apply` that
creates the cluster also:

1. Applies `manifests/openshift-gitops-operator.yaml` and
   `manifests/external-secrets-operator.yaml` (Subscriptions use
   `installPlanApproval: Automatic` so the first InstallPlan completes).
2. Waits for each operator CSV to reach `Succeeded`.
3. Patches both Subscriptions to `installPlanApproval: Manual` so later
   upgrades require explicit approval.
4. When `configure_eso_clustersecretstore = true` (default):
   - Creates an IAM role trusted for IRSA against the cluster OIDC provider
   - Applies `manifests/eso/external-secrets-config.yaml` (operand), including
     NetworkPolicy egress TCP/443 so the controller can reach AWS STS and
     Secrets Manager (Red Hat ESO defaults to deny-all egress otherwise)
   - Annotates `ServiceAccount/external-secrets` with the role ARN and
     restarts the ESO deployment
   - Applies `ClusterSecretStore/aws-secrets-manager` for AWS Secrets Manager
   - Waits until the store reports `Ready=True`
5. Optionally (`eso_run_e2e_test = true`) creates a Secrets Manager test
   secret and validates an `ExternalSecret` sync

Requirements:

- `oc` on the Terraform runner's `PATH`
- `create_htpasswd_admin = true` (used for `oc login`)
- `create_oidc = true` (required for ESO IRSA / ClusterSecretStore)
- API reachability from the Terraform runner — for `private_cluster = true`,
  that means VPN/TGW into the VPC, or an active SSM port-forward via the
  bastion (see below), before/during apply

To skip operator install (and therefore ESO ClusterSecretStore config), set
`install_day1_operators = false`.

To install operators but skip ClusterSecretStore / IRSA wiring:

```hcl
configure_eso_clustersecretstore = false
```

To re-run operator + ESO config after a failed apply (or after changing
manifests), replace the tracker resource:

```bash
terraform apply -replace='terraform_data.day1_operators[0]'
```

IAM / IRSA details for the ESO role are documented in
`docs/eso-iam-setup-guide.md`.
## Notes

- This configuration intentionally sets `cluster_autoscaler_enabled = false`
  because the module docs currently flag that setting as unavailable.
- Day-1 worker autoscaling is implemented through module `machine_pools`.
- For ACM+AAP+Argo CD hub clusters, keep `min_replicas_per_pool >= 2` for HA.
- Validate min/max worker settings in a non-production account before Week 1-2 rollout.

## Connecting to a private cluster via the bastion host

`private_cluster` (`rhcs_cluster_rosa_hcp`'s `private` attribute) is
**immutable after cluster creation** -- set it before the first `terraform
apply` for a new cluster; it cannot be toggled on an existing one (see the
[rhcs_cluster_rosa_hcp docs](https://registry.terraform.io/providers/terraform-redhat/rhcs/latest/docs/resources/cluster_rosa_hcp)).

With `private_cluster = true`, the API server and default router have **no
public endpoint** -- `oc login`/console access from outside the VPC requires
a path into the private subnets. Set `create_bastion = true` (`bastion.tf`)
to provision a small EC2 instance there for exactly this, reachable only
through **AWS Systems Manager Session Manager** -- no SSH key pair, no
inbound security group rules, IAM- and CloudTrail-audited access instead.

### Prerequisites

- The [Session Manager plugin for the AWS CLI](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
  installed locally (`session-manager-plugin`).
- Your AWS credentials need `ssm:StartSession` on the bastion instance (already
  covered if you're using the same credentials as the rest of this stack).

### Connect to the API

```bash
API_HOST=$(terraform output -raw cluster_api_url | sed -E 's#https://([^:]+).*#\1#')
BASTION_ID=$(terraform output -raw bastion_instance_id)

# Map the real API hostname to localhost so the cluster's TLS certificate
# (issued for that hostname, not "localhost") validates without
# --insecure-skip-tls-verify.
echo "127.0.0.1 ${API_HOST}" | sudo tee -a /etc/hosts

# Start the port-forward tunnel (leave running in its own terminal)
aws ssm start-session \
  --target "${BASTION_ID}" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${API_HOST}\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"443\"]}"
```

In a separate terminal, log in exactly as you would against the real
hostname (it now resolves to your local tunnel via `/etc/hosts`):

```bash
oc login "https://${API_HOST}:443" -u sandbox-admin -p "$(terraform output -raw htpasswd_admin_password)"
```

### Connect to the console

Same pattern, using the console hostname and a different local port so you
can run both tunnels at once:

```bash
CONSOLE_HOST=$(terraform output -raw cluster_console_url | sed -E 's#https://([^/]+).*#\1#')
echo "127.0.0.1 ${CONSOLE_HOST}" | sudo tee -a /etc/hosts

aws ssm start-session \
  --target "${BASTION_ID}" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${CONSOLE_HOST}\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"443\"]}"
```

Then browse to `https://<CONSOLE_HOST>` locally. This only maps the
console's own hostname -- individual application `Route`s under
`apps.<cluster-domain>` each have their own hostname and would need their
own `/etc/hosts` entry + tunnel to reach the same way. For routine
multi-route/browser access to a private cluster, an
[AWS Client VPN endpoint](https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/what-is.html)
into the VPC is a better fit than one-off SSM tunnels -- not currently
provisioned by this stack.

### Cleanup

Remove the `/etc/hosts` entries and stop the `aws ssm start-session`
process(es) when done; the bastion instance itself can stay running (or set
`create_bastion = false` and re-apply to remove it) since it has no public
exposure either way.

### Alternative: an on-prem bastion instead

If on-prem-to-VPC connectivity (Transit Gateway or VPN Gateway) already
exists -- for example the same network this repo's `ocp-baremetal-bootstrap`
source targets -- a plain bastion on-prem can reach the private cluster
directly over routed IP, with no SSM tunnel and no AWS credentials needed on
that host at all. This needs one more piece the AWS-side bastion above
doesn't: DNS resolution for the cluster's private hosted zone from on-prem.
See "Optional on-prem DNS resolution" in
`sources/rosa-hcp-network-terraform/README.md`.

## GitHub Actions deployment (`.github/workflows/rosa-hub-terraform.yaml`)

`rhcs_token` can be sourced from a repository secret instead of a local
`terraform.tfvars` when running this stack from CI:

- **Secret name:** `RHHC_ROSA_SVC_TOKEN` (repository secret, not environment-scoped).
  Set it with `gh secret set RHHC_ROSA_SVC_TOKEN` or via
  **Settings > Secrets and variables > Actions** in GitHub.
- **Workflow:** manually triggered (`workflow_dispatch`) only -- this never
  runs automatically on push/PR, consistent with this repo's stance of not
  auto-applying changes to live cloud infrastructure.
- **Inputs:**
  - `action`: `plan` (default), `apply`, or `destroy`.
  - `rhcs_token_override`: optional, supplies a one-time token for that run
    instead of the `RHHC_ROSA_SVC_TOKEN` secret. **Caution:** unlike secrets,
    `workflow_dispatch` string inputs are visible to anyone with read access
    to the run (including in the "re-run workflow" UI) -- only use this for
    a token you're comfortable being visible that way, and prefer updating
    the `RHHC_ROSA_SVC_TOKEN` secret itself for anything longer-lived.
- **AWS credentials:** selectable per run via the `aws_auth_method` input --
  Duo/Secrets Manager is one option, not a requirement. Pick whichever this
  AWS account actually supports:

  | `aws_auth_method` | Required secrets | Notes |
  | --- | --- | --- |
  | `access_keys` (default) | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`; optionally `AWS_SESSION_TOKEN` for temporary/STS creds | Simplest path; fine for sandbox accounts that don't enforce Duo |
  | `oidc` | `AWS_OIDC_ROLE_ARN` (the IAM role ARN to assume) | No long-lived keys stored in GitHub at all; requires a one-time IAM OIDC identity provider trust for this repo. Recommended over `access_keys` once set up |
  | `secrets_manager` | n/a yet -- **placeholder** | For this org's Duo-backed AWS Secrets Manager flow. The corresponding workflow step is a TODO; use `access_keys` or `oidc` until it's filled in |

  Regardless of method, a **"Verify AWS credentials resolved"** step runs
  `aws sts get-caller-identity` immediately after, so a bad/missing
  credential fails fast with a clear message instead of a confusing error
  partway through `terraform plan`.

  Note that `plan` itself (not just `apply`/`destroy`) genuinely needs valid
  AWS credentials -- this stack does live VPC/subnet auto-discovery via AWS
  data sources during plan (see "VPC/subnet/CIDR auto-discovery" below), so
  there's no fully credential-free plan path for this stack. `terraform
  validate` (syntax/type checking only, no AWS calls) is the one command
  here that never needs credentials, if that's ever useful as a lighter-weight
  PR-time check.

Local `terraform.tfvars` (gitignored) remains the normal path for
interactive/sandbox use; the GitHub secrets only matter for the CI workflow
path.

- **`ci.tfvars`** (committed, not gitignored): supplies the non-sensitive
  required variables that have no default (`cluster_name`, `aws_region`,
  `account_role_prefix`, `operator_role_prefix`) for the CI workflow, since
  `terraform.tfvars` is never present in a CI checkout. Every command the
  workflow runs uses `-input=false` so a genuinely missing variable fails
  immediately with a clear error instead of hanging forever waiting for
  interactive input that can never arrive in CI. Update `ci.tfvars` to match
  whatever this environment should actually be named before running
  `action=apply` for real.
