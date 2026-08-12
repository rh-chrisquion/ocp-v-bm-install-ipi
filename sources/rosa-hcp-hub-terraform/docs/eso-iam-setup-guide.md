# IAM Role & Trust Policy Setup for External Secrets Operator (IRSA)

This document provides the exact IAM role, trust policy, and Kubernetes ServiceAccount annotation required for the External Secrets Operator (ESO) to authenticate to AWS Secrets Manager using IRSA (IAM Roles for Service Accounts) on a ROSA HCP cluster.

## Overview

IRSA allows a Kubernetes ServiceAccount to assume an AWS IAM role without static credentials. The flow is:

1. The ESO pod receives a projected JWT token from the cluster's OIDC provider
2. ESO calls `sts:AssumeRoleWithWebIdentity` with that token
3. AWS validates the token against the cluster's OIDC provider
4. AWS returns temporary credentials scoped to the IAM role
5. ESO uses those credentials to call `secretsmanager:GetSecretValue`

## Prerequisites — Values You Need

| Variable | Description | How to Obtain |
|----------|-------------|---------------|
| `<AWS_ACCOUNT_ID>` | Your AWS account ID (12 digits) | `aws sts get-caller-identity --query Account --output text` |
| `<OIDC_PROVIDER_URL>` | OIDC issuer URL **without** `https://` prefix | `oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}'` then strip `https://` |
| `<OIDC_PROVIDER_ARN>` | ARN of the OIDC provider in IAM | `arn:aws:iam::<AWS_ACCOUNT_ID>:oidc-provider/<OIDC_PROVIDER_URL>` |
| `<REGION>` | AWS region where secrets are stored | e.g. `us-east-2` |

## Step 1: Create the IAM Trust Policy

This trust policy allows **only** the `external-secrets` ServiceAccount in the `external-secrets` namespace to assume the role.

Save this as `trust-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "<OIDC_PROVIDER_ARN>"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "<OIDC_PROVIDER_URL>:sub": "system:serviceaccount:external-secrets:external-secrets",
          "<OIDC_PROVIDER_URL>:aud": "openshift"
        }
      }
    }
  ]
}
```

### Example with real values

If your AWS account is `123456789012` and your OIDC provider URL is `rh-oidc.s3.us-east-1.amazonaws.com/abc123def456`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::123456789012:oidc-provider/rh-oidc.s3.us-east-1.amazonaws.com/abc123def456"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "rh-oidc.s3.us-east-1.amazonaws.com/abc123def456:sub": "system:serviceaccount:external-secrets:external-secrets",
          "rh-oidc.s3.us-east-1.amazonaws.com/abc123def456:aud": "openshift"
        }
      }
    }
  ]
}
```

### Key details about the trust policy

- **`Principal.Federated`**: Must be the full ARN of the OIDC provider registered in IAM for this ROSA HCP cluster.
- **`Condition.StringEquals` — `:sub`**: This locks the role to a specific ServiceAccount. The format is `system:serviceaccount:<namespace>:<service-account-name>`. In our case: `system:serviceaccount:external-secrets:external-secrets`.
- **`Condition.StringEquals` — `:aud`**: On ROSA HCP, the `aws-pod-identity`
  webhook projects ServiceAccount tokens with audience **`openshift`** (not
  `sts.amazonaws.com`). The trust policy must match that audience.

## Step 2: Create the IAM Permission Policy

This policy grants the minimum permissions ESO needs to read secrets from AWS Secrets Manager.

Save this as `permissions-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowGetSecrets",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:ListSecretVersionIds"
      ],
      "Resource": "arn:aws:secretsmanager:<REGION>:<AWS_ACCOUNT_ID>:secret:*"
    },
    {
      "Sid": "AllowListSecrets",
      "Effect": "Allow",
      "Action": "secretsmanager:ListSecrets",
      "Resource": "*"
    }
  ]
}
```

### Scoping down (optional but recommended)

To restrict access to specific secrets rather than all secrets in the account, replace the `Resource` in `AllowGetSecrets` with specific ARNs or a prefix pattern:

```json
"Resource": "arn:aws:secretsmanager:us-east-2:123456789012:secret:my-app/*"
```

## Step 3: Create the IAM Role

Using the AWS CLI:

```bash
# Create the role with the trust policy
aws iam create-role \
  --role-name <CLUSTER_NAME>-external-secrets \
  --assume-role-policy-document file://trust-policy.json \
  --tags Key=cluster,Value=<CLUSTER_NAME> Key=purpose,Value=external-secrets-operator

# Attach the permissions policy inline
aws iam put-role-policy \
  --role-name <CLUSTER_NAME>-external-secrets \
  --policy-name SecretsManagerReadOnly \
  --policy-document file://permissions-policy.json
```

Note the role ARN from the output — it will look like:
```
arn:aws:iam::<AWS_ACCOUNT_ID>:role/<CLUSTER_NAME>-external-secrets
```

## Step 4: Annotate the Kubernetes ServiceAccount

Once the IAM role is created, annotate the ESO ServiceAccount so it knows which role to assume:

```bash
oc annotate serviceaccount external-secrets \
  -n external-secrets \
  eks.amazonaws.com/role-arn=arn:aws:iam::<AWS_ACCOUNT_ID>:role/<CLUSTER_NAME>-external-secrets \
  --overwrite
```

After annotating, restart the ESO pods so they pick up the new token:

```bash
oc rollout restart deployment/external-secrets -n external-secrets
```

## Step 5: Verify

Check the ServiceAccount annotation:

```bash
oc get sa external-secrets -n external-secrets -o jsonpath='{.metadata.annotations}' | python3 -m json.tool
```

Expected output:
```json
{
  "eks.amazonaws.com/role-arn": "arn:aws:iam::<AWS_ACCOUNT_ID>:role/<CLUSTER_NAME>-external-secrets"
}
```

Check the ClusterSecretStore status:

```bash
oc get clustersecretstore aws-secrets-manager -o jsonpath='{.status.conditions[0]}' | python3 -m json.tool
```

Expected output:
```json
{
  "lastTransitionTime": "...",
  "message": "",
  "reason": "Valid",
  "status": "True",
  "type": "Ready"
}
```

## Summary

| Component | Value |
|-----------|-------|
| IAM Role Name | `<CLUSTER_NAME>-external-secrets` |
| Trust Policy Principal | OIDC provider ARN for the ROSA HCP cluster |
| Trust Policy Subject | `system:serviceaccount:external-secrets:external-secrets` |
| Trust Policy Audience | `openshift` (ROSA HCP aws-pod-identity webhook) |
| Permissions | `secretsmanager:GetSecretValue`, `DescribeSecret`, `ListSecretVersionIds`, `ListSecrets` |
| ServiceAccount | `external-secrets` in namespace `external-secrets` |
| ServiceAccount Annotation | `eks.amazonaws.com/role-arn` = role ARN |
