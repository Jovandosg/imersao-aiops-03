output "cluster_name" {
  description = "Nome do cluster EKS."
  value       = aws_eks_cluster.this.name
}

output "cluster_version" {
  description = "Versão do Kubernetes efetivamente rodando no control plane."
  value       = aws_eks_cluster.this.version
}

output "cluster_endpoint" {
  description = "Endpoint HTTPS do API server do cluster."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Certificado da CA do cluster, em base64. Usado no kubeconfig."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "Security group gerenciado pelo EKS para a comunicação entre control plane e nodes."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "cluster_oidc_issuer_url" {
  description = "URL do OIDC issuer do cluster. É o ponto de partida para configurar IRSA."
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "node_group_role_arn" {
  description = "ARN da role IAM dos worker nodes, para anexar políticas adicionais."
  value       = aws_iam_role.node.arn
}
