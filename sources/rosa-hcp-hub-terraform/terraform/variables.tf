variable "rhcs_token" {
  description = "OCM API token used by the RHCS provider."
  type        = string
  sensitive   = true
}

variable "cluster_name" {
  description = "ROSA HCP cluster name."
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
