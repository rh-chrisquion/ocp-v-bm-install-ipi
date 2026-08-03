provider "aws" {
  region = var.aws_region
}

locals {
  az_count          = length(var.availability_zones)
  nat_gateway_count = var.enable_single_nat_gateway ? 1 : local.az_count

  base_tags = merge(
    {
      "managed-by" = "terraform"
      "platform"   = "example-rosa-hcp-hub"
      "stack"      = "network-foundation"
    },
    var.tags
  )

  onprem_route_table_ids = length(var.onprem_route_table_ids_override) > 0 ? var.onprem_route_table_ids_override : aws_route_table.private[*].id

  onprem_route_entries = {
    for route in flatten([
      for route_table_index, route_table_id in local.onprem_route_table_ids : [
        for cidr in var.onprem_route_cidrs : {
          key            = format("%02d-%s", route_table_index, replace(cidr, "/", "_"))
          route_table_id = route_table_id
          cidr           = cidr
        }
      ]
    ]) : route.key => route
  }

  onprem_route_target_type = (
    !var.create_onprem_private_routes ? "disabled" :
    var.onprem_transit_gateway_id != null ? "tgw" :
    var.onprem_vpn_gateway_id != null ? "vgw" :
    "invalid"
  )
}

check "onprem_route_requirements" {
  assert {
    condition     = !var.create_onprem_private_routes || length(var.onprem_route_cidrs) > 0
    error_message = "When create_onprem_private_routes is true, onprem_route_cidrs must contain at least one destination CIDR."
  }
}

check "onprem_route_target_exclusive" {
  assert {
    condition = !var.create_onprem_private_routes || (
      (var.onprem_transit_gateway_id != null ? 1 : 0) +
      (var.onprem_vpn_gateway_id != null ? 1 : 0)
    ) == 1
    error_message = "When create_onprem_private_routes is true, configure exactly one target: onprem_transit_gateway_id or onprem_vpn_gateway_id."
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(
    local.base_tags,
    {
      Name = "${var.network_name}-vpc"
    }
  )
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(
    local.base_tags,
    {
      Name = "${var.network_name}-igw"
    }
  )
}

resource "aws_subnet" "public" {
  count = local.az_count

  vpc_id                  = aws_vpc.this.id
  availability_zone       = var.availability_zones[count.index]
  cidr_block              = var.public_subnet_cidrs[count.index]
  map_public_ip_on_launch = false

  tags = merge(
    local.base_tags,
    {
      Name                     = format("%s-public-%02d", var.network_name, count.index + 1)
      "kubernetes.io/role/elb" = "1"
      Attributes               = "public"
    }
  )
}

resource "aws_subnet" "private" {
  count = local.az_count

  vpc_id                  = aws_vpc.this.id
  availability_zone       = var.availability_zones[count.index]
  cidr_block              = var.private_subnet_cidrs[count.index]
  map_public_ip_on_launch = false

  tags = merge(
    local.base_tags,
    {
      Name                              = format("%s-private-%02d", var.network_name, count.index + 1)
      "kubernetes.io/role/internal-elb" = "1"
      Attributes                        = "private"
    }
  )
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(
    local.base_tags,
    {
      Name = "${var.network_name}-public-rt"
    }
  )
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = local.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count = local.nat_gateway_count

  domain = "vpc"

  tags = merge(
    local.base_tags,
    {
      Name = format("%s-nat-eip-%02d", var.network_name, count.index + 1)
    }
  )
}

resource "aws_nat_gateway" "this" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  depends_on = [aws_internet_gateway.this]

  tags = merge(
    local.base_tags,
    {
      Name = format("%s-nat-%02d", var.network_name, count.index + 1)
    }
  )
}

resource "aws_route_table" "private" {
  count = local.az_count

  vpc_id = aws_vpc.this.id

  tags = merge(
    local.base_tags,
    {
      Name = format("%s-private-rt-%02d", var.network_name, count.index + 1)
    }
  )
}

resource "aws_route" "private_default" {
  count = local.az_count

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.enable_single_nat_gateway ? 0 : count.index].id
}

resource "aws_route_table_association" "private" {
  count = local.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_route" "onprem_private_tgw" {
  for_each = var.create_onprem_private_routes && var.onprem_transit_gateway_id != null ? local.onprem_route_entries : {}

  route_table_id         = each.value.route_table_id
  destination_cidr_block = each.value.cidr
  transit_gateway_id     = var.onprem_transit_gateway_id
}

resource "aws_route" "onprem_private_vgw" {
  for_each = var.create_onprem_private_routes && var.onprem_vpn_gateway_id != null ? local.onprem_route_entries : {}

  route_table_id         = each.value.route_table_id
  destination_cidr_block = each.value.cidr
  gateway_id             = var.onprem_vpn_gateway_id
}

resource "aws_security_group" "vpc_endpoints" {
  count = var.create_vpc_endpoints ? 1 : 0

  name        = "${var.network_name}-vpce-sg"
  description = "Security group for interface VPC endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "Allow endpoint HTTPS from VPC CIDR"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all outbound from endpoint ENIs"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    local.base_tags,
    {
      Name = "${var.network_name}-vpce-sg"
    }
  )
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.create_vpc_endpoints ? toset(var.interface_vpc_endpoint_services) : toset([])

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(
    local.base_tags,
    {
      Name = format("%s-vpce-%s", var.network_name, replace(each.value, ".", "-"))
    }
  )
}

resource "aws_vpc_endpoint" "s3_gateway" {
  count = var.create_vpc_endpoints && var.create_s3_gateway_endpoint ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(
    local.base_tags,
    {
      Name = "${var.network_name}-vpce-s3"
    }
  )
}
