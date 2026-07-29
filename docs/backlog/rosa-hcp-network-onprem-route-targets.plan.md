# ROSA HCP Network Stack Plan: On-Prem Route Targets

## Goal

Add optional, explicit support in `sources/rosa-hcp-network-terraform/terraform` for
private on-prem route propagation from private worker subnets through enterprise
network attachments (for example TGW or VGW), without changing current default
behavior.

## Scope

- Extend only the network foundation stack.
- Keep existing NAT-based default route behavior intact.
- Add optional route targets for private on-prem CIDR destinations.
- Do not provision TGW/VGW resources in this phase; consume attachment IDs from
  external foundation stacks.

## Design Principles

- Backward compatible by default (`no-op` when new variables are unset).
- Explicit per-CIDR route declarations (auditable and deterministic).
- Validate incompatible combinations early (for example setting both TGW and VGW
  for same route).
- Keep ROSA cluster stack unchanged; it continues to consume subnet outputs.

## Proposed Inputs

- `onprem_route_cidrs` (`list(string)`, default `[]`)
- `onprem_transit_gateway_id` (`string`, default `null`)
- `onprem_vpn_gateway_id` (`string`, default `null`)
- `create_onprem_private_routes` (`bool`, default `false`)

Optional enhancement:

- `onprem_route_table_ids_override` (`list(string)`, default `[]`) for advanced
  route-table targeting.

## Proposed Implementation Steps

1. Add variables with validation:
   - when `create_onprem_private_routes=true`, require:
     - non-empty `onprem_route_cidrs`
     - exactly one of TGW or VGW ID.
2. Add route resource(s) for each CIDR in each private route table:
   - target TGW when `onprem_transit_gateway_id` is set.
   - target VGW when `onprem_vpn_gateway_id` is set.
3. Add outputs exposing on-prem route entries and target type.
4. Update README with:
   - examples for TGW and VGW mode
   - guidance for private-only ROSA hub <-> on-prem ACM paths.
5. Add tfvars example commented block for on-prem routing.
6. Validate with `terraform fmt`, `terraform validate`, and test plans for:
   - default mode (no on-prem routes)
   - TGW mode
   - VGW mode.

## Risks and Mitigations

- **Risk:** Misrouted private traffic due to incorrect CIDRs.
  - **Mitigation:** explicit CIDR list + review checklist + plan output review.
- **Risk:** Inconsistent enterprise ownership of TGW/VGW.
  - **Mitigation:** consume IDs only; no ownership takeover in this stack.
- **Risk:** Route conflicts with existing private route standards.
  - **Mitigation:** optional feature flag and non-default activation.

## Acceptance Criteria

- Existing users can apply unchanged defaults with no behavior change.
- When enabled, private route tables include deterministic routes to specified
  on-prem CIDRs via configured TGW or VGW.
- Docs include operator-ready examples for both attachment types.
- Plan output clearly shows all on-prem routes before apply.
