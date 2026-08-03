variable "aws_region" {
  description = "AWS region where the ROSA HCP network stack is provisioned."
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
  default     = "terraform-rosa-hcp-network"
}

variable "network_name" {
  description = "Name prefix used for VPC networking resources."
  type        = string
  default     = "rosa-hcp-hub-network"
}

variable "vpc_cidr" {
  description = "VPC CIDR block used as the machine supernet for ROSA HCP."
  type        = string
  default     = "10.200.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones used for the network and ROSA worker placement."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs (one per AZ) for ROSA worker nodes."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_cidrs) == length(var.availability_zones)
    error_message = "private_subnet_cidrs must have the same number of entries as availability_zones."
  }
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs (one per AZ) that host NAT gateways."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_cidrs) == length(var.availability_zones)
    error_message = "public_subnet_cidrs must have the same number of entries as availability_zones."
  }
}

variable "enable_single_nat_gateway" {
  description = "When true, creates one NAT gateway in the first AZ. When false, creates one NAT gateway per AZ."
  type        = bool
  default     = false
}

variable "create_vpc_endpoints" {
  description = "When true, provisions private VPC endpoints for selected AWS services."
  type        = bool
  default     = true
}

variable "interface_vpc_endpoint_services" {
  description = "Interface endpoint services (service suffixes) to create, such as sts or ecr.api."
  type        = list(string)
  default = [
    "sts",
    "ecr.api",
    "ecr.dkr",
    "ec2",
    "elasticloadbalancing",
    "logs",
    "monitoring"
  ]
}

variable "create_s3_gateway_endpoint" {
  description = "When true, creates an S3 gateway endpoint and associates it to private route tables."
  type        = bool
  default     = true
}

variable "create_onprem_private_routes" {
  description = "When true, creates explicit private route entries for on-prem CIDRs in private route tables."
  type        = bool
  default     = false
}

variable "onprem_route_cidrs" {
  description = "On-prem destination CIDRs routed from private subnets to TGW or VGW."
  type        = list(string)
  default     = []
}

variable "onprem_transit_gateway_id" {
  description = "Transit Gateway ID used for on-prem private routing (for example tgw-xxxxxxxx)."
  type        = string
  default     = null
  nullable    = true
}

variable "onprem_vpn_gateway_id" {
  description = "Virtual Private Gateway ID used for on-prem private routing (for example vgw-xxxxxxxx)."
  type        = string
  default     = null
  nullable    = true
}

variable "onprem_route_table_ids_override" {
  description = "Optional explicit private route table IDs to target for on-prem routes. Defaults to route tables created by this stack."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Additional tags applied to all supported resources."
  type        = map(string)
  default     = {}
}

# --- Optional hybrid DNS for on-prem cluster access ---
# A private ROSA HCP cluster's API/console records live in a Route 53
# private hosted zone associated only with this VPC, so on-prem hosts can't
# resolve them by default even once create_onprem_private_routes gives them
# an IP path in. A Resolver inbound endpoint exposes this VPC's resolver
# (which knows about that private hosted zone) to on-prem DNS servers via
# conditional forwarding. See "Optional on-prem DNS resolution" in README.md.

variable "create_onprem_dns_resolver" {
  description = "When true, creates a Route 53 Resolver inbound endpoint so on-prem DNS servers can conditionally forward queries for the cluster's private hosted zone into this VPC."
  type        = bool
  default     = false
}

variable "onprem_dns_cidrs" {
  description = "On-prem CIDRs allowed to send DNS queries (TCP/UDP 53) to the resolver inbound endpoint. Required (non-empty) when create_onprem_dns_resolver is true."
  type        = list(string)
  default     = []
}
