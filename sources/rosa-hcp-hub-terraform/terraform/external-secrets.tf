# External Secrets Operator post-install: IAM IRSA role for AWS Secrets Manager
# + ClusterSecretStore wiring (applied by the day-1 install script after the
# ESO operator CSV and ExternalSecretsConfig operand are ready).
#
# OIDC endpoint URL comes from the rosa-hcp module (without https://). The IAM
# OIDC provider ARN is derived from the account id + that URL.

locals {
  eso_enabled = var.install_day1_operators && var.create_htpasswd_admin && var.configure_eso_clustersecretstore

  # Module output is the issuer host/path without scheme (e.g.
  # rh-oidc.s3.us-east-2.amazonaws.com/<id>).
  oidc_provider_url = try(module.rosa_hcp_hub.oidc_endpoint_url, null)
  oidc_provider_arn = local.oidc_provider_url != null ? "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_provider_url}" : null

  eso_namespace            = "external-secrets"
  eso_service_account_name = "external-secrets"
  eso_cluster_secret_store = "aws-secrets-manager"
  eso_manifests_dir        = "${path.module}/../manifests/eso"
}

check "eso_requires_oidc" {
  assert {
    condition     = !var.configure_eso_clustersecretstore || var.create_oidc
    error_message = "configure_eso_clustersecretstore=true requires create_oidc=true so the cluster has an IAM OIDC provider for IRSA."
  }
}

check "eso_requires_day1_operators" {
  assert {
    condition     = !var.configure_eso_clustersecretstore || var.install_day1_operators
    error_message = "configure_eso_clustersecretstore=true requires install_day1_operators=true (ClusterSecretStore is applied after the ESO operator install)."
  }
}

resource "aws_iam_role" "external_secrets" {
  count = local.eso_enabled ? 1 : 0

  name = "${var.cluster_name}-external-secrets"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = local.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            # ROSA HCP aws-pod-identity webhook projects SA tokens with
            # audience "openshift" (not sts.amazonaws.com).
            "${local.oidc_provider_url}:sub" = "system:serviceaccount:${local.eso_namespace}:${local.eso_service_account_name}"
            "${local.oidc_provider_url}:aud" = "openshift"
          }
        }
      }
    ]
  })

  tags = merge(local.base_tags, {
    purpose = "external-secrets-operator"
  })

  depends_on = [module.rosa_hcp_hub]
}

resource "aws_iam_role_policy" "external_secrets" {
  count = local.eso_enabled ? 1 : 0

  name = "${var.cluster_name}-external-secrets"
  role = aws_iam_role.external_secrets[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds"
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:*"
      },
      {
        Effect   = "Allow"
        Action   = "secretsmanager:ListSecrets"
        Resource = "*"
      }
    ]
  })
}

# Optional E2E: create a short-lived Secrets Manager secret for sync validation.
resource "aws_secretsmanager_secret" "eso_e2e_test" {
  count = local.eso_enabled && var.eso_run_e2e_test ? 1 : 0

  name                    = var.eso_e2e_test_secret_name
  recovery_window_in_days = 0
  tags = merge(local.base_tags, {
    purpose = "eso-e2e-test"
  })
}

resource "aws_secretsmanager_secret_version" "eso_e2e_test" {
  count = local.eso_enabled && var.eso_run_e2e_test ? 1 : 0

  secret_id     = aws_secretsmanager_secret.eso_e2e_test[0].id
  secret_string = var.eso_e2e_test_secret_value
}
