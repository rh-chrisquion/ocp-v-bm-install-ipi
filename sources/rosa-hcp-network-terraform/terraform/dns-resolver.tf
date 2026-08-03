# Route 53 Resolver inbound endpoint for hybrid DNS: lets on-prem DNS
# servers conditionally forward queries for the ROSA HCP cluster's private
# hosted zone into this VPC, so on-prem hosts (including an on-prem bastion)
# can resolve api/console/route hostnames after create_onprem_private_routes
# has given them an IP path in. See "Optional on-prem DNS resolution" in
# README.md for the on-prem-side forwarding configuration.

check "onprem_dns_resolver_requirements" {
  assert {
    condition     = !var.create_onprem_dns_resolver || length(var.onprem_dns_cidrs) > 0
    error_message = "When create_onprem_dns_resolver is true, onprem_dns_cidrs must contain at least one on-prem CIDR allowed to query the resolver."
  }
}

resource "aws_security_group" "resolver_inbound" {
  count = var.create_onprem_dns_resolver ? 1 : 0

  name        = "${var.network_name}-resolver-inbound-sg"
  description = "Allow on-prem DNS servers to query the Route 53 Resolver inbound endpoint"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "DNS (UDP) from on-prem"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = var.onprem_dns_cidrs
  }

  ingress {
    description = "DNS (TCP) from on-prem"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = var.onprem_dns_cidrs
  }

  egress {
    description = "Allow all outbound from resolver ENIs"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    local.base_tags,
    {
      Name = "${var.network_name}-resolver-inbound-sg"
    }
  )
}

resource "aws_route53_resolver_endpoint" "onprem_inbound" {
  count = var.create_onprem_dns_resolver ? 1 : 0

  name               = "${var.network_name}-onprem-inbound"
  direction          = "INBOUND"
  security_group_ids = [aws_security_group.resolver_inbound[0].id]

  dynamic "ip_address" {
    for_each = aws_subnet.private
    content {
      subnet_id = ip_address.value.id
    }
  }

  tags = merge(
    local.base_tags,
    {
      Name = "${var.network_name}-onprem-inbound"
    }
  )
}
