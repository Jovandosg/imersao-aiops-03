output "cluster_name" {
  description = "Nome do cluster EKS."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint do API server."
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Versão do Kubernetes do control plane."
  value       = module.eks.cluster_version
}

output "vpc_id" {
  description = "ID da VPC do ambiente."
  value       = module.network.vpc_id
}

output "private_subnet_ids" {
  description = "Subnets privadas onde os worker nodes rodam."
  value       = module.network.private_subnet_ids
}

output "kubeconfig_command" {
  description = "Comando para configurar o kubectl contra este cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
