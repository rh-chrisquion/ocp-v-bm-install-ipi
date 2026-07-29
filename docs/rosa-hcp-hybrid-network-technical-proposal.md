# ROSA HCP Hybrid Network Technical Proposal

The ROSA HCP hub will be:

- in `eu-west-1` 
- using a 3-AZ design with 2 workers per AZ, 
- deployed into an AWS common-services regional `/21` allocation (exact block pending confirmation) and carved into per-AZ private worker and public NAT subnets.

Management traffic is standardized on a spoke-initiated model for ACM, Argo CD Agent, and AAP mesh workflows, minimizing inbound exposure to on-prem environments. 

One NAT gateway per AZ as resilient egress transport, selected VPC endpoints for AWS service traffic, and an explicit egress inspection layer (firewall/proxy allowlisting) for non-endpoint traffic; optional TGW/VGW route targets are enabled only for approved direct-access exceptions.

If multi-cluster overlay networking (for example Submariner) is required, Pod and Service CIDRs must be globally non-overlapping across ROSA and all participating on-prem/SNO clusters.

## Context

Design target:

- ROSA HCP hub in `eu-west-1`
- Hub workloads: ACM, OpenShift GitOps (Argo CD Agent model), and AAP (Automation Mesh/agent-forward pattern)
- Managed spokes:
  - On-prem bare-metal OCP-V clusters (5 schedulable nodes)
  - Remote SNO clusters
- Enterprise allocation guidance:
  - AWS common services supernet: `10.81.0.0/16`
  - One regional `/21` reserved for `eu-west-1` for this deployment pattern (exact `/21` pending confirmation)

Management traffic assumption for this revision:

- **Spoke-initiated model is the baseline** (outbound from on-prem to AWS hub endpoints).
- **Direct hub-to-spoke API routing is optional** and only needed for explicit non-agent use cases.



## Technical Network Decision Spec Sheet



### NET-01 — Region

- Domain: Region
- Inter-ref dependencies: Foundational for `NET-02`, `NET-03`, `NET-05`, `NET-07`, and `NET-08`.
- Proposal: Deploy ROSA hub in `eu-west-1` with 3 AZ worker distribution as the default production posture for availability and maintenance tolerance.
- Example: `eu-west-1a`, `eu-west-1b`, `eu-west-1c`
- Current state: Proposed
- TT Input Required: Confirm region is final and approved.
- Impact if unresolved: Rework to CIDR, subnets, and deployment parameter sets if region changes later.



### NET-02 — VPC Existence

- Domain: VPC Existence
- Inter-ref dependencies: Depends on `NET-01`; determines execution path for `NET-03`, `NET-05`, `NET-07`, and `NET-08`.
- Proposal: If a common-services VPC already exists, deploy into approved existing subnets; otherwise create a dedicated VPC from the regional `/21`.
- Example: Existing VPC path -> consume approved subnets and route domains; new VPC path -> create VPC `10.81.16.0/21`.
- Current state: **Unclear**
- TT Input Required: Confirm whether target VPC already exists; if yes, provide VPC ID and subnet IDs.
- Impact if unresolved: Cannot finalize the network integration approach (existing-network consume vs dedicated-network create) or execute deployment safely.



### NET-03 — IP Allocation

- Domain: IP Allocation
- Inter-ref dependencies: Depends on `NET-01` and `NET-02`; defines address boundaries for `NET-04` and `NET-05`.
- Proposal: Use `10.81.0.0/16` as the enterprise IPAM pool only. Use the approved `eu-west-1` `/21` as `machine_cidr` once confirmed, then carve per-AZ worker/public subnets from that `/21`.
- Example: **IPAM pool CIDR** `10.81.0.0/16` -> allocate **VPC CIDR block** `10.81.16.0/21` to this `eu-west-1` hub footprint (and set ROSA `machine_cidr` to this `/21`) -> carve **private worker subnet CIDRs** `10.81.16.0/24` (`eu-west-1a`), `10.81.17.0/24` (`eu-west-1b`), `10.81.18.0/24` (`eu-west-1c`) -> carve **public NAT subnet CIDRs** `10.81.23.0/26`, `10.81.23.64/26`, `10.81.23.128/26` -> set each private subnet route `0.0.0.0/0` to its local-AZ NAT gateway.
- Current state: Partially confirmed (pattern confirmed, exact `/21` pending validation)
- TT Input Required: Confirm the exact `/21` reserved for this hub footprint. If a new VPC is created, this `/21` is the VPC CIDR; if an existing VPC is used, confirm the existing VPC/subnet CIDRs and AZ mapping.
- Impact if unresolved: Incorrect subnet carve or overlap risk; cluster creation blockage.



