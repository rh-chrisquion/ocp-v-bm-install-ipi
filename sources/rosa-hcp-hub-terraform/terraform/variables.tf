variable "rhcs_token" {
  description = "OCM API token used by the RHCS provider."
  type        = string
  sensitive   = true
}

variable "cluster_name" {
  description = "ROSA HCP cluster name."
  type        = string
}

variable "env" {
  description = "Environment slug used in required organizational tagging (e.g. sandbox, dev, staging, prod)."
  type        = string
}

variable "openshift_version" {
  description = "OpenShift version to deploy."
  type        = string
  default     = "4.22.0"
}

variable "aws_region" {
  description = "AWS region for ROSA cluster resources."
  type        = string
}

variable "aws_subnet_ids" {
  description = "Private subnet IDs for worker placement. When empty and enable_vpc_discovery is true, these are auto-discovered from AWS."
  type        = list(string)
  default     = []
}

variable "aws_availability_zones" {
  description = "Availability zones that map to aws_subnet_ids. When empty and enable_vpc_discovery is true, these are auto-discovered from AWS."
  type        = list(string)
  default     = []
}

variable "machine_cidr" {
  description = "Machine network CIDR used during cluster installation. When null and enable_vpc_discovery is true, this is auto-discovered from AWS."
  type        = string
  default     = null
  nullable    = true
}

variable "enable_vpc_discovery" {
  description = "When true, auto-discover the VPC, private subnet IDs, availability zones, and machine CIDR from AWS via tags instead of requiring aws_subnet_ids/aws_availability_zones/machine_cidr to be set explicitly. Explicit values always take precedence over discovered ones."
  type        = bool
  default     = true
}

variable "network_name" {
  description = "Name prefix used to locate the VPC by its Name tag (\"$${network_name}-vpc\") during auto-discovery. Must match the network_name used in the sibling rosa-hcp-network-terraform stack."
  type        = string
  default     = "rosa-hcp-hub-network"
}

variable "private_subnet_selector_tags" {
  description = "Tags used to select private worker subnets within the discovered VPC during auto-discovery."
  type        = map(string)
  default = {
    Attributes = "private"
  }
}

variable "public_subnet_selector_tags" {
  description = "Tags used to select a public subnet within the discovered VPC during auto-discovery, when private_cluster is false. ROSA HCP requires at least one public subnet in aws_subnet_ids to place the public API/router load balancers."
  type        = map(string)
  default = {
    Attributes = "public"
  }
}

variable "private_cluster" {
  description = "Whether to deploy ROSA HCP as private."
  type        = bool
  default     = true
}

variable "create_account_roles" {
  description = "Create required ROSA account roles."
  type        = bool
  default     = true
}

variable "create_oidc" {
  description = "Create managed OIDC configuration for the cluster."
  type        = bool
  default     = true
}

variable "create_operator_roles" {
  description = "Create ROSA operator roles."
  type        = bool
  default     = true
}

variable "account_role_prefix" {
  description = "Prefix for AWS account roles generated for ROSA."
  type        = string
}

variable "operator_role_prefix" {
  description = "Prefix for AWS operator roles generated for ROSA."
  type        = string
}

variable "compute_machine_type" {
  description = "Default worker machine type (upsized for ACM+AAP+ArgoCD hub workloads)."
  type        = string
  default     = "m5.2xlarge"
}

variable "replicas" {
  description = "Fixed worker replica count when autoscaling machine pools are not enabled."
  type        = number
  default     = 6
}

variable "enable_autoscaled_machine_pools" {
  description = "Create per-subnet machine pools with autoscaling controls."
  type        = bool
  default     = true
}

variable "min_replicas_per_pool" {
  description = "Minimum replicas per machine pool when autoscaling is enabled (recommend >=2 for ACM+AAP+Argo CD hub HA)."
  type        = number
  default     = 2
}

variable "max_replicas_per_pool" {
  description = "Maximum replicas per machine pool when autoscaling is enabled."
  type        = number
  default     = 6
}

variable "tags" {
  description = "AWS tags applied to ROSA resources."
  type        = map(string)
  default     = {}
}

variable "extra_machine_pools" {
  description = "Additional machine pools to create through the module (advanced usage)."
  type        = map(any)
  default     = {}
}

# --- Identity providers ---
# Two independent, toggleable IDPs. Both are Terraform-managed via the rhcs
# provider (an OCM-level API, not a Kubernetes API call), so they work even
# before any working kubeconfig/admin credentials exist on the cluster.

variable "create_htpasswd_admin" {
  description = "Create a Terraform-managed htpasswd identity provider with a single generated cluster-admin user. Intended for sandbox/dev use only -- not a substitute for real SSO in shared/production environments."
  type        = bool
  default     = true
}

variable "htpasswd_admin_username" {
  description = "Username for the Terraform-managed htpasswd cluster-admin user (only used when create_htpasswd_admin is true)."
  type        = string
  default     = "sandbox-admin"
}

variable "enable_oidc_idp" {
  description = "Create an OpenID Connect identity provider, e.g. to front the cluster with your organization's SSO (and whatever MFA, such as Duo, that SSO already enforces upstream). Terraform only registers the cluster as an OIDC relying party -- it cannot create the client registration on the IdP side; obtain oidc_client_id/oidc_client_secret/oidc_issuer_url from whoever administers that IdP first."
  type        = bool
  default     = false
}

variable "oidc_idp_name" {
  description = "Display name for the OIDC identity provider shown on the OpenShift login page."
  type        = string
  default     = "corporate-sso"
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL (https, no query params/fragment) from your organization's IdP. Required when enable_oidc_idp is true."
  type        = string
  default     = null
}

variable "oidc_client_id" {
  description = "OIDC client ID registered against your organization's IdP for this cluster. Required when enable_oidc_idp is true."
  type        = string
  default     = null
}

variable "oidc_client_secret" {
  description = "OIDC client secret registered against your organization's IdP for this cluster. Required when enable_oidc_idp is true."
  type        = string
  default     = null
  sensitive   = true
}

variable "oidc_mapping_method" {
  description = "How OpenShift maps OIDC identities to cluster users: add, claim, generate, or lookup."
  type        = string
  default     = "claim"
}

variable "oidc_email_claims" {
  description = "OIDC claims to use as the user's email address."
  type        = list(string)
  default     = ["email"]
}

variable "oidc_name_claims" {
  description = "OIDC claims to use as the user's display name."
  type        = list(string)
  default     = ["name"]
}

variable "oidc_username_claims" {
  description = "OIDC claims to use as the user's preferred username."
  type        = list(string)
  default     = ["preferred_username"]
}

variable "oidc_groups_claims" {
  description = "OIDC claims to use as the user's group memberships, if your IdP asserts them."
  type        = list(string)
  default     = []
}

variable "oidc_extra_scopes" {
  description = "Additional OAuth scopes to request from the OIDC provider beyond 'openid'."
  type        = list(string)
  default     = ["email", "profile"]
}

variable "oidc_admin_username" {
  description = "If set, grants this username (as it will appear once mapped from the OIDC identity) membership in the cluster-admins group. Leave null to grant no automatic admin rights via OIDC and assign access manually afterward."
  type        = string
  default     = null
}
