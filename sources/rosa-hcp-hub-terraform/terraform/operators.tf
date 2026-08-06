# Day-1 OLM operators installed as part of terraform apply (not a separate
# post-step). Manifests live under ../manifests/; after CSVs succeed the
# install script patches Subscriptions to installPlanApproval=Manual.
#
# Requires cluster API reachability from the Terraform runner (public API,
# VPN/TGW, or an active bastion SSM port-forward for private clusters) and
# the htpasswd sandbox admin for oc login.

check "day1_operators_require_htpasswd_admin" {
  assert {
    condition     = !var.install_day1_operators || var.create_htpasswd_admin
    error_message = "install_day1_operators=true requires create_htpasswd_admin=true so Terraform can oc login and apply operator manifests. Disable install_day1_operators or enable create_htpasswd_admin."
  }
}

locals {
  day1_manifests_dir  = "${path.module}/../manifests"
  day1_manifest_files = sort(fileset(local.day1_manifests_dir, "*.yaml"))
  day1_manifests_hash = sha256(join("", [
    for f in local.day1_manifest_files : filesha256("${local.day1_manifests_dir}/${f}")
  ]))
}

resource "terraform_data" "day1_operators" {
  # Both flags required: the check above catches misconfiguration at plan time;
  # the conjunction here keeps the password reference valid when count is zero.
  count = var.install_day1_operators && var.create_htpasswd_admin ? 1 : 0

  # Changing cluster id or manifests replaces this resource and re-runs install.
  triggers_replace = [
    module.rosa_hcp_hub.cluster_id,
    local.day1_manifests_hash,
  ]

  depends_on = [
    module.rosa_hcp_hub,
    rhcs_identity_provider.htpasswd_admin,
    rhcs_group_membership.htpasswd_admin_cluster_admins,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.module}/scripts/install-day1-operators.sh"
    environment = {
      CLUSTER_API_URL = module.rosa_hcp_hub.cluster_api_url
      OC_USERNAME     = var.htpasswd_admin_username
      OC_PASSWORD     = one(random_password.htpasswd_admin[*].result)
      MANIFESTS_DIR   = local.day1_manifests_dir
    }
  }
}
