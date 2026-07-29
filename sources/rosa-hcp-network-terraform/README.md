# ROSA HCP Network Terraform Source

This source provisions the AWS network foundation for ROSA HCP using an
enterprise split-stack pattern:

- VPC and CIDR
- Public/private subnets per AZ
- NAT gateway strategy (single or one-per-AZ)
- Route tables and routing
- Optional VPC endpoints for private AWS service access

Use this stack first, then pass outputs into
`sources/rosa-hcp-hub-terraform/terraform`.

## Terraform root

- `sources/rosa-hcp-network-terraform/terraform`

## Quick start

```bash
cd sources/rosa-hcp-network-terraform/terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
```

Then use outputs in the ROSA cluster stack:

- `private_subnet_ids` -> `aws_subnet_ids`
- `availability_zones` -> `aws_availability_zones`
- `machine_cidr` -> `machine_cidr`

## Optional on-prem private routes

By default, this stack creates no private routes for on-prem CIDRs. To add
explicit private routes from ROSA worker subnets to on-prem prefixes, enable
`create_onprem_private_routes` and choose exactly one route target type:

- Transit Gateway (`onprem_transit_gateway_id`)
- Virtual Private Gateway (`onprem_vpn_gateway_id`)

### TGW mode example

```hcl
create_onprem_private_routes = true
onprem_route_cidrs = [
  "10.20.10.0/24",
  "10.30.10.0/24"
]
onprem_transit_gateway_id = "tgw-0123456789abcdef0"
onprem_vpn_gateway_id     = null
```

### VGW mode example

```hcl
create_onprem_private_routes = true
onprem_route_cidrs = [
  "10.20.10.0/24",
  "10.30.10.0/24"
]
onprem_transit_gateway_id = null
onprem_vpn_gateway_id     = "vgw-0123456789abcdef0"
```

### Advanced route-table targeting

Use `onprem_route_table_ids_override` only when your enterprise network pattern
requires routing to a different route-table set than the one created by this
stack.

## About VPC endpoints

A VPC endpoint lets private subnets reach AWS services without sending traffic
through an internet NAT path.

- Interface endpoint: ENIs in your private subnets (for example `sts`,
  `ecr.api`, `ecr.dkr`).
- Gateway endpoint: route-table target for services like `s3`.

For ROSA HCP, endpoints typically reduce NAT egress dependency, improve
security posture, and reduce NAT data processing costs.
