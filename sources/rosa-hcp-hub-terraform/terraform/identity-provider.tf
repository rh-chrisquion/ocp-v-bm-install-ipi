# Identity providers for the hub cluster. Both resources talk to the OCM API
# (via the rhcs provider), not the cluster's own Kubernetes API, so they work
# immediately after cluster creation with no bootstrap kubeconfig required.

check "oidc_idp_requirements" {
  assert {
    condition = !var.enable_oidc_idp || (
      var.oidc_client_id != null &&
      var.oidc_client_secret != null &&
      var.oidc_issuer_url != null
    )
    error_message = "enable_oidc_idp is true but oidc_client_id, oidc_client_secret, or oidc_issuer_url is not set. Register an OIDC client against your organization's SSO (the one fronted by Duo) first, then set these values."
  }
}

# --- Sandbox/dev: Terraform-managed htpasswd cluster-admin ---

resource "random_password" "htpasswd_admin" {
  count            = var.create_htpasswd_admin ? 1 : 0
  length           = 24
  special          = true
  override_special = "!@#%^*()-_=+"
}

resource "rhcs_identity_provider" "htpasswd_admin" {
  count   = var.create_htpasswd_admin ? 1 : 0
  cluster = module.rosa_hcp_hub.cluster_id
  name    = "htpasswd-sandbox-admin"

  htpasswd = {
    users = [{
      username = var.htpasswd_admin_username
      password = random_password.htpasswd_admin[0].result
    }]
  }
}

resource "rhcs_group_membership" "htpasswd_admin_cluster_admins" {
  count   = var.create_htpasswd_admin ? 1 : 0
  cluster = module.rosa_hcp_hub.cluster_id
  group   = "cluster-admins"
  user    = var.htpasswd_admin_username

  depends_on = [rhcs_identity_provider.htpasswd_admin]
}

# --- Future/client env: OIDC IDP fronted by your org's SSO (Duo 2FA lives
# upstream at the IdP, not in this config -- see variables.tf for details) ---

resource "rhcs_identity_provider" "oidc" {
  count   = var.enable_oidc_idp ? 1 : 0
  cluster = module.rosa_hcp_hub.cluster_id
  name    = var.oidc_idp_name

  mapping_method = var.oidc_mapping_method

  openid = {
    client_id     = var.oidc_client_id
    client_secret = var.oidc_client_secret
    issuer        = var.oidc_issuer_url
    extra_scopes  = var.oidc_extra_scopes

    claims = {
      email              = var.oidc_email_claims
      name               = var.oidc_name_claims
      preferred_username = var.oidc_username_claims
      groups             = var.oidc_groups_claims
    }
  }
}

resource "rhcs_group_membership" "oidc_admin_cluster_admins" {
  count   = var.enable_oidc_idp && var.oidc_admin_username != null ? 1 : 0
  cluster = module.rosa_hcp_hub.cluster_id
  group   = "cluster-admins"
  user    = var.oidc_admin_username

  depends_on = [rhcs_identity_provider.oidc]
}
