terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Assumption: remote state in a dedicated, versioned, encrypted S3 bucket with a
  # DynamoDB lock table, in the security/platform account of the AWS Organization,
  # not the workload account. Backend block left unconfigured here (values are
  # account-specific and shouldn't be hardcoded in a submission repo) - see
  # DECISIONS.md "State backend".
}

provider "aws" {
  region = "ap-south-1"
  default_tags {
    tags = {
      service    = "accounts-api"
      data-class = "pci-adjacent"
      managed-by = "terraform"
    }
  }
}
