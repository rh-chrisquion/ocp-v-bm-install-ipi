# ROSA HCP Hybrid Network Consolidated Notes

This document consolidates the working notes into one consistent design reference for a ROSA HCP hub managing on-prem OpenShift clusters.

## 1) Architecture Baseline

- ROSA HCP control plane runs in a Red Hat-managed AWS account.
- Worker/data-plane nodes run in TT AWS account VPC subnets.
- Preferred management posture is spoke-initiated, agent-based:
  - ACM Klusterlet: spoke -> hub `443`
  - Argo CD Agent: spoke -> hub `443`
  - AAP mesh/execution: spoke/on-prem execution with hub orchestration
- Direct hub -> spoke API access is optional and only enabled for explicit use cases.

## 2) Reference AWS CIDR Plan (Example)

- VPC CIDR: `10.200.0.0/16`
- Private worker subnets (one per AZ):
  - `eu-west-1a`: `10.200.0.0/20`
  - `eu-west-1b`: `10.200.16.0/20`
  - `eu-west-1c`: `10.200.32.0/20`
- Public/NAT subnets:
  - `10.200.240.0/24`
  - `10.200.241.0/24`
  - `10.200.242.0/24`
- ROSA machine supernet:
  - `machine_cidr: 10.200.0.0/18` (covers all three private worker subnets)

## 3) Cluster Network Defaults

Keep defaults unless IPAM conflicts require changes:

- Pod network: `10.128.0.0/14`
- Service network: `172.30.0.0/16`
- Host prefix: `23`

## 4) Worker Sizing and Autoscaling

- Day-0 baseline: 6 workers total (2 per AZ).
- Starting shape: `m6i.2xlarge` (or `m5.2xlarge` if standardized).
- Use one worker pool per AZ.
- If per-AZ pools use `min=2`, `max=4`, total range is `6-12`.
- For management hub reliability, do not use scale-to-zero.
- Typical scale-up trigger toward 9 workers (3/AZ):
  - frequent worker CPU > 70%
  - sustained memory pressure
  - AAP job backlogs impacting reconciliation latency

## 5) Egress and Endpoint Strategy

- Keep one NAT gateway per AZ and route each private subnet to same-AZ NAT.
- Use VPC endpoints to reduce NAT dependency and keep selected AWS service traffic private.
- ROSA HCP customer-VPC baseline endpoint profile:
  - Interface: `sts`, `ecr.api`, `ecr.dkr`
  - Gateway: `s3`
- Conditional endpoints by validated requirement:
  - `ec2`, `logs`, `monitoring`, `kms`, `secretsmanager`
- Do not include `autoscaling` and `elasticloadbalancing` in default HCP customer-VPC endpoint profile unless a specific in-VPC consumer is proven.
- For hardened mode, enforce outbound policy through firewall/proxy inspection and allowlisting (FQDN/SNI/IP policy), not NAT alone.

## 6) On-Prem <-> Hub Connectivity Requirements

- Baseline (agent model): reliable spoke outbound `443` to hub endpoints.
- Optional direct hub -> spoke API path: `6443` only when required by approved workflows.
- AAP local execution nodes must reach local site endpoints (for example VMware, BMC, local API endpoints) per site policy.
- DNS must resolve hub and spoke FQDNs according to selected connectivity model.
- Routing and firewall policy must be symmetric for return traffic.

## 7) CIDR Guardrails

- No overlap between AWS VPC/subnets and on-prem machine/provisioning/BMC/storage networks.
- For future overlay/east-west connectivity (for example Submariner), Pod and Service CIDRs must be globally non-overlapping across all participating clusters.

## 8) MTU Guidance for Hybrid Paths

- MTU must be designed using the lowest end-to-end underlay MTU in the active path.
- For OVN-Kubernetes, target overlay MTU is underlay MTU minus 100.
- Build an end-to-end MTU matrix for AWS + DX/VPN/TGW + on-prem hops before finalizing overlay requirements.
- If jumbo frames are used, validate every hop supports the selected MTU class (do not assume end-to-end jumbo by default).

## 9) Terraform Stack Pattern

- Keep separate stacks:
  - Network foundation: VPC, subnets, NAT, routes, optional endpoints
  - ROSA cluster: consumes network outputs and provisions cluster resources
- Recommended data flow:
  - network outputs (`private_subnet_ids`, `availability_zones`, `machine_cidr`) -> cluster inputs (`aws_subnet_ids`, `aws_availability_zones`, `machine_cidr`)

## 10) TT Decisions Required

- Confirm VPC mode: existing VPC vs new dedicated VPC.
- Confirm exact regional CIDR allocation for this hub footprint.
- Confirm baseline and max worker scale target for hub workloads.
- Approve connectivity standard: `TGW+VPN`, `DX+TGW`, or hardened internet path.
- Confirm whether any direct hub -> spoke API workflows are required.
- Approve endpoint profile (baseline + conditional) and egress allowlist governance.
- Confirm whether multi-cluster overlay networking is in scope.
