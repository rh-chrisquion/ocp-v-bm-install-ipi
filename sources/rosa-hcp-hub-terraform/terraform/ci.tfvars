# Non-sensitive values required by .github/workflows/rosa-hub-terraform.yaml.
#
# terraform.tfvars is gitignored (local/interactive use only), so the CI
# workflow has no source for the required variables below unless they're
# committed somewhere -- this file is that source. Only rhcs_token (the one
# genuinely sensitive value) comes from the RHCS_TOKEN GitHub secret instead.
#
# These are the same style of placeholder values as terraform.tfvars.example.
# Update them to match whatever this environment should actually be named
# before running `action=apply` for real -- an apply with these values will
# create resources named accordingly.

cluster_name          = "example-rosa-hub-hcp"
aws_region            = "us-east-2"
account_role_prefix   = "example-rosa-hub"
operator_role_prefix  = "example-rosa-hub-operators"
