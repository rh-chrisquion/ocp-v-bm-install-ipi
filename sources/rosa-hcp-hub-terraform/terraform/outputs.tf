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
