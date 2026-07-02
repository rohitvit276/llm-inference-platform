output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = var.region
}

output "ecr_gateway_url" {
  value = aws_ecr_repository.gateway.repository_url
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