### NET-04 — Machine CIDR

- Domain: Machine CIDR
- Inter-ref dependencies: Depends on `NET-03` allocation and `NET-05` subnet carving.
- Proposal: Set `machine_cidr` to the smallest supernet that fully covers all ROSA worker subnets from the regional allocation (typically the same `/21` in this model).
- Example: `machine_cidr = "10.81.16.0/21"`
- Current state: Proposed
- TT Input Required: Confirm final `machine_cidr` value after subnet plan approval.
- Impact if unresolved: Machine/subnet mismatch can fail ROSA provisioning or future scaling.



### NET-05 — Subnet Layout

- Domain: Subnet Layout
- Inter-ref dependencies: Depends on `NET-02` and `NET-03`; provides capacity and topology inputs for `NET-06` and `NET-07`.
- Proposal: Carve one private worker subnet and one public egress/NAT subnet per AZ (3+3 model), reserving spare address space in-region for later pool expansion.
- Example: Private: `10.81.16.0/24`, `10.81.17.0/24`, `10.81.18.0/24`; Public: `10.81.23.0/26`, `10.81.23.64/26`, `10.81.23.128/26`
- Current state: Proposed
- TT Input Required: Confirm exact CIDR split per AZ and reserved growth ranges.
- Impact if unresolved: Limited growth or subnet exhaustion if carved incorrectly.



### NET-06 — Worker Baseline

- Domain: Worker Baseline
- Inter-ref dependencies: Depends on `NET-05`; drives capacity, route, and cost assumptions in `NET-07` and `NET-08`.
- Proposal: Start at 2 workers per AZ (6 total Day-0) using one worker machine pool per AZ. Configure autoscaling per machine pool with `min=2` and `max=6`; in a 3-AZ design this yields a cluster-wide worker range of 6 to 18.
- Example: Three AZ-scoped pools (`eu-west-1a`, `eu-west-1b`, `eu-west-1c`) each set to `min_replicas_per_pool=2`, `max_replicas_per_pool=6` -> total min `6`, total max `18`.
- Current state: Proposed baseline
- TT Input Required: Confirm baseline and peak growth expectations for ACM/AAP/Argo workload bursts.
- Impact if unresolved: Under-sizing risk for hub management operations and automation throughput.



### NET-07 — Egress

- Domain: Egress
- Inter-ref dependencies: Depends on `NET-05` subnet topology and is policy-coupled with `NET-08` and `NET-15`.
- Proposal: Use one NAT gateway per AZ and route each private subnet to its local-AZ NAT to avoid single-AZ egress dependency and reduce cross-AZ failure coupling. Destination policy is enforced by VPC endpoints plus firewall/proxy controls.
- Example: `nat-eu-west-1a`, `nat-eu-west-1b`, `nat-eu-west-1c`; private subnet `0.0.0.0/0` -> same-AZ NAT; non-VPC-endpoint egress -> inspection layer -> approved destinations only.
- Current state: Proposed
- TT Input Required: Confirm cost acceptance for 3 NAT gateways, plus the selected egress inspection pattern (AWS Network Firewall and/or explicit proxy).
- Impact if unresolved: Either over-permissive outbound access (security risk) or unpredictable dependency failures from ad hoc blocking.



### NET-08 — AWS Service Access

- Domain: AWS Service Access
- Inter-ref dependencies: Depends on `NET-07` egress architecture and `NET-15` security policy model.
- Proposal: Enable VPC endpoints (interface endpoints + S3 gateway endpoint) so AWS service traffic stays on private AWS paths and NAT is reserved for non-endpoint destinations. For ROSA HCP customer-VPC baseline, use `sts`, `ecr.api`, `ecr.dkr`, `s3`. Do not include `autoscaling` and `elasticloadbalancing` in the default customer-VPC endpoint profile for HCP control-plane operations; include additional endpoints only for validated data-plane or workload requirements (for example `ec2` for EBS CSI and cloud-network operators, plus `logs`, `monitoring`, `kms`, `secretsmanager` as policy-driven).
- Example: Baseline: Interface `sts`, `ecr.api`, `ecr.dkr`; Gateway `s3`. Conditional: Interface `ec2`, `logs`, `monitoring`, `kms`, `secretsmanager`. Excluded from default HCP customer-VPC profile: `autoscaling`, `elasticloadbalancing`.
- Current state: Proposed
- TT Input Required: Confirm control-framework endpoint profile (`required` vs `conditional`) and endpoint-policy restrictions.
- Impact if unresolved: Increased NAT reliance/cost, broader egress exposure, and inconsistent behavior across environments.



