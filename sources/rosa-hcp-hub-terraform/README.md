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
