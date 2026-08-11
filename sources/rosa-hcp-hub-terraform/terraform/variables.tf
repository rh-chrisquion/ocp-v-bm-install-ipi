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

variable "aws_assume_role_arn" {
  description = "Optional IAM role ARN to assume for all AWS API calls in this account (e.g. a cross-account role a client grants a consultant). Leave null to use ambient AWS credentials (CLI profile, SSO session, GitHub Actions credentials, etc.) directly with no assume-role hop."
  type        = string
  default     = null
  nullable    = true
}

variable "aws_assume_role_external_id" {
  description = "External ID required by aws_assume_role_arn's trust policy, if the role's trust policy requires one. Leave null if not required."
  type        = string
  default     = null
  nullable    = true
}

variable "aws_assume_role_session_name" {
  description = "Session name used when assuming aws_assume_role_arn (visible in the client's CloudTrail for auditing)."
  type        = string
  default     = "terraform-rosa-hcp-hub"
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
  description = "Fixed worker replica count for the default machine pool when autoscaling machine pools are not enabled. Must be a multiple of the private subnet count (HCP requirement). Ignored for sizing when enable_autoscaled_machine_pools is true (default pool is then sized to one worker per private subnet)."
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

# --- Bastion host (private cluster access) ---
# Only meaningful when private_cluster = true, where the API/console have no
# public endpoint. Provides an SSM Session Manager-only jump host inside the
# private subnets -- no SSH key, no open inbound security group rules. See
# "Connecting to a private cluster via the bastion host" in this source's
# README for the client-side connection steps.

variable "create_bastion" {
  description = "Create an SSM-only bastion EC2 instance in the private subnets for reaching a private cluster's API/console. No-op (but harmless) when private_cluster = false, since the API/console are already publicly reachable in that case."
  type        = bool
  default     = false
}

variable "bastion_instance_type" {
  description = "Instance type for the bastion host. A small instance is sufficient since it only proxies SSM sessions."
  type        = string
  default     = "t3.micro"
}

variable "bastion_ami_id" {
  description = "AMI ID for the bastion host. Leave null to auto-discover the latest Amazon Linux 2023 AMI (which ships the SSM agent preinstalled)."
  type        = string
  default     = null
  nullable    = true
}

# --- Day-1 OLM operators (GitOps + External Secrets) ---
# Applied automatically at the end of terraform apply via oc. Subscriptions
# start with installPlanApproval=Automatic so the first InstallPlan completes,
# then the install script patches them to Manual.

variable "install_day1_operators" {
  description = "After the cluster is ready, install OpenShift GitOps and External Secrets Operator from manifests/ as part of terraform apply, then set their Subscriptions to installPlanApproval=Manual. Requires create_htpasswd_admin=true and API reachability from the Terraform runner (public API, VPN/TGW, or bastion SSM port-forward)."
  type        = bool
  default     = true
}

variable "configure_eso_clustersecretstore" {
  description = "After ESO operator install, create the IRSA IAM role, apply ExternalSecretsConfig, annotate the external-secrets ServiceAccount, and create the aws-secrets-manager ClusterSecretStore. Requires install_day1_operators=true and create_oidc=true."
  type        = bool
  default     = true
}

variable "eso_run_e2e_test" {
  description = "When configure_eso_clustersecretstore is true, create a temporary Secrets Manager secret and validate an ExternalSecret sync during terraform apply. The test ExternalSecret/Secret are deleted on success; the AWS secret remains managed by Terraform until destroy."
  type        = bool
  default     = false
}

variable "eso_e2e_test_secret_name" {
  description = "AWS Secrets Manager secret name used by the optional ESO e2e test."
  type        = string
  default     = "e2e-test/external-secrets"
}

variable "eso_e2e_test_secret_value" {
  description = "Value stored in the optional ESO e2e Secrets Manager secret."
  type        = string
  default     = "e2e-test-value-success"
  sensitive   = true
}

variable "eso_e2e_test_namespace" {
  description = "Namespace where the optional ESO e2e ExternalSecret is created."
  type        = string
  default     = "default"
}
