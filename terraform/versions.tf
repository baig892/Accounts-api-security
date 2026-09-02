terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Backend configuration is provided separately per environment.
  # See DECISIONS.md for the remote state design.
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
