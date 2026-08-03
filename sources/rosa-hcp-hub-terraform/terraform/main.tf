provider "aws" {
  region = var.aws_region
}

provider "rhcs" {
  token = var.rhcs_token
}

data "aws_caller_identity" "current" {}

locals {
  # Required organizational tags (locals.tf) merged with hub-specific tags,
  # with var.tags able to override either if a caller needs to. This is the
  # single tag set applied to the module and machine pools below.
  base_tags = merge(
    local.common_tags,
    {
      "managed-by" = "terraform"
      "platform"   = "example-rosa-hcp-hub"
      "role"       = "central-management-hub"
    },
    var.tags
  )

  # Only query AWS for discovery data when at least one of the three
  # network inputs hasn't already been supplied explicitly.
  use_discovery = var.enable_vpc_discovery && (
    length(var.aws_subnet_ids) == 0 ||
    length(var.aws_availability_zones) == 0 ||
    var.machine_cidr == null
  )

  discovered_private_subnet_ids = local.use_discovery ? sort(data.aws_subnets.private[0].ids) : []

  discovered_subnet_details = {
    for id, subnet in data.aws_subnet.private_details : id => subnet
  }

  discovered_availability_zones = [
    for id in local.discovered_private_subnet_ids : local.discovered_subnet_details[id].availability_zone
  ]

  discovered_machine_cidr = local.use_discovery ? data.aws_vpc.selected[0].cidr_block : null

  # Worker/private subnet ids and AZs drive machine pool placement and
  # replica counts; an explicit aws_subnet_ids override always wins.
  effective_private_subnet_ids = length(var.aws_subnet_ids) > 0 ? var.aws_subnet_ids : local.discovered_private_subnet_ids
  effective_availability_zones = length(var.aws_availability_zones) > 0 ? var.aws_availability_zones : local.discovered_availability_zones
  effective_machine_cidr       = coalesce(var.machine_cidr, local.discovered_machine_cidr)

  # A public cluster requires at least one public subnet in aws_subnet_ids
  # (for the public API/router load balancers) in addition to the private
  # worker subnets. Only relevant when discovery resolved the subnets
  # ourselves -- a manual aws_subnet_ids override must include its own
  # public subnet if needed.
  needs_discovered_public_subnet = local.use_discovery && !var.private_cluster && length(var.aws_subnet_ids) == 0
  discovered_public_subnet_id    = local.needs_discovered_public_subnet ? sort(data.aws_subnets.public[0].ids)[0] : null

  # aws_subnet_ids passed to the cluster resource: private worker subnets
  # plus, for public clusters, one discovered public subnet.
  effective_cluster_subnet_ids = local.discovered_public_subnet_id != null ? concat(local.effective_private_subnet_ids, [local.discovered_public_subnet_id]) : local.effective_private_subnet_ids

  autoscaled_machine_pools = {
    for index, subnet_id in local.effective_private_subnet_ids :
    format("hub-workers-%02d", index + 1) => {
      name              = format("hub-workers-%02d", index + 1)
      subnet_id         = subnet_id
      openshift_version = var.openshift_version
      aws_node_pool = {
        instance_type = var.compute_machine_type
        tags          = local.base_tags
      }
      autoscaling = {
        enabled      = true
        min_replicas = var.min_replicas_per_pool
        max_replicas = var.max_replicas_per_pool
      }
      auto_repair = true
    }
  }

  effective_machine_pools = merge(
    var.enable_autoscaled_machine_pools ? local.autoscaled_machine_pools : {},
    var.extra_machine_pools
  )
}

check "vpc_discovery_requirements" {
  assert {
    condition     = length(local.effective_private_subnet_ids) > 0
    error_message = "No subnet IDs resolved. Either set aws_subnet_ids explicitly, or ensure a VPC tagged Name=\"${var.network_name}-vpc\" with subnets matching private_subnet_selector_tags exists in aws_region, or set enable_vpc_discovery=false together with manual overrides."
  }
}

check "vpc_discovery_az_alignment" {
  assert {
    condition     = length(local.effective_private_subnet_ids) == length(local.effective_availability_zones)
    error_message = "Resolved private subnet IDs and availability zones must have matching counts."
  }
}

check "public_cluster_subnet_requirement" {
  assert {
    condition     = var.private_cluster || length(var.aws_subnet_ids) > 0 || local.discovered_public_subnet_id != null
    error_message = "private_cluster is false but no public subnet could be resolved. Ensure a VPC tagged Name=\"${var.network_name}-vpc\" has a subnet matching public_subnet_selector_tags, or set aws_subnet_ids explicitly to include a public subnet."
  }
}

data "aws_vpc" "selected" {
  count = local.use_discovery ? 1 : 0

  tags = {
    Name = "${var.network_name}-vpc"
  }
}

data "aws_subnets" "private" {
  count = local.use_discovery ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected[0].id]
  }

  tags = var.private_subnet_selector_tags
}

data "aws_subnet" "private_details" {
  for_each = local.use_discovery ? toset(data.aws_subnets.private[0].ids) : toset([])

  id = each.value
}

data "aws_subnets" "public" {
  count = local.needs_discovered_public_subnet ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected[0].id]
  }

  tags = var.public_subnet_selector_tags
}

module "rosa_hcp_hub" {
  source  = "terraform-redhat/rosa-hcp/rhcs"
  version = "1.7.3"

  cluster_name           = var.cluster_name
  openshift_version      = var.openshift_version
  aws_subnet_ids         = local.effective_cluster_subnet_ids
  aws_availability_zones = local.effective_availability_zones
  machine_cidr           = local.effective_machine_cidr
  private                = var.private_cluster

  create_account_roles  = var.create_account_roles
  create_oidc           = var.create_oidc
  create_operator_roles = var.create_operator_roles
  account_role_prefix   = var.account_role_prefix
  operator_role_prefix  = var.operator_role_prefix

  compute_machine_type = var.compute_machine_type
  replicas             = var.enable_autoscaled_machine_pools ? null : var.replicas

  machine_pools = local.effective_machine_pools

  cluster_autoscaler_enabled = false

  properties = {
    rosa_creator_arn = data.aws_caller_identity.current.arn
  }

  wait_for_create_complete            = true
  wait_for_std_compute_nodes_complete = true
  tags                                = local.base_tags
}
