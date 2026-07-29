# ROSA HCP Hub Terraform Source

This source contains Terraform for provisioning the central management ROSA HCP
cluster that will host ACM, AAP, and optional Argo CD workloads.

## Design targets

- Hosted Control Plane (HCP) ROSA cluster
- OpenShift `4.22.x`
- Upsized workers for hub tooling (`m5.2xlarge` default)
- Autoscaled machine pools with per-AZ min/max controls
- Module-aligned implementation using `terraform-redhat/rosa-hcp/rhcs`

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
# Set aws_subnet_ids, aws_availability_zones, and machine_cidr
# from network stack outputs.
# Keep aws_region aligned to the network stack region.
terraform init
terraform plan
```

`terraform.tfvars` is gitignored so environment-specific values stay local.

Example output extraction from the network stack:

```bash
cd sources/rosa-hcp-network-terraform/terraform
terraform output -json private_subnet_ids
terraform output -json availability_zones
terraform output -raw machine_cidr
```

## Notes

- This configuration intentionally sets `cluster_autoscaler_enabled = false`
  because the module docs currently flag that setting as unavailable.
- Day-1 worker autoscaling is implemented through module `machine_pools`.
- For ACM+AAP+Argo CD hub clusters, keep `min_replicas_per_pool >= 2` for HA.
- Validate min/max worker settings in a non-production account before Week 1-2 rollout.
