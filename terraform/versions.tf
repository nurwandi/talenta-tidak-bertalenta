terraform {
  required_version = ">= 1.6"

  cloud {
    organization = "ambitionism"
    workspaces {
      name = "talenta-tidak-bertalenta"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project = "talenta-tidak-bertalenta"
    }
  }
}
