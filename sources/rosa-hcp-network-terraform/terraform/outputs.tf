output "vpc_id" {
  description = "VPC ID used for ROSA HCP worker networking."
  value       = aws_vpc.this.id
}

output "machine_cidr" {
  description = "Machine CIDR supernet to pass into ROSA HCP cluster provisioning."
  value       = aws_vpc.this.cidr_block
}

output "availability_zones" {
  description = "Availability zones configured for this network stack."
  value       = var.availability_zones
}

output "private_subnet_ids" {
  description = "Private subnet IDs to use as aws_subnet_ids in ROSA HCP."
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "Public subnet IDs that host NAT gateways."
  value       = aws_subnet.public[*].id
}

output "private_route_table_ids" {
  description = "Private route table IDs associated with worker subnets."
  value       = aws_route_table.private[*].id
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs used for private subnet egress."
  value       = aws_nat_gateway.this[*].id
}

output "onprem_route_target_type" {
  description = "On-prem private route target type (disabled, tgw, or vgw)."
  value       = local.onprem_route_target_type
}

output "onprem_route_entries" {
  description = "Computed per-route-table on-prem route intents."
  value       = local.onprem_route_entries
}

output "onprem_route_ids" {
  description = "Created on-prem route IDs by synthetic route key."
  value = merge(
    { for key, route in aws_route.onprem_private_tgw : key => route.id },
    { for key, route in aws_route.onprem_private_vgw : key => route.id }
  )
}

output "interface_vpc_endpoint_ids" {
  description = "Map of interface endpoint IDs by endpoint service suffix."
  value       = { for name, endpoint in aws_vpc_endpoint.interface : name => endpoint.id }
}

output "s3_gateway_endpoint_id" {
  description = "S3 gateway endpoint ID when enabled."
  value       = try(aws_vpc_endpoint.s3_gateway[0].id, null)
}

output "onprem_resolver_endpoint_ips" {
  description = "IP addresses of the Route 53 Resolver inbound endpoint, when create_onprem_dns_resolver is true. Point an on-prem conditional-forwarding rule for the cluster's private hosted zone at these IPs on port 53."
  value       = try(aws_route53_resolver_endpoint.onprem_inbound[0].ip_address[*].ip, null)
}
