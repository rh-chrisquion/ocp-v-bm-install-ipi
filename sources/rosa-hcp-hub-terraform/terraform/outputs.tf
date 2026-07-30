output "cluster_id" {
  description = "ROSA HCP cluster identifier."
  value       = module.rosa_hcp_hub.cluster_id
}

output "cluster_state" {
  description = "Current ROSA HCP cluster state."
  value       = module.rosa_hcp_hub.cluster_state
}

output "cluster_api_url" {
  description = "ROSA HCP API endpoint."
  value       = module.rosa_hcp_hub.cluster_api_url
}

output "cluster_console_url" {
  description = "ROSA HCP web console URL."
  value       = module.rosa_hcp_hub.cluster_console_url
}

output "cluster_current_version" {
  description = "Current OpenShift version running in the cluster."
  value       = module.rosa_hcp_hub.cluster_current_version
}

output "discovered_vpc_id" {
  description = "VPC ID discovered from AWS via tag lookup (null when discovery is skipped)."
  value       = local.use_discovery ? data.aws_vpc.selected[0].id : null
}

output "effective_subnet_ids" {
  description = "Private subnet IDs actually used for worker placement, whether explicit or auto-discovered."
  value       = local.effective_subnet_ids
}

output "effective_availability_zones" {
  description = "Availability zones actually used for worker placement, whether explicit or auto-discovered."
  value       = local.effective_availability_zones
}

output "effective_machine_cidr" {
  description = "Machine CIDR actually used for cluster installation, whether explicit or auto-discovered."
  value       = local.effective_machine_cidr
}
