locals {
  # cluster_name is intentionally NOT duplicated here -- var.cluster_name
  # (variables.tf) is the single source of truth for the cluster's name.
  common_tags = {
    name                           = var.cluster_name
    "created-by:tool"              = "syseng:terraform"
    "class:component:sub-project"  = "core:infrastructure:openshift"
    "backup"                       = "no"
    "map-migrated"                 = "mig2EWA1MBCZO"
    "cost-center:team:env:sub-env" = "infrastructure:syseng:${var.env}:common-services"
  }
}