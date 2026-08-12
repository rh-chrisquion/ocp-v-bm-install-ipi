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
  value       = local.effective_private_subnet_ids
}

output "effective_cluster_subnet_ids" {
  description = "Full subnet ID list passed to the cluster resource, including a discovered public subnet when private_cluster is false."
  value       = local.effective_cluster_subnet_ids
}

output "effective_availability_zones" {
  description = "Availability zones actually used for worker placement, whether explicit or auto-discovered."
  value       = local.effective_availability_zones
}

output "effective_machine_cidr" {
  description = "Machine CIDR actually used for cluster installation, whether explicit or auto-discovered."
  value       = local.effective_machine_cidr
}

output "htpasswd_admin_username" {
  description = "Username for the Terraform-managed sandbox htpasswd cluster-admin, when create_htpasswd_admin is true."
  value       = var.create_htpasswd_admin ? var.htpasswd_admin_username : null
}

output "htpasswd_admin_password" {
  description = "Generated password for the Terraform-managed sandbox htpasswd cluster-admin, when create_htpasswd_admin is true. Retrieve with: terraform output -raw htpasswd_admin_password"
  value       = var.create_htpasswd_admin ? random_password.htpasswd_admin[0].result : null
  sensitive   = true
}

output "oidc_idp_enabled" {
  description = "Whether the OIDC identity provider (for org SSO / Duo-fronted login) is currently configured."
  value       = var.enable_oidc_idp
}

output "bastion_instance_id" {
  description = "EC2 instance ID of the SSM bastion host, when create_bastion is true. Use with: aws ssm start-session --target <this-value> ..."
  value       = try(aws_instance.bastion[0].id, null)
}

output "day1_operators_installed" {
  description = "Whether this apply configured day-1 OLM operator installation (OpenShift GitOps + External Secrets). When true, Subscriptions are left at installPlanApproval=Manual after the initial CSV succeeds."
  value       = var.install_day1_operators && var.create_htpasswd_admin
}

output "eso_iam_role_arn" {
  description = "ARN of the IAM role used by External Secrets Operator for AWS Secrets Manager (IRSA), when configure_eso_clustersecretstore is enabled."
  value       = try(aws_iam_role.external_secrets[0].arn, null)
}

output "eso_cluster_secret_store_name" {
  description = "Name of the ClusterSecretStore created for AWS Secrets Manager, when configure_eso_clustersecretstore is enabled."
  value       = var.configure_eso_clustersecretstore && var.install_day1_operators && var.create_htpasswd_admin ? local.eso_cluster_secret_store : null
}

output "eso_oidc_provider_url" {
  description = "OIDC provider URL (no https://) used in the ESO IRSA trust policy."
  value       = local.oidc_provider_url
}

output "eso_e2e_test_secret_arn" {
  description = "ARN of the optional ESO e2e Secrets Manager secret, when eso_run_e2e_test is true."
  value       = try(aws_secretsmanager_secret.eso_e2e_test[0].arn, null)
}
