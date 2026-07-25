variable "cluster_name" {
  type        = string
  description = "Nome do cluster EKS. Também prefixa as roles IAM e o node group."
}

variable "kubernetes_version" {
  type        = string
  description = "Versão do Kubernetes do control plane (ex.: 1.36). O node group herda essa versão quando não é fixada separadamente."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnets onde o control plane cria as ENIs e onde os worker nodes sobem. Devem estar em ao menos 2 AZs."
}

variable "endpoint_public_access" {
  type        = bool
  description = "Expõe o endpoint da API do cluster na internet. Necessário para rodar kubectl de fora da VPC sem bastion/VPN."
  default     = true
}

variable "endpoint_public_access_cidrs" {
  type        = list(string)
  description = "CIDRs autorizados a alcançar o endpoint público da API. Só tem efeito com endpoint_public_access = true."
  default     = ["0.0.0.0/0"]
}

variable "enabled_cluster_log_types" {
  type        = list(string)
  description = "Tipos de log do control plane enviados ao CloudWatch. Valores válidos: api, audit, authenticator, controllerManager, scheduler. Lista vazia desliga o logging."
  default     = ["api", "audit", "authenticator"]
}

variable "log_retention_days" {
  type        = number
  description = "Retenção, em dias, do log group do control plane. Só é usado quando enabled_cluster_log_types não está vazio."
  default     = 7
}

variable "node_group_name" {
  type        = string
  description = "Nome do managed node group."
  default     = "default"
}

variable "node_instance_types" {
  type        = list(string)
  description = "Tipos de instância dos worker nodes (ex.: [\"t3.medium\"])."
}

variable "node_desired_size" {
  type        = number
  description = "Quantidade desejada de worker nodes."
}

variable "node_min_size" {
  type        = number
  description = "Mínimo de worker nodes no autoscaling group."
}

variable "node_max_size" {
  type        = number
  description = "Máximo de worker nodes no autoscaling group."
}

variable "node_capacity_type" {
  type        = string
  description = "Modelo de capacidade dos nodes: ON_DEMAND ou SPOT."
  default     = "ON_DEMAND"
}

variable "node_disk_size" {
  type        = number
  description = "Tamanho, em GiB, do disco EBS de cada worker node."
  default     = 20
}

variable "node_ami_type" {
  type        = string
  description = "AMI usada pelos nodes. AL2023_x86_64_STANDARD é o padrão atual — o Amazon Linux 2 foi descontinuado a partir do Kubernetes 1.33."
  default     = "AL2023_x86_64_STANDARD"
}

variable "cluster_addons" {
  type        = list(string)
  description = "Add-ons gerenciados instalados após o node group (ex.: vpc-cni, coredns, kube-proxy, eks-pod-identity-agent). Lista vazia mantém apenas os add-ons de bootstrap do próprio EKS."
  default     = ["vpc-cni", "kube-proxy", "coredns", "eks-pod-identity-agent"]
}

variable "tags" {
  type        = map(string)
  description = "Tags aplicadas a todos os recursos criados pelo módulo."
  default     = {}
}
