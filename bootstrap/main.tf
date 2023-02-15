# One-time, applied by hand with admin credentials: the state bucket, lock table and the
# GitHub OIDC roles the pipeline assumes. Everything else is applied by CI.
terraform {
  required_version = ">= 0.14"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 3.27" }
  }
}

provider "aws" {
  region = "us-east-1"
}

locals {
  repo = "ericguerra/infrablocks"
  tags = { Environment = "shared", Owner = "platform-team", CostCenter = "ecom-1042", ManagedBy = "terraform" }
}

module "state" {
  source = "../modules/s3-bucket"
  name   = "infrablocks-tfstate-123456789012"
  tags   = local.tags
}

resource "aws_dynamodb_table" "locks" {
  name         = "infrablocks-tf-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  tags         = local.tags

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# plan roles: read-only, any branch/PR.  apply roles: only from main, gated per GitHub environment.
data "aws_iam_policy_document" "trust" {
  for_each = toset(["plan", "apply"])
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.key == "plan" ? ["repo:${local.repo}:*"] : ["repo:${local.repo}:environment:*"]
    }
  }
}

resource "aws_iam_role" "gha" {
  for_each           = { for pair in setproduct(["plan", "apply"], ["staging", "prod"]) : "${pair[0]}-${pair[1]}" => pair[0] }
  name               = "gha-terraform-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.trust[each.value].json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "gha" {
  for_each   = aws_iam_role.gha
  role       = each.value.name
  # apply needs IAM (modules create task roles); scope it down with a permissions boundary in a real account
  policy_arn = substr(each.key, 0, 4) == "plan" ? "arn:aws:iam::aws:policy/ReadOnlyAccess" : "arn:aws:iam::aws:policy/AdministratorAccess"
}
