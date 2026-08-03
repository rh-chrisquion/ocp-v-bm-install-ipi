# ROSA HCP + OCP-V Networking Port Cheat Sheet

Scope: OCP-V bare-metal agent-based installs managed by a ROSA HCP hub running ACM, Argo CD, and AAP Migration Factory workflows.

## Color Key

| Color | Meaning | How to Treat It |
| --- | --- | --- |
| Green (`success`) | Baseline required for the recommended architecture | Treat as default allow path for Day-0 and Day-1 readiness |
| Yellow (`warning`) | Conditional control path or exception-only flow | Enable only when the administrator approves a specific use case |
| Blue (`info`) | Context or environment-dependent supporting control | Validate against DNS, routing, and security design choices |

## Cross-Site Hub to Spoke Management Ports

| Flow | Source -> Destination | Protocol / Port | Direction | Required? | Purpose | Color |
| --- | --- | --- | --- | --- | --- | --- |
| ACM klusterlet registration + policy | On-prem OCP-V cluster -> ROSA ACM hub route | TCP 443 | Spoke outbound | Yes | Cluster registration, status, policy work queue | Green |
| Argo CD Agent control channel | On-prem Argo agent -> ROSA Argo control endpoint | TCP 443 | Spoke outbound | Yes (agent model) | GitOps sync/control without inbound API exposure | Green |
| Argo CD classic push | ROSA Argo controller -> on-prem OCP-V API | TCP 6443 | Hub outbound + spoke inbound | Conditional | Required only for direct push model | Yellow |
| AAP mesh control path | AAP execution nodes <-> AAP control mesh peers | TCP 27199 (default, configurable) | Depends on mesh topology | Conditional | Receptor mesh transport for job dispatch/results | Yellow |
| AAP UI/API | Execution nodes/operators -> ROSA AAP API/UI | TCP 443 | Spoke outbound | Yes (centralized control) | Job control, inventory sync, callback/results | Green |
| Optional direct hub node operations | ROSA automation components -> on-prem OCP-V API | TCP 6443 | Hub outbound + spoke inbound | Conditional | Only if Admins requires direct hub-initiated cluster actions | Yellow |
| Hybrid DNS forwarding | AWS resolver <-> on-prem DNS resolvers | TCP/UDP 53 | Bidirectional | Conditional | Required when split-horizon/forwarding is used | Blue |

## OCP-V Agent-Based Install and Node Provisioning Ports (On-Prem)

| Flow | Source -> Destination | Protocol / Port | Required? | Purpose | Color |
| --- | --- | --- | --- | --- | --- |
| DHCP address assignment | Booting nodes -> DHCP service | UDP 67/68 | Yes (if DHCP) | IP addressing during boot/install | Green |
| DNS resolution | Booting/installed nodes -> DNS resolvers | TCP/UDP 53 | Yes | Resolve API/ingress and external dependencies | Green |
| Time sync | Booting/installed nodes -> NTP sources | UDP 123 | Yes | Certificate validity and cluster health | Green |
| API access | Admins/automation -> OCP-V API VIP | TCP 6443 | Yes | Cluster API operations | Green |
| Ingress access | Users/automation -> OCP-V ingress | TCP 443 (and 80 as needed) | Yes | Application and route access | Green |
| BMC virtual media + lifecycle | Provisioning automation -> iLO/iDRAC/Redfish endpoints | TCP 443 (Redfish), UDP 623 (IPMI legacy) | Conditional | Power, mount media, and lifecycle operations | Yellow |

## AAP Migration Factory for VMware Migration

| Flow | Source -> Destination | Protocol / Port | Required? | Purpose | Color |
| --- | --- | --- | --- | --- | --- |
| vCenter API | AAP execution nodes -> vCenter | TCP 443 | Yes | Inventory, orchestration, and migration API actions | Green |
| ESXi data/control channel | AAP execution nodes -> ESXi hosts | TCP 443 and TCP/UDP 902 | Commonly required | VM console/NFC and migration-related host interactions | Blue |
| Target cluster API | AAP execution nodes -> OCP-V API | TCP 6443 | Yes | Create/patch target resources during migration workflows | Green |
| Guest OS automation (Linux) | AAP execution nodes -> guest VMs | TCP 22 | Conditional | In-guest pre/post migration configuration | Yellow |
| Guest OS automation (Windows) | AAP execution nodes -> guest VMs | TCP 5985/5986 | Conditional | WinRM-based migration/configuration steps | Yellow |

## Design Guardrail

To minimize inbound exposure, keep hub management spoke-initiated and place AAP execution nodes on-prem. Enable hub outbound `6443` only for explicitly approved workflows.
