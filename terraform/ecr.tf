# ECR repository for the accounts-api container.
resource "aws_ecr_repository" "accounts_api" {
  name                 = "accounts-api"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.accounts_api.arn
  }
}

# Allow the workload account to pull images and the GitHub Actions
# role to push images to this repository.
data "aws_iam_policy_document" "ecr_repo_policy" {
  statement {
    sid    = "AllowWorkloadAccountPull"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::444455556666:root"]
    }

    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
    ]
  }

  statement {
    sid    = "AllowCIPush"
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

# Remove untagged images after 7 days.
resource "aws_ecr_lifecycle_policy" "accounts_api" {
  repository = aws_ecr_repository.accounts_api.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"

        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }

        action = {
          type = "expire"
        }
      }
    ]
  })
}

# GitHub Actions authenticates to AWS through OIDC.
# No long-lived AWS access keys are stored in GitHub.
data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    effect  = "Allow"

    actions = [
      "sts:AssumeRoleWithWebIdentity"
    ]

    principals {
      type = "Federated"

      identifiers = [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only the main branch of the accounts-api repository can assume this role.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [
        "repo:org/accounts-api:ref:refs/heads/main"
      ]
    }
  }
}

resource "aws_iam_role" "github_actions_ci" {
  name               = "accounts-api-github-actions-ci"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json
}