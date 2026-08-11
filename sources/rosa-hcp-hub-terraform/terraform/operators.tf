# Day-1 OLM operators installed as part of terraform apply (not a separate
# post-step). Manifests live under ../manifests/; after CSVs succeed the
# install script patches Subscriptions to installPlanApproval=Manual, then
# (when configure_eso_clustersecretstore is true) applies ExternalSecretsConfig,
# annotates the IRSA ServiceAccount, and creates the ClusterSecretStore.
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
  day1_manifests_dir = "${path.module}/../manifests"
  day1_operator_files = sort([
    for f in fileset(local.day1_manifests_dir, "*.yaml") : f
  ])
  day1_eso_files = sort([
    for f in fileset("${local.day1_manifests_dir}/eso", "*.yaml") : "eso/${f}"
  ])
  day1_manifests_hash = sha256(join("", [
    for f in concat(local.day1_operator_files, local.day1_eso_files) :
    filesha256("${local.day1_manifests_dir}/${f}")
  ]))
}

resource "terraform_data" "day1_operators" {
  # Both flags required: the check above catches misconfiguration at plan time;
  # the conjunction here keeps the password reference valid when count is zero.
  count = var.install_day1_operators && var.create_htpasswd_admin ? 1 : 0

  # Changing cluster id, manifests, IAM role, or e2e settings replaces this
  # resource and re-runs install + ESO ClusterSecretStore configuration.
  triggers_replace = [
    module.rosa_hcp_hub.cluster_id,
    local.day1_manifests_hash,
    try(aws_iam_role.external_secrets[0].arn, ""),
    var.configure_eso_clustersecretstore,
    var.eso_run_e2e_test,
    var.eso_e2e_test_secret_name,
  ]

  depends_on = [
    module.rosa_hcp_hub,
    rhcs_identity_provider.htpasswd_admin,
    rhcs_group_membership.htpasswd_admin_cluster_admins,
    aws_iam_role.external_secrets,
    aws_iam_role_policy.external_secrets,
    aws_secretsmanager_secret_version.eso_e2e_test,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.module}/scripts/install-day1-operators.sh"
    environment = {
      CLUSTER_API_URL          = module.rosa_hcp_hub.cluster_api_url
      OC_USERNAME              = var.htpasswd_admin_username
      OC_PASSWORD              = one(random_password.htpasswd_admin[*].result)
      MANIFESTS_DIR            = local.day1_manifests_dir
      AWS_REGION               = var.aws_region
      ESO_MANIFESTS_DIR        = local.eso_manifests_dir
      ESO_IAM_ROLE_ARN         = var.configure_eso_clustersecretstore ? try(aws_iam_role.external_secrets[0].arn, "") : ""
      ESO_NAMESPACE            = local.eso_namespace
      ESO_SERVICE_ACCOUNT      = local.eso_service_account_name
      ESO_CLUSTER_SECRET_STORE = local.eso_cluster_secret_store
      ESO_RUN_E2E_TEST         = var.configure_eso_clustersecretstore && var.eso_run_e2e_test ? "true" : "false"
      ESO_E2E_SECRET_NAME      = var.eso_e2e_test_secret_name
      ESO_E2E_SECRET_VALUE     = var.eso_e2e_test_secret_value
      ESO_E2E_NAMESPACE        = var.eso_e2e_test_namespace
    }
  }
}