### NET-09 — Management Directionality

- Domain: Management Directionality
- Inter-ref dependencies: Foundational for `NET-10`, `NET-12`, `NET-13`, and `NET-14`.
- Proposal: Standardize on spoke-initiated flows (spoke -> hub outbound) for ACM Klusterlet, Argo CD Agent, and AAP mesh controls to minimize inbound openings toward on-prem.
- Example: Spoke -> hub on `443`; no default hub -> spoke `6443` dependency
- Current state: **Open**
- TT Input Required: Confirm that direct hub-to-spoke API operations are not required for baseline operations.
- Impact if unresolved: Overbuilding private routing (cost/complexity) or missing required direct paths for non-agent workflows.



### NET-10 — AAP Execution Topology

- Domain: AAP Execution Topology
- Inter-ref dependencies: Depends on `NET-09`; informs `NET-11`, `NET-12`, and `NET-15`.
- Proposal: Run AAP control/orchestration centrally in hub while executing jobs on spoke/on-prem automation mesh nodes so migration actions occur close to VMware/BMC/spoke APIs.
- Example: AAP controller on hub + spoke execution nodes per site
- Current state: **Open**
- TT Input Required: Confirm this as the Migration Factory operating model.
- Impact if unresolved: If jobs run only in hub, direct hub->spoke API/network exposure becomes broader and less resilient for large migration waves.



### NET-11 — Local Action Endpoints for Spoke Execution

- Domain: Local Action Endpoints for Spoke Execution
- Inter-ref dependencies: Depends on `NET-10`; constrains reachable endpoint policy in `NET-12` and `NET-15`.
- Proposal: Permit spoke execution nodes to reach local VMware, BMC, and spoke OpenShift API endpoints required for pre-flight checks, migration waves, and stairstep host lifecycle tasks.
- Example: vCenter `443`, iLO/Redfish `443`, spoke API `6443`
- Current state: **Open**
- TT Input Required: Confirm endpoint inventory, protocols, and local firewall policy for each spoke site.
- Impact if unresolved: AAP workflows cannot perform migration-prep, host turnover, or local cluster actions at scale.



### NET-12 — Spoke-to-Hub Connectivity Standard

- Domain: Spoke-to-Hub Connectivity Standard
- Inter-ref dependencies: Depends on `NET-09` and `NET-11`; constrains `NET-13` route exceptions and `NET-14` DNS design; provides transport constraints for `NET-16` MTU planning when overlay networking is enabled.
- Proposal: Choose one standardized spoke outbound path to hub endpoints: (a) TGW+VPN, (b) DX+TGW, or (c) internet-based routing with hardened controls and explicit policy approval. For private connectivity options, document an end-to-end path MTU matrix so overlay and agent traffic expectations are explicit.
- Example: Option A: TGW+VPN; Option B: DX+TGW; Option C: Internet + allowlists; include path MTU matrix per option and identify the lowest-hop MTU.
- Current state: **Open**
- TT Input Required: Select standard model and fallback policy.
- Impact if unresolved: Security, cost, and reliability profile remain undefined.



### NET-13 — Optional Hub-to-Spoke Direct Access

- Domain: Optional Hub-to-Spoke Direct Access
- Inter-ref dependencies: Depends on `NET-09` baseline and `NET-12` connectivity standard; introduces conditional requirements for `NET-14` and `NET-15`.
- Proposal: Keep hub->spoke direct routing disabled by default; enable TGW/VGW route targets only for approved exceptions such as break-glass operations or non-agent legacy tooling.
- Example: Direct hub->spoke routes remain disabled by default and are enabled only through an approved exception path.
- Current state: Proposed conditional policy
- TT Input Required: Confirm whether any direct hub-to-spoke API use cases exist; if yes, provide CIDRs and target IDs.
- Impact if unresolved: Unexpected management failures for non-agent operations or unnecessary private routing footprint.



