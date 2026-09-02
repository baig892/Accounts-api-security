variable "eks_oidc_provider_arn" {
  description = "OIDC provider ARN for the shared EKS cluster (created once at cluster level, referenced here)."
  type        = string
}

variable "eks_oidc_provider_url" {
  description = "OIDC issuer URL without https://, e.g. oidc.eks.ap-south-1.amazonaws.com/id/XXXX"
  type        = string
}

# Trust policy: ONLY the accounts-api ServiceAccount in the accounts-api namespace
# can assume this role. This is the actual boundary that stops another team's pod
# on the shared cluster from calling AWS as accounts-api, even though they share
# the same EKS cluster and the same OIDC provider.
data "aws_iam_policy_document" "accounts_api_irsa_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.eks_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.eks_oidc_provider_url}:sub"
      values   = ["system:serviceaccount:accounts-api:accounts-api"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.eks_oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "accounts_api_irsa" {
  name               = "accounts-api-irsa"
  assume_role_policy = data.aws_iam_policy_document.accounts_api_irsa_trust.json
  max_session_duration = 3600
}

# Permissions: read one secret path, decrypt with one key, write to one KYC
# audit S3 prefix if that's how audit records land, and CloudWatch logs.
# No rds:*, no iam:*, no secretsmanager:* wildcard, no access to any other
# team's resources sharing the account/cluster.
data "aws_iam_policy_document" "accounts_api_permissions" {
  statement {
    sid       = "ReadOwnSecretOnly"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = ["arn:aws:secretsmanager:ap-south-1:*:secret:accounts-api/*"]
  }

  statement {
    sid       = "WriteOwnLogsOnly"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:ap-south-1:*:log-group:/eks/accounts-api/*"]
  }
}

resource "aws_iam_policy" "accounts_api_permissions" {
  name   = "accounts-api-scoped-permissions"
  policy = data.aws_iam_policy_document.accounts_api_permissions.json
}

resource "aws_iam_role_policy_attachment" "accounts_api" {
  role       = aws_iam_role.accounts_api_irsa.name
  policy_arn = aws_iam_policy.accounts_api_permissions.arn
}

# Platform team break-glass role, referenced by kms.tf. Requires MFA (enforced
# in the KMS key policy condition) - this is the two-person platform team's
# path to respond to an incident without standing broad access day-to-day.
resource "aws_iam_role" "platform_breakglass" {
  name = "platform-team-breakglass"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "sts:AssumeRole"
      Condition = { Bool = { "aws:MultiFactorAuthPresent" = "true" } }
    }]
  })
  max_session_duration = 3600 # short-lived, forces re-auth+re-MFA for a fresh incident rather than a standing long session
}
