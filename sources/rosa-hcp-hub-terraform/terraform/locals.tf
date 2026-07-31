locals {
  cluster_name = "tt-openshift-rosa-${var.env}"

  common_tags = {
    name                           = local.cluster_name
    "created-by:tool"              = "syseng:terraform"
    "class:component:sub-project"  = "core:infrastructure:openshift"
    "backup"                       = "no"
    "map-migrated"                 = "mig2EWA1MBCZO"
    "cost-center:team:env:sub-env" = "infrastructure:syseng:${var.env}:common-services"
  }

  tags = merge(local.common_tags, var.tags)
}