### NET-14 — DNS Architecture

- Domain: DNS Architecture
- Inter-ref dependencies: Depends on `NET-09` and `NET-12`; additionally depends on `NET-13` only when direct hub->spoke access is enabled.
- Proposal: Require deterministic spoke resolution of hub FQDNs always; require hub resolution of spoke FQDNs only when direct hub->spoke access is enabled; use authoritative zones + forwarding model per connectivity choice.
- Example: On-prem conditional forwarders -> Route53 inbound; Route53 outbound -> on-prem DNS
- Current state: Proposed
- TT Input Required: Confirm DNS authority ownership and forwarder/resolver endpoint design per chosen connectivity model.
- Impact if unresolved: ACM/Argo/AAP operations fail despite nominal L3 connectivity.



### NET-15 — Security Controls

- Domain: Security Controls
- Inter-ref dependencies: Depends on `NET-07`, `NET-08`, `NET-11`, and `NET-12`; includes `NET-13` when direct hub->spoke access is approved.
- Proposal: Enforce FQDN-based TLS validation, least-privilege IAM/network policy, and explicit firewall matrix. For hardened internet egress, combine VPC endpoints + NAT + inspection controls (AWS Network Firewall and/or explicit egress proxy) with domain/SNI allowlisting, default-deny posture, and exception governance.
- Example: Allowlist ROSA NAT EIPs to spoke API edge; require TLS hostname match; allow approved outbound endpoints (for example Red Hat registries/auth plus explicitly required services), deny all other direct internet egress by policy.
- Current state: Proposed
- TT Input Required: Confirm approved egress allowlist owner/process, required logging/retention, and emergency exception workflow.
- Impact if unresolved: Elevated security risk, weak auditability, or production outages caused by unmanaged/stale egress rules.



### NET-16 — Multi-Cluster Overlay Network (Submariner or equivalent)

- Domain: Multi-Cluster Overlay Network (Submariner or equivalent)
- Inter-ref dependencies: Depends on `NET-03` CIDR governance and `NET-12` connectivity intent for cross-cluster traffic.
- Proposal: If cross-cluster east-west pod/service communication is required, mandate globally non-overlapping Pod CIDR and Service CIDR across ROSA and all participating on-prem/SNO clusters. Also define an MTU policy from the lowest end-to-end underlay MTU in the active path and align the OVN overlay MTU accordingly (`overlay MTU = lowest node/underlay MTU - 100`).
- Example: CIDR: ROSA `10.128.0.0/14` + `172.30.0.0/16`; spoke ranges must not overlap. MTU: if lowest path MTU is `1500`, OVN overlay target is `1400`; if the entire path is jumbo-capable, size overlay from that lowest jumbo hop (for example DX private VIF supports up to `9001`; DX transit VIF supports up to `8500`).
- Current state: **Conditional / Open**
- TT Input Required: Confirm whether overlay networking is in-scope, provide CIDR plans for all connected clusters, and provide the end-to-end MTU matrix (AWS and on-prem hops) for any overlay-enabled paths.
- Impact if unresolved: Overlapping Pod/Service CIDRs will break or severely constrain cross-cluster pod/service routing and service export/import behavior; MTU mismatches can reduce throughput or cause packet loss/fragmentation symptoms across hybrid paths.



## TT Questions


