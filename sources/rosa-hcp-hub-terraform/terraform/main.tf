provider "aws" {
  region = var.aws_region
}

provider "rhcs" {
  token = var.rhcs_token
}

data "aws_caller_identity" "current" {}

locals {
  base_tags = merge(
    {
      "managed-by" = "terraform"
      "platform"   = "tt-rosa-hcp-hub"
      "role"       = "central-management-hub"
    },
    var.tags
  )

  autoscaled_machine_pools = {
    for index, subnet_id in var.aws_subnet_ids :
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

module "rosa_hcp_hub" {
  source  = "terraform-redhat/rosa-hcp/rhcs"
  version = var.rosa_hcp_module_version

  cluster_name           = var.cluster_name
  openshift_version      = var.openshift_version
  aws_subnet_ids         = var.aws_subnet_ids
  aws_availability_zones = var.aws_availability_zones
  machine_cidr           = var.machine_cidr
  private                = var.private_cluster

  create_account_roles  = var.create_account_roles
  create_oidc           = var.create_oidc
  create_operator_roles = var.create_operator_roles
  account_role_prefix   = var.account_role_prefix
  operator_role_prefix  = var.operator_role_prefix

  compute_machine_type = var.compute_machine_type
  replicas             = var.enable_autoscaled_machine_pools ? null : var.replicas
  worker_disk_size     = var.worker_disk_size

  machine_pools = local.effective_machine_pools

  cluster_autoscaler_enabled = false

  properties = {
    rosa_creator_arn = data.aws_caller_identity.current.arn
  }

  wait_for_create_complete            = true
  wait_for_std_compute_nodes_complete = true
  tags                                = local.base_tags
}
