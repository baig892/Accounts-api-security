# Dedicated CMK per data-class, not the AWS-managed default key. This is what makes
# key-usage auditable in CloudTrail (aws/rds default key usage is not attributable
# to accounts-api specifically) and what lets us revoke access to accounts-api's
# data independent of every other RDS instance in the account.
resource "aws_kms_key" "accounts_api" {
  description             = "CMK for accounts-api RDS storage + Secrets Manager (customer PII/financial data)"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = data.aws_iam_policy_document.kms_key_policy.json
}

resource "aws_kms_alias" "accounts_api" {
  name          = "alias/accounts-api"
  target_key_id = aws_kms_key.accounts_api.key_id
}

data "aws_caller_identity" "current" {}

# Deliberately narrow: root account retains admin rights (required, can't be
# removed without bricking the key), the accounts-api IRSA role gets Decrypt/
# GenerateDataKey ONLY (never Encrypt alone, never key management actions),
# and the platform team's break-glass role gets full kms:* for incident response.
# No wildcard principal, no "*" action anywhere in this policy.
#checkov:skip=CKV_AWS_111:KMS key-policy statements are resource="*" by AWS convention (this key, not all resources); access is scoped by named principal instead.
#checkov:skip=CKV_AWS_356:Same as CKV_AWS_111 - key-policy resource wildcard is the standard AWS pattern, not an identity-policy wildcard.
#checkov:skip=CKV_AWS_109:Access is constrained to three named principals (root/accounts-api-irsa/platform-breakglass), not exposed broadly. See DECISIONS.md "KMS key policy wildcard resource".
data "aws_iam_policy_document" "kms_key_policy" {
  statement {
    sid    = "RootAccountFullAccess"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AccountsApiDecryptOnly"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.accounts_api_irsa.arn]
    }
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "PlatformTeamBreakGlass"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.platform_breakglass.arn]
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
