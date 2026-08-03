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

## Notes

- This configuration intentionally sets `cluster_autoscaler_enabled = false`
  because the module docs currently flag that setting as unavailable.
- Day-1 worker autoscaling is implemented through module `machine_pools`.
- For ACM+AAP+Argo CD hub clusters, keep `min_replicas_per_pool >= 2` for HA.
- Validate min/max worker settings in a non-production account before Week 1-2 rollout.

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
