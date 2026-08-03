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

By default, `sources/rosa-hcp-hub-terraform` auto-discovers this stack's VPC,
private subnets, and machine CIDR directly from AWS by tag, as long as its
`network_name` matches this stack's `network_name` (default
`rosa-hcp-hub-network` in both) and both stacks target the same `aws_region`.
No manual output copying is required in that case.

The VPC is tagged `Name = "${network_name}-vpc"`, private subnets are tagged
`Attributes = "private"` (plus `kubernetes.io/role/internal-elb = "1"`), and
public subnets are tagged `Attributes = "public"` (plus
`kubernetes.io/role/elb = "1"`) to support this lookup.

If the ROSA cluster stack's auto-discovery is disabled or overridden, use
these outputs manually instead:

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

## Optional on-prem DNS resolution (for an on-prem bastion)

`create_onprem_private_routes` (above) only gives on-prem hosts an *IP path*
into the VPC. It does not help them resolve the private cluster's hostnames:
a private ROSA HCP cluster's `api.<cluster-domain>` and
`*.apps.<cluster-domain>` records live in a Route 53 **private hosted zone**
that OCM associates only with this VPC, so only resolvers inside the VPC
(or VPCs explicitly associated with that zone) can answer for it -- an
on-prem DNS server has no way to know those records exist.

Set `create_onprem_dns_resolver = true` and provide `onprem_dns_cidrs` to
create a Route 53 Resolver **inbound endpoint** in the private subnets. This
exposes the VPC's own resolver (which *does* know about the private hosted
zone) to on-prem DNS servers via conditional forwarding, with no direct
dependency on this repo's ROSA cluster stack -- it works for any private
hosted zone associated with this VPC.

```hcl
create_onprem_dns_resolver = true
onprem_dns_cidrs = [
  "10.20.10.0/24"
]
```

After `apply`, get the endpoint's IPs (one per AZ, for HA):

```bash
terraform output onprem_resolver_endpoint_ips
```

On your on-prem DNS server (BIND, Windows DNS, dnsmasq, etc.), add a
conditional forwarding zone for the cluster's domain -- everything after
`api.` in `cluster_api_url` from the hub stack's outputs -- pointed at those
IPs on port 53. For example, in BIND:

```text
zone "c2d9y9w7o6u9g3c.fl4f.p3.openshiftapps.com" {
    type forward;
    forward only;
    forwarders { 10.200.x.x; 10.200.y.y; };
};
```

Once that's in place, **any on-prem host with a route to the VPC** --
including a plain on-prem bastion/jump host with no AWS credentials or SSM
agent at all -- can resolve and reach the cluster directly:

```bash
oc login https://api.<cluster-domain>:443 -u <user> -p <password>
```

This is a simpler path than the AWS-side SSM bastion documented in
`sources/rosa-hcp-hub-terraform/README.md` when on-prem-to-VPC connectivity
(TGW/VGW) already exists for another reason -- e.g. the same bare-metal
network this repo's `ocp-baremetal-bootstrap` source targets -- since it's
plain routed IP + DNS, with no port-forwarding tunnel required. The AWS SSM
bastion is the better fit when no such on-prem connectivity exists yet, or
when you'd rather avoid opening any inbound path from on-prem into the VPC
at all.

## About VPC endpoints

A VPC endpoint lets private subnets reach AWS services without sending traffic
through an internet NAT path.

- Interface endpoint: ENIs in your private subnets (for example `sts`,
  `ecr.api`, `ecr.dkr`).
- Gateway endpoint: route-table target for services like `s3`.

For ROSA HCP, endpoints typically reduce NAT egress dependency, improve
security posture, and reduce NAT data processing costs.
