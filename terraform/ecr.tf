# In the actual AWS environment this is the registry, replacing the ghcr.io used
# in the take-home CI (see DECISIONS.md "Registry mapping" for why ghcr.io was
# used for the exercise and what changes to point CI at this instead).
resource "aws_ecr_repository" "accounts_api" {
  name                 = "accounts-api"
  image_tag_mutability = "IMMUTABLE" # a tag can never be repointed to a different digest after push

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.accounts_api.arn
  }
}

# Cross-account pull-only policy: the workload account's EKS node role can pull,
# nothing can push except the CI role, nothing can delete except that same CI
# role via lifecycle policy (not shown here as it's account-level IAM, not repo
# policy) - this repo policy only governs pull/push on THIS repository.
data "aws_iam_policy_document" "ecr_repo_policy" {
  statement {
    sid    = "AllowWorkloadAccountPull"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::444455556666:root"] # workload account, placeholder
    }
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
    ]
  }
  statement {
    sid    = "AllowCIPushOnly"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.github_actions_ci.arn]
    }
    actions = [
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:BatchCheckLayerAvailability",
    ]
  }
}

resource "aws_ecr_repository_policy" "accounts_api" {
  repository = aws_ecr_repository.accounts_api.name
  policy     = data.aws_iam_policy_document.ecr_repo_policy.json
}

resource "aws_ecr_lifecycle_policy" "accounts_api" {
  repository = aws_ecr_repository.accounts_api.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 7 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 7
      }
      action = { type = "expire" }
    }]
  })
}

# GitHub Actions -> AWS via OIDC federation, not a long-lived IAM user access key.
# This is what removes AWS_ACCESS_KEY_ID/SECRET from GitHub repo secrets entirely.
data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      # Locked to main branch pushes from this exact repo - a fork or a PR
      # branch cannot assume this role, only merges to main can push images.
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:org/accounts-api:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_actions_ci" {
  name               = "accounts-api-github-actions-ci"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json
}
