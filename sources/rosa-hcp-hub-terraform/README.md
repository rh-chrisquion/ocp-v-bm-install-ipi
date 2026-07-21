# ROSA HCP Hub Terraform Source

This source contains Terraform for provisioning the central management ROSA HCP
cluster that will host ACM, AAP, and optional Argo CD workloads.

## Design targets

- Hosted Control Plane (HCP) ROSA cluster
- OpenShift `4.22.x`
- Upsized workers for hub tooling (`m5.2xlarge` default)
- Autoscaled machine pools with optional scale-to-zero (`min_replicas_per_pool = 0`)
- Module-aligned implementation using `terraform-redhat/rosa-hcp/rhcs`

## Terraform root

Use:

- `sources/rosa-hcp-hub-terraform/terraform`

## Quick start

```bash
cd sources/rosa-hcp-hub-terraform/terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
```

`terraform.tfvars` is gitignored so environment-specific values stay local.

## Notes

- This configuration intentionally sets `cluster_autoscaler_enabled = false`
  because the module docs currently flag that setting as unavailable.
- Day-1 worker autoscaling is implemented through module `machine_pools`.
- Set `min_replicas_per_pool = 0` to target scale-to-zero behavior in low/no-load periods.
- Validate min/max worker settings in a non-production account before Week 1-2 rollout.
