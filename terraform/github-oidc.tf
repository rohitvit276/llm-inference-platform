# GitHub Actions OIDC: CI assumes a short-lived role instead of storing AWS
# keys as repo secrets. The trust policy is pinned to this exact repo and
# branch, so a fork (or any other repo) presenting a GitHub token cannot
# assume the role even if the role ARN is public.

variable "github_repo" {
  description = "GitHub repo allowed to assume the CI role (owner/name)"
  type        = string
  default     = "rohitvit276/llm-inference-platform"
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]
  # GitHub rotates thumbprints; AWS now validates against trusted root CAs,
  # but the argument is still required.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

variable "create_github_oidc_provider" {
  description = "Create the OIDC provider (false if the account already has one)"
  type        = bool
  default     = true
}

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

resource "aws_iam_role" "github_actions" {
  name = "llm-platform-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = local.github_oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          # Pin: only workflows on main of this exact repo can assume the role.
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/main"
        }
      }
    }]
  })
}

# Least privilege: push/pull the gateway image, nothing else.
resource "aws_iam_role_policy" "github_actions_ecr" {
  name = "ecr-push-gateway"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
        Resource = aws_ecr_repository.gateway.arn
      }
    ]
  })
}

output "github_actions_role_arn" {
  description = "Set as the AWS_ROLE_ARN repo variable to enable CI image pushes"
  value       = aws_iam_role.github_actions.arn
}