| QID  | Question                                                                                                                                                                                                                                             | Why this matters                                                                                                                                                                                                                                | Related Spec Refs              |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------ |
| Q-01 | Can you confirm the exact `/21` allocated to `eu-west-1` for this ROSA hub deployment?                                                                                                                                                               | Finalizes VPC/subnet carving and `machine_cidr` values.                                                                                                                                                                                         | NET-02, NET-03, NET-04, NET-05 |
| Q-02 | Does the target VPC already exist in AWS common services, or should we create a new VPC from the allocated `/21`?                                                                                                                                    | Determines deployment mode (consume existing network vs create network).                                                                                                                                                                        | NET-02, NET-03                 |
| Q-03 | If VPC exists, can you provide VPC ID, private/public subnet IDs, AZ mapping, and route table IDs?                                                                                                                                                   | Needed to finalize network integration and deployment prerequisites.                                                                                                                                                                            | NET-02, NET-05                 |
| Q-04 | Can we formally confirm the spoke-initiated management model as baseline (ACM Klusterlet, Argo CD Agent, AAP mesh/agent paths), with no default hub-initiated API dependence?                                                                        | Establishes whether direct hub-to-spoke routes are required at Day-0.                                                                                                                                                                           | NET-09, NET-13                 |
| Q-05 | Do you approve a centralized hub AAP control-plane with spoke/on-prem execution nodes (Automation Mesh) as the Migration Factory model?                                                                                                              | Confirms job execution locality and network trust boundaries.                                                                                                                                                                                   | NET-10                         |
| Q-06 | For spoke execution nodes, what local VMware, BMC, and spoke OpenShift API endpoints/protocols must be reachable?                                                                                                                                    | Defines the local action network policy required for migration and host lifecycle automation.                                                                                                                                                   | NET-11                         |
| Q-07 | Which connectivity standard should we adopt for spoke outbound management traffic to AWS hub endpoints: TGW+VPN, DX+TGW, or internet-based routing?                                                                                                  | Locks security posture, reliability target, and cost model.                                                                                                                                                                                     | NET-12                         |
| Q-08 | What existing assets are already in place (TGW, site-to-site VPN, DX, DXGW, partner links)?                                                                                                                                                          | Prevents redundant build and guides fastest compliant path.                                                                                                                                                                                     | NET-12, NET-13                 |
| Q-09 | Do you have any explicit use cases that still require direct hub-to-spoke API access?                                                                                                                                                                | Determines whether optional on-prem route targets should remain disabled or be enabled.                                                                                                                                                         | NET-13                         |
| Q-10 | If direct hub-to-spoke access is required, what are the on-prem CIDRs and should route targets use TGW or VGW?                                                                                                                                       | Required to activate on-prem route resources correctly and safely.                                                                                                                                                                              | NET-13                         |
| Q-11 | Who owns DNS authority for hub and spoke domains, and who configures forwarders/resolver endpoints?                                                                                                                                                  | Prevents cross-domain resolution failures during ACM/Argo/AAP operations.                                                                                                                                                                       | NET-14                         |
| Q-12 | Are there policy constraints against internet-routed spoke outbound management traffic? If internet path is allowed, what source allowlist model is required?                                                                                        | Defines whether public-path management is permissible and under what controls.                                                                                                                                                                  | NET-12, NET-15                 |
| Q-13 | Is the 2 workers/AZ baseline approved for Day-0, and what growth threshold should trigger scaling above 6 workers (toward the modeled 18-worker ceiling from `max=6` per AZ pool)?                                                                     | Ensures hub remains stable under automation and policy load growth.                                                                                                                                                                             | NET-06                         |
| Q-14 | Is one NAT gateway per AZ approved from both resiliency and cost perspectives?                                                                                                                                                                       | Confirms egress resilience model and operational budget assumptions.                                                                                                                                                                            | NET-07                         |
| Q-15 | Which VPC endpoint profile is approved in your control framework for ROSA HCP customer VPCs: baseline (`sts`, `ecr.api`, `ecr.dkr`, `s3`) and conditional (`ec2`, `logs`, `monitoring`, `kms`, `secretsmanager`), explicitly excluding `autoscaling` and `elasticloadbalancing` unless a specific data-plane use case is documented? | Aligns security/cost posture and avoids ad hoc endpoint sprawl.                                                                                                                                                                                 | NET-08                         |
| Q-16 | Will you require multi-cluster overlay networking (for example Submariner) for direct pod-to-VM or pod-to-pod communication across ROSA and on-prem clusters? If yes, can you provide a non-overlapping Pod CIDR/Service CIDR plan for all clusters? | Submariner is NOT in-scope for this project. However if it ever is needed, we should proactively allocate non-overlapping CIDR. Determines whether strict global non-overlap of Pod/Service CIDRs must be enforced as a hard Day-0 requirement. | NET-16                         |
| Q-17 | If overlay networking or heavy east-west data paths are enabled, can TT provide an end-to-end MTU matrix (node NICs, VPC path, DX/VPN/TGW hops, and on-prem links) and approve the target overlay MTU policy?                                      | Prevents hidden MTU bottlenecks and avoids disruptive post-install MTU rework in production.                                                                                                                                                    | NET-12, NET-16                 |


