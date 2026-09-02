# Dedicated KMS key for accounts-api data.
# Using a customer-managed key gives us explicit access control,
# rotation and a separate audit boundary for this application's data.

resource "aws_kms_key" "accounts_api" {
  description             = "KMS key for accounts-api RDS and Secrets Manager data"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = data.aws_iam_policy_document.kms_key_policy.json
}

resource "aws_kms_alias" "accounts_api" {
  name          = "alias/accounts-api"
  target_key_id = aws_kms_key.accounts_api.key_id
}

data "aws_caller_identity" "current" {}

# KMS key policies use Resource = "*" because the key policy itself
# defines access to this specific KMS key. Access is restricted through
# explicit principals below.
#
# checkov:skip=CKV_AWS_111:KMS key policies use Resource="*" by design; access is restricted by named principals.
# checkov:skip=CKV_AWS_356:KMS key policy Resource="*" applies only to this key policy and is not an identity-policy wildcard.
# checkov:skip=CKV_AWS_109:Access is restricted to the account root, accounts-api IRSA role, and break-glass role.

data "aws_iam_policy_document" "kms_key_policy" {
  statement {
    sid    = "RootAccountFullAccess"
    effect = "Allow"

    principals {
      type = "AWS"

      identifiers = [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
      ]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AccountsApiUseKey"
    effect = "Allow"

    principals {
      type = "AWS"

      identifiers = [
        aws_iam_role.accounts_api_irsa.arn
      ]
    }

    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "PlatformBreakGlass"
    effect = "Allow"

    principals {
      type = "AWS"

      identifiers = [
        aws_iam_role.platform_breakglass.arn
      ]
    }

    actions   = ["kms:*"]
    resources = ["*"]

    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }
}